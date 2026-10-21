defmodule PictureRail.PhotoSource.Manager do
  @moduledoc """
  Starts the photo source the settings name, and swaps it when that
  changes (see `PictureRail.PhotoSource.Supervisor`).

  Follows the `:settings` controller and reads the settings themselves
  from `PictureRail.Settings.current/0`. A change within the same source
  (a new URL, other albums) is left to the source, which follows the
  settings itself; only a different type, or none, restarts it.
  """
  use GenServer

  require Logger

  alias PictureRail.{PhotoSource, Settings}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Check the settings again now."
  @spec refresh(GenServer.server()) :: :ok
  def refresh(server), do: GenServer.call(server, :refresh)

  @impl GenServer
  def init(opts) do
    registry = Keyword.fetch!(opts, :registry)

    # Restarted alone (`:rest_for_one`, last): the source it started is
    # still running, under the same registry.
    running =
      case PhotoSource.active(registry) do
        {_pid, module} -> module
        nil -> nil
      end

    state = %{
      registry: registry,
      sources: Keyword.fetch!(opts, :sources),
      settings_fun: Keyword.get(opts, :settings, &Settings.current/0),
      app: Keyword.get(opts, :app, PictureRail.App),
      app_monitor: nil,
      running: running
    }

    {:ok, state, {:continue, :start}}
  end

  @impl GenServer
  def handle_continue(:start, state),
    do: {:noreply, state |> subscribe_settings() |> apply_settings()}

  @impl GenServer
  def handle_call(:refresh, _from, state), do: {:reply, :ok, apply_settings(state)}

  @impl GenServer
  def handle_info(%Solve.Message{}, state), do: {:noreply, apply_settings(state)}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{app_monitor: ref} = state) do
    Process.send_after(self(), :resubscribe, 1_000)
    {:noreply, %{state | app_monitor: nil}}
  end

  def handle_info(:resubscribe, state),
    do: {:noreply, state |> subscribe_settings() |> apply_settings()}

  def handle_info(_message, state), do: {:noreply, state}

  defp subscribe_settings(state) do
    app = state.app

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
    case state.settings_fun.().photo_source do
      %Settings.PhotoSource{module: module} when module == state.running ->
        state

      %Settings.PhotoSource{module: module, config: config} ->
        state |> stop() |> start(module, config)

      nil ->
        stop(state)
    end
  end

  defp start(state, module, config) do
    name = {:via, Registry, {state.registry, :active, module}}
    spec = module.child_spec(name: name, config: config)

    case DynamicSupervisor.start_child(state.sources, spec) do
      {:ok, _pid} ->
        Logger.info("Photo source: started #{module.label()}")
        %{state | running: module}

      {:error, reason} ->
        # tried again on the next settings change
        Logger.error("Photo source: #{module.label()} didn't start: #{inspect(reason)}")
        state
    end
  end

  defp stop(%{running: nil} = state), do: state

  defp stop(state) do
    for {_id, pid, _type, _modules} when is_pid(pid) <-
          DynamicSupervisor.which_children(state.sources),
        do: DynamicSupervisor.terminate_child(state.sources, pid)

    Logger.info("Photo source: stopped #{state.running.label()}")

    # a stopped source reports nothing more: say so, or its last status
    # stays on the screen
    if state.app && Process.whereis(state.app),
      do: Solve.dispatch(state.app, :photos, :stats, PhotoSource.unconfigured_stats())

    %{state | running: nil}
  end
end
