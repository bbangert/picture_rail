defmodule PictureRail.Settings.Watcher do
  @moduledoc """
  Keeps the settings file loaded.

  Loads it at start (writing a template on first boot, so there's
  something to edit over SSH), re-reads it within ten seconds of a change
  or on `reload/0`, and hands every successfully loaded version to the
  `:settings` controller. A file that doesn't validate is reported and the
  previous settings stay in use.

  The file holds credentials, so its mode is kept at 0600.
  """
  use GenServer

  require Logger

  alias PictureRail.Settings

  @poll_ms 10_000

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

  @impl GenServer
  def init(opts) do
    state = %{
      path: Keyword.get_lazy(opts, :path, &PictureRail.Paths.settings_file/0),
      poll_ms: Keyword.get(opts, :poll_ms, @poll_ms),
      notify: Keyword.get(opts, :notify, &notify_app/2),
      write_template?: Keyword.get(opts, :write_template, true),
      mtime: nil,
      settings: Settings.defaults(),
      status: :missing
    }

    {:ok, state, {:continue, :load}}
  end

  @impl GenServer
  def handle_continue(:load, state) do
    state = state |> maybe_write_template() |> load()
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

  defp maybe_write_template(%{write_template?: true, path: path} = state) do
    if File.exists?(path) do
      state
    else
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(path, @template),
           :ok <- File.chmod(path, 0o600) do
        Logger.info("Settings: wrote a template to #{path}; fill in the credentials")
      else
        {:error, reason} -> Logger.warning("Settings: couldn't write #{path}: #{inspect(reason)}")
      end

      state
    end
  end

  defp maybe_write_template(state), do: state

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
