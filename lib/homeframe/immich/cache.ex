defmodule HomeFrame.Immich.Cache do
  @moduledoc """
  The rolling photo cache behind the slideshow.

  It indexes every photo in the selected albums, shuffles them once per
  pass, and keeps the next `cache.window` (default 25) downloaded in the
  photo cache directory, one download at a time. `next/1` hands out the
  next downloaded photo without ever waiting on the network.

  When new photos can be fetched, a photo that has been shown is deleted
  and the window refills. When they can't (Immich unreachable, or the
  albums fit in the window), shown photos go back to the end of the window
  instead, so the slideshow keeps cycling what it has.

  A manifest next to the photos lists the window, so after a reboot
  without network the slideshow still has photos. Files are checked on
  start (present, non-empty, a JPEG or PNG header); anything else in the
  directory is removed.

  Status (reported to the `:immich` controller): `:unconfigured`,
  `:connecting`, `:online`, `:offline`, `:invalid_key`,
  `{:missing_permission, message}` or `:no_albums`.
  """
  use GenServer

  require Logger

  alias HomeFrame.Immich.{Album, Asset}
  alias HomeFrame.Settings

  @type entry :: %{asset: Asset.t(), path: Path.t(), clip: Path.t() | nil}
  @type status ::
          :unconfigured
          | :connecting
          | :online
          | :offline
          | :invalid_key
          | {:missing_permission, String.t()}
          | :no_albums

  @defaults [
    api: HomeFrame.Immich.Client,
    backoff_initial_ms: 5_000,
    backoff_max_ms: 300_000,
    album_poll_ms: 600_000,
    task_sup: HomeFrame.TaskSup,
    app: HomeFrame.App
  ]

  # -- API --

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  The next photo to show: `{:ok, entry}` or `:none` while nothing is
  downloaded yet. Never waits on the network.
  """
  @spec next(GenServer.server()) :: {:ok, entry()} | :none
  def next(server \\ __MODULE__), do: GenServer.call(server, :next)

  @doc "Status and counts, for the UI and the IEx shell."
  @spec stats(GenServer.server()) :: map()
  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats)

  # -- GenServer --

  @impl GenServer
  def init(opts) do
    opts = Keyword.merge(@defaults, opts)

    state = %{
      api: opts[:api],
      opts: Map.new(opts),
      dir: Keyword.get_lazy(opts, :dir, &HomeFrame.Paths.photo_cache_dir/0),
      settings_fun: Keyword.get(opts, :settings, &Settings.current/0),
      notify: Keyword.get(opts, :notify, &notify_app/1),
      immich: nil,
      window: 25,
      include_live?: true,
      conn: nil,
      status: :unconfigured,
      version: nil,
      album_versions: %{},
      album_ids: [],
      # every photo, and what's left of the current pass in shuffled order
      index: [],
      pass: [],
      ready: :queue.new(),
      current: nil,
      download: nil,
      backoff_ms: opts[:backoff_initial_ms],
      timer: nil,
      app_monitor: nil,
      bad: MapSet.new()
    }

    {:ok, state, {:continue, :start}}
  end

  @impl GenServer
  def handle_continue(:start, state) do
    File.mkdir_p!(state.dir)
    state = state |> restore_manifest() |> subscribe_settings() |> apply_settings()
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:next, _from, state) do
    case :queue.out(state.ready) do
      {{:value, entry}, rest} ->
        state = retire(state.current, %{state | ready: rest, current: entry})
        state = state |> write_manifest() |> maybe_download()
        {:reply, {:ok, entry}, state}

      {:empty, _} ->
        {:reply, maybe_current(state), state}
    end
  end

  def handle_call(:stats, _from, state), do: {:reply, stats_of(state), state}

  @impl GenServer
  def handle_info(:connect, state), do: {:noreply, connect(%{state | timer: nil})}
  def handle_info(:poll_albums, state), do: {:noreply, poll_albums(%{state | timer: nil})}

  def handle_info({ref, result}, %{download: {ref, asset}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, download_done(result, asset, %{state | download: nil})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{download: {ref, asset}} = state) do
    Logger.warning("Immich cache: download of #{asset.id} crashed: #{inspect(reason)}")
    {:noreply, %{state | download: nil} |> maybe_download()}
  end

  # The settings controller changed: re-read them (with credentials).
  def handle_info(%Solve.Message{}, state), do: {:noreply, apply_settings(state)}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{app_monitor: ref} = state) do
    Process.send_after(self(), :resubscribe, 1_000)
    {:noreply, %{state | app_monitor: nil}}
  end

  def handle_info(:resubscribe, state),
    do: {:noreply, state |> subscribe_settings() |> apply_settings()}

  def handle_info(_message, state), do: {:noreply, state}

  # -- Settings --

  defp subscribe_settings(state) do
    app = state.opts.app

    case app && Process.whereis(app) do
      pid when is_pid(pid) ->
        Solve.subscribe(app, :settings)
        %{state | app_monitor: Process.monitor(pid)}

      _ ->
        if app, do: Process.send_after(self(), :resubscribe, 1_000)
        state
    end
  end

  defp apply_settings(state) do
    settings = state.settings_fun.()
    window = settings.cache.window
    include_live? = settings.cache.include_live_photos

    cond do
      settings.immich == state.immich ->
        %{state | window: window, include_live?: include_live?}
        |> trim_window()
        |> maybe_download()

      settings.immich == nil ->
        Logger.info("Immich cache: Immich isn't configured")

        cancel_timer(state)
        |> Map.merge(%{immich: nil, conn: nil, window: window, include_live?: include_live?})
        |> set_status(:unconfigured)

      true ->
        state
        |> cancel_timer()
        |> Map.merge(%{
          immich: settings.immich,
          conn: Map.get_lazy(state.opts, :conn, fn -> state.api.connect(settings.immich) end),
          window: window,
          include_live?: include_live?,
          album_versions: %{},
          backoff_ms: state.opts.backoff_initial_ms
        })
        |> set_status(:connecting)
        |> connect()
    end
  end

  # -- Connecting and listing --

  defp connect(%{conn: nil} = state), do: state

  defp connect(state) do
    with :ok <- state.api.ping(state.conn),
         {:ok, version} <- state.api.version(state.conn),
         {:ok, albums} <- state.api.list_albums(state.conn) do
      %{state | version: version, backoff_ms: state.opts.backoff_initial_ms}
      |> refresh_index(albums)
      |> maybe_download()
      |> schedule(:poll_albums, state.opts.album_poll_ms)
    else
      {:error, reason} -> failed(state, reason)
    end
  end

  defp poll_albums(%{conn: nil} = state), do: state

  defp poll_albums(state) do
    case state.api.list_albums(state.conn) do
      {:ok, albums} ->
        state |> refresh_index(albums) |> schedule(:poll_albums, state.opts.album_poll_ms)

      {:error, reason} ->
        failed(state, reason)
    end
  end

  # Re-list the photos only when a selected album's change fields moved.
  defp refresh_index(state, albums) do
    selected = select_albums(albums, state.immich)
    versions = Map.new(selected, &{&1.id, Album.version(&1)})

    cond do
      selected == [] ->
        Logger.warning("Immich cache: none of the configured albums were found")
        %{state | album_ids: []} |> set_status(:no_albums)

      versions == state.album_versions ->
        set_status(state, :online)

      true ->
        list_images(state, Enum.map(selected, & &1.id), versions)
    end
  end

  defp select_albums(albums, immich) do
    Enum.filter(albums, &(&1.id in immich.album_ids or &1.name in immich.album_names))
  end

  defp list_images(state, album_ids, versions) do
    case state.api.list_album_images(state.conn, album_ids, state.version) do
      {:ok, assets} ->
        Logger.info("Immich cache: #{length(assets)} photos in #{length(album_ids)} album(s)")

        %{state | index: assets, album_ids: album_ids, album_versions: versions, pass: []}
        |> drop_removed()
        |> set_status(:online)
        |> maybe_download()

      {:error, reason} ->
        failed(state, reason)
    end
  end

  defp failed(state, reason) do
    status =
      case reason do
        :invalid_key -> :invalid_key
        {:missing_permission, _} = missing -> missing
        _ -> :offline
      end

    delay = state.backoff_ms
    Logger.warning("Immich cache: #{inspect(reason)}, retrying in #{div(delay, 1000)} s")

    %{state | backoff_ms: min(delay * 2, state.opts.backoff_max_ms)}
    |> set_status(status)
    |> schedule(:connect, delay)
  end

  # -- The window --

  # Photos that left the albums go, unless one is on screen.
  defp drop_removed(state) do
    keys = MapSet.new(state.index, &key/1)

    {keep, gone} =
      state.ready |> :queue.to_list() |> Enum.split_with(&MapSet.member?(keys, key(&1.asset)))

    Enum.each(gone, &delete_entry/1)
    write_manifest(%{state | ready: :queue.from_list(keep)})
  end

  defp trim_window(state) do
    {keep, extra} = state.ready |> :queue.to_list() |> Enum.split(state.window)
    Enum.each(extra, &delete_entry/1)
    if extra == [], do: state, else: write_manifest(%{state | ready: :queue.from_list(keep)})
  end

  # The photo that was on screen (no longer current): deleted if the
  # window can refill with new photos, otherwise sent round again.
  defp retire(nil, state), do: state

  defp retire(old, state) do
    if can_refill?(%{state | ready: :queue.in(old, state.ready)}) do
      delete_entry(old)
      state
    else
      %{state | ready: :queue.in(old, state.ready)}
    end
  end

  defp maybe_current(%{current: nil}), do: :none
  defp maybe_current(%{current: entry}), do: {:ok, entry}

  # New photos can come in when online and some photo isn't on disk yet.
  defp can_refill?(state) do
    state.status == :online and Enum.any?(state.index, &(not on_disk?(state, &1)))
  end

  defp on_disk?(state, asset) do
    k = key(asset)

    (state.current != nil and key(state.current.asset) == k) or
      Enum.any?(:queue.to_list(state.ready), &(key(&1.asset) == k))
  end

  defp maybe_download(%{download: download} = state) when download != nil, do: state
  defp maybe_download(%{status: status} = state) when status != :online, do: state

  defp maybe_download(state) do
    if :queue.len(state.ready) >= state.window do
      state
    else
      case next_to_download(state) do
        {nil, state} -> state
        {asset, state} -> start_download(state, asset)
      end
    end
  end

  # The next photo of the current pass that isn't on disk; a new shuffled
  # pass starts when this one runs out.
  defp next_to_download(state, reshuffled? \\ false) do
    case Enum.split_while(
           state.pass,
           &(on_disk?(state, &1) or MapSet.member?(state.bad, key(&1)))
         ) do
      {_skipped, [asset | rest]} ->
        {asset, %{state | pass: rest}}

      {_skipped, []} when reshuffled? ->
        {nil, %{state | pass: []}}

      {_skipped, []} ->
        next_to_download(%{state | pass: Enum.shuffle(state.index)}, true)
    end
  end

  defp start_download(state, asset) do
    path = photo_path(state, asset)
    clip = if state.include_live? and asset.live_photo_video_id, do: clip_path(state, asset)
    api = state.api
    conn = state.conn

    task =
      Task.Supervisor.async_nolink(state.opts.task_sup, fn ->
        fetch(api, conn, asset, path, clip)
      end)

    %{state | download: {task.ref, asset}}
  end

  # Runs in a task: download to .part files, then rename.
  defp fetch(api, conn, asset, path, clip) do
    with :ok <- fetch_file(fn tmp -> api.download_preview(conn, asset.id, tmp) end, path),
         :ok <- fetch_clip(api, conn, asset, clip) do
      {:ok, %{asset: asset, path: path, clip: clip}}
    end
  end

  defp fetch_clip(_api, _conn, _asset, nil), do: :ok

  defp fetch_clip(api, conn, asset, clip) do
    case fetch_file(fn tmp -> api.download_clip(conn, asset.live_photo_video_id, tmp) end, clip) do
      :ok ->
        :ok

      {:error, reason} ->
        # The still is still worth showing.
        Logger.warning("Immich cache: clip for #{asset.id} failed: #{inspect(reason)}")
        :ok
    end
  end

  defp fetch_file(download, path) do
    tmp = path <> ".part"

    case download.(tmp) do
      :ok ->
        File.rename(tmp, path)

      error ->
        File.rm(tmp)
        error
    end
  end

  defp download_done({:ok, entry}, _asset, state) do
    entry = if entry.clip && File.exists?(entry.clip), do: entry, else: %{entry | clip: nil}

    %{state | ready: :queue.in(entry, state.ready)}
    |> write_manifest()
    |> maybe_download()
    |> report()
  end

  defp download_done({:error, {:unsupported_format, type}}, asset, state) do
    Logger.warning("Immich cache: skipping #{asset.id}, its preview is #{type}")
    %{state | bad: MapSet.put(state.bad, key(asset))} |> maybe_download()
  end

  defp download_done({:error, {:http_error, status}}, asset, state) do
    Logger.warning("Immich cache: skipping #{asset.id} (HTTP #{status})")
    %{state | bad: MapSet.put(state.bad, key(asset))} |> maybe_download()
  end

  defp download_done({:error, reason}, _asset, state), do: failed(state, reason)

  # -- Files and the manifest --

  defp key(%Asset{id: id, checksum: checksum}), do: {id, checksum}

  defp file_stem(%Asset{id: id, checksum: checksum}) do
    hash =
      case Base.decode64(checksum) do
        {:ok, raw} -> Base.encode16(raw, case: :lower)
        :error -> Integer.to_string(:erlang.phash2(checksum), 16)
      end

    "#{id}-#{hash}"
  end

  defp photo_path(state, asset), do: Path.join(state.dir, file_stem(asset) <> ".jpg")
  defp clip_path(state, asset), do: Path.join(state.dir, file_stem(asset) <> ".mp4")
  defp manifest_path(state), do: Path.join(state.dir, "manifest.json")

  defp delete_entry(entry) do
    File.rm(entry.path)
    if entry.clip, do: File.rm(entry.clip)
  end

  defp write_manifest(state) do
    entries = :queue.to_list(state.ready) ++ List.wrap(state.current)
    json = Jason.encode!(%{version: 1, entries: Enum.map(entries, &entry_to_json/1)})
    tmp = manifest_path(state) <> ".part"

    with :ok <- File.write(tmp, json), do: File.rename(tmp, manifest_path(state))
    state
  end

  defp entry_to_json(%{asset: asset, path: path, clip: clip}) do
    %{asset: Map.from_struct(asset), file: Path.basename(path), clip: clip && Path.basename(clip)}
  end

  # Rebuild the window from the manifest, keeping only intact files, and
  # remove everything else in the directory.
  defp restore_manifest(state) do
    entries =
      with {:ok, json} <- File.read(manifest_path(state)),
           {:ok, %{"entries" => entries}} <- Jason.decode(json) do
        entries |> Enum.map(&entry_from_json(state, &1)) |> Enum.filter(&intact?/1)
      else
        _ -> []
      end

    keep = MapSet.new(["manifest.json" | Enum.flat_map(entries, &entry_files/1)])

    for file <- File.ls!(state.dir),
        not MapSet.member?(keep, file),
        do: File.rm_rf(Path.join(state.dir, file))

    if entries != [], do: Logger.info("Immich cache: #{length(entries)} photos on disk")
    %{state | ready: :queue.from_list(entries)} |> write_manifest()
  end

  defp entry_files(entry),
    do:
      Enum.reject([Path.basename(entry.path), entry.clip && Path.basename(entry.clip)], &is_nil/1)

  defp entry_from_json(state, %{"asset" => asset, "file" => file} = entry) do
    asset = %Asset{
      id: asset["id"],
      checksum: asset["checksum"],
      width: asset["width"],
      height: asset["height"],
      local_date_time: asset["local_date_time"],
      live_photo_video_id: asset["live_photo_video_id"],
      mime: asset["mime"]
    }

    clip = entry["clip"] && Path.join(state.dir, entry["clip"])
    clip = if clip && File.regular?(clip), do: clip

    %{asset: asset, path: Path.join(state.dir, file), clip: clip}
  end

  defp entry_from_json(_state, _entry), do: nil

  defp intact?(nil), do: false

  defp intact?(%{asset: %Asset{id: id, checksum: checksum}, path: path})
       when is_binary(id) and is_binary(checksum) do
    case File.open(path, [:read, :binary], &IO.binread(&1, 8)) do
      {:ok, <<0xFF, 0xD8, 0xFF, _::binary>>} -> true
      {:ok, <<0x89, "PNG", _::binary>>} -> true
      _ -> false
    end
  end

  defp intact?(_entry), do: false

  # -- Status --

  defp set_status(%{status: status} = state, status), do: state

  defp set_status(state, status) do
    Logger.info("Immich cache: #{inspect(status)}")
    report(%{state | status: status})
  end

  defp report(state) do
    state.notify.(stats_of(state))
    state
  end

  defp stats_of(state) do
    %{
      status: state.status,
      photos: length(state.index),
      ready: :queue.len(state.ready),
      window: state.window,
      downloading?: state.download != nil
    }
  end

  defp schedule(state, message, ms) do
    state = cancel_timer(state)
    %{state | timer: Process.send_after(self(), message, ms)}
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(state) do
    Process.cancel_timer(state.timer)
    %{state | timer: nil}
  end

  defp notify_app(stats) do
    if Process.whereis(HomeFrame.App), do: Solve.dispatch(HomeFrame.App, :immich, :stats, stats)
    :ok
  end
end
