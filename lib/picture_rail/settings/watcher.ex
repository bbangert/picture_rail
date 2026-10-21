defmodule PictureRail.Settings.Watcher do
  @moduledoc """
  Keeps the settings file loaded, and writes it.

  Loads it at start, re-reads it within ten seconds of a change (an edit
  over SSH) or on `reload/0`, and hands every successfully loaded version
  to the `:settings` controller. A file that doesn't validate is reported
  and the previous settings stay in use.

  `update/2` is how the Setup page and the web page save: it changes
  sections of the file and loads the result, serialized with the reloads.
  A missing file is fine: the frame guides setting it up. Frames set up
  before that have a template written on first boot; while unedited it
  still counts as not set up (`:template`).

  The file holds credentials, so its mode is kept at 0600.
  """
  use GenServer

  require Logger

  alias PictureRail.{PhotoSource, PrivateFile, Settings}
  alias PictureRail.Settings.Sections
  alias PictureRail.Setup.{Field, Secret}

  @poll_ms 10_000

  # Written on first boot by earlier versions; recognized, no longer written.
  @template """
  {
    "immich": {
      "url": "https://photos.example.com",
      "api_key": "",
      "album_ids": []
    },
    "home_assistant": {
      "url": "http://homeassistant.local:8123",
      "token": ""
    }
  }
  """

  @type status :: :ok | :missing | :template | {:error, [String.t()]}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "The settings in use."
  @spec current(GenServer.server()) :: Settings.t()
  def current(server \\ __MODULE__), do: GenServer.call(server, :current)

  @doc "The settings in use and the status of the last load."
  @spec state(GenServer.server()) :: {Settings.t(), status()}
  def state(server \\ __MODULE__), do: GenServer.call(server, :state)

  @doc "Re-read the file now."
  @spec reload(GenServer.server()) :: :ok | {:error, [String.t()]}
  def reload(server \\ __MODULE__), do: GenServer.call(server, :reload)

  @doc """
  Change sections of the settings file and load the result.

  `sections` maps section names to the values to set in them (string
  keys); a `nil` section is removed. Keys left out of a section keep their
  value, and so does a secret given as `""` or `nil` (secrets are never
  shown, only replaced), unless the section now points at another server
  (`PictureRail.Setup.Field.same_server?/3`): then it has to be given
  again. A photo source of a different `"type"` replaces
  the old one's settings. Keys and sections this version doesn't know are
  kept, and a legacy `immich` section becomes `photo_source`.

  The result is validated as a whole: on errors nothing is written and
  they're returned. Otherwise the file is replaced atomically, private
  from the first byte (`PictureRail.PrivateFile`), and loaded. A file that
  isn't valid JSON is never overwritten.
  """
  @spec update(%{String.t() => map() | nil}, GenServer.server()) :: :ok | {:error, [String.t()]}
  def update(sections, server \\ __MODULE__) when is_map(sections),
    do: GenServer.call(server, {:update, %Secret{value: sections}})

  @impl GenServer
  def init(opts) do
    state = %{
      path: Keyword.get_lazy(opts, :path, &PictureRail.Paths.settings_file/0),
      poll_ms: Keyword.get(opts, :poll_ms, @poll_ms),
      notify: Keyword.get(opts, :notify, &notify_app/2),
      mtime: nil,
      settings: Settings.defaults(),
      status: :missing
    }

    {:ok, state, {:continue, :load}}
  end

  @impl GenServer
  def handle_continue(:load, state) do
    state = load(state)
    Process.send_after(self(), :poll, state.poll_ms)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:current, _from, state), do: {:reply, state.settings, state}
  def handle_call(:state, _from, state), do: {:reply, {state.settings, state.status}, state}

  def handle_call(:reload, _from, state) do
    state = load(state)

    reply =
      case state.status do
        {:error, errors} -> {:error, errors}
        _ -> :ok
      end

    {:reply, reply, state}
  end

  def handle_call({:update, %Secret{value: sections}}, _from, state) do
    with {:ok, current} <- read_json(state.path),
         {:ok, merged} <- merge(current, sections),
         {:ok, _settings} <- Settings.parse(merged),
         :ok <- write(state.path, merged) do
      state = load(state)

      case state.status do
        {:error, errors} -> {:reply, {:error, errors}, state}
        _ -> {:reply, :ok, state}
      end
    else
      {:error, errors} -> {:reply, {:error, errors}, state}
    end
  end

  @impl GenServer
  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, state.poll_ms)
    if mtime(state.path) != state.mtime, do: {:noreply, load(state)}, else: {:noreply, state}
  end

  defp load(state) do
    mtime = mtime(state.path)
    secure(state.path)

    case read(state.path) do
      {:ok, settings, status} ->
        Logger.info("Settings: loaded #{state.path} (#{inspect(status)})")
        state.notify.(settings, status)
        %{state | settings: settings, status: status, mtime: mtime}

      {:error, errors} ->
        Logger.error(
          "Settings: #{state.path} is invalid, keeping the previous settings:\n  " <>
            Enum.join(errors, "\n  ")
        )

        state.notify.(state.settings, {:error, errors})
        %{state | status: {:error, errors}, mtime: mtime}
    end
  end

  # The unedited template means "not configured yet", not an invalid file.
  defp read(path) do
    case File.read(path) do
      {:ok, @template} ->
        {:ok, Settings.defaults(), :template}

      {:ok, json} ->
        with {:ok, settings} <- Settings.decode(json), do: {:ok, settings, :ok}

      {:error, :enoent} ->
        {:ok, Settings.defaults(), :missing}

      {:error, reason} ->
        {:error, ["can't read #{path}: #{:file.format_error(reason)}"]}
    end
  end

  # The file as JSON, to change and write back. Nothing (or the unedited
  # template) is an empty object; JSON that doesn't parse is left alone.
  defp read_json(path) do
    case File.read(path) do
      {:ok, @template} ->
        {:ok, %{}}

      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{} = map} -> {:ok, map}
          {:ok, _other} -> {:error, ["the settings file must contain a JSON object"]}
          {:error, error} -> {:error, ["not valid JSON: #{Exception.message(error)}"]}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, ["can't read #{path}: #{:file.format_error(reason)}"]}
    end
  end

  defp merge(current, sections) do
    Enum.reduce_while(sections, {:ok, migrate(current)}, fn
      {name, nil}, {:ok, acc} ->
        {:cont, {:ok, Map.delete(acc, name)}}

      {name, values}, {:ok, acc} ->
        case merge_section(name, Map.get(acc, name), values) do
          {:ok, section} -> {:cont, {:ok, Map.put(acc, name, section)}}
          error -> {:halt, error}
        end
    end)
  end

  # Files from before photo sources: `immich` is the Immich photo source,
  # unless there's a `photo_source` (`null` isn't one, as for the parser).
  defp migrate(%{"immich" => legacy} = map) do
    map = Map.delete(map, "immich")

    case map["photo_source"] do
      nil ->
        source = if is_map(legacy), do: Map.put(legacy, "type", "immich"), else: legacy
        Map.put(map, "photo_source", source)

      _source ->
        map
    end
  end

  defp migrate(map), do: map

  # Another kind of source: the old one's settings don't apply.
  defp merge_section("photo_source", %{"type" => type}, %{"type" => new} = values)
       when new != type,
       do: merge_section("photo_source", %{}, values)

  defp merge_section(name, old, values) do
    old = if is_map(old), do: old, else: %{}
    fields = fields(name, Map.get(values, "type", Map.get(old, "type")))
    secrets = Field.secret_keys(fields)

    merged = put_values(old, values, secrets)

    # a kept secret only goes to the server it was given for
    kept = for key <- secrets, Map.get(values, key) in [nil, ""], Map.has_key?(old, key), do: key

    if kept == [] or Field.same_server?(fields, old, merged),
      do: {:ok, merged},
      else: {:error, for(key <- kept, do: "#{name}.#{key} #{Field.retype()}")}
  end

  defp put_values(old, values, secrets) do
    Enum.reduce(values, old, fn {key, value}, acc ->
      cond do
        value in [nil, ""] and key in secrets -> acc
        value == nil -> Map.delete(acc, key)
        true -> Map.put(acc, key, value)
      end
    end)
  end

  defp fields("photo_source", type) when is_binary(type) do
    case PhotoSource.module_for(type) do
      {:ok, module} -> module.fields()
      :error -> []
    end
  end

  defp fields("photo_source", _type), do: []

  defp fields(name, _type) do
    if name in Sections.names(), do: Sections.fields(name), else: []
  end

  defp write(path, map) do
    case PrivateFile.write(path, [Jason.encode_to_iodata!(map, pretty: true), "
"]) do
      :ok -> :ok
      {:error, reason} -> {:error, ["can't write #{path}: #{:file.format_error(reason)}"]}
    end
  end

  # Credentials: keep the file private to its owner.
  defp secure(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} when Bitwise.band(mode, 0o077) != 0 ->
        Logger.warning("Settings: #{path} was readable by others; setting its mode to 0600")
        File.chmod(path, 0o600)

      _ ->
        :ok
    end
  end

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime, size: size}} -> {mtime, size}
      {:error, _} -> nil
    end
  end

  defp notify_app(settings, status) do
    if Process.whereis(PictureRail.App) do
      Solve.dispatch(PictureRail.App, :settings, :loaded, {settings, status})
    end

    :ok
  end
end
