defmodule PictureRail.HA.Model do
  @moduledoc """
  The Home Assistant model behind the panel.

  It follows the settings: when `home_assistant` is set it starts a
  `Hassock.Supervisor` (connection, entity cache and registry cache) under
  `PictureRail.HA.ConnSup`, and replaces it when the URL or token changes.
  Hassock connects in the background and keeps retrying, so Home Assistant
  being down at boot holds nothing up.

  Once both the registries and the entity states are loaded, it joins them
  (`PictureRail.HA.Index`) into an ETS table, again (debounced) whenever a
  registry changes or entities appear or go away. Reads go to ETS directly.

  It reports to the `:ha` controller: the connection status
  (`:unconfigured`, `:connecting`, `:connected`, `:disconnected`,
  `{:auth_failed, reason}`), the model revision after each rebuild, and
  the ids of entities whose state changed.
  """
  use GenServer

  require Logger

  alias Hassock.{Cache, RegistryCache}
  alias PictureRail.HA.Index
  alias PictureRail.Settings

  @type status ::
          :unconfigured | :connecting | :connected | :disconnected | {:auth_failed, term()}

  @defaults [
    table: :picture_rail_ha,
    conn_sup: PictureRail.HA.ConnSup,
    connection_name: PictureRail.HA.Connection,
    cache_name: PictureRail.HA.Cache,
    registry_cache_name: PictureRail.HA.Registries,
    app: PictureRail.App,
    rebuild_ms: 300,
    states_flush_ms: 250,
    restart_ms: 5_000
  ]

  # -- API --

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "The current status (see the moduledoc), from ETS: never waits on the model."
  @spec status(atom()) :: status()
  def status(table \\ @defaults[:table]), do: lookup(table, :status, :unconfigured)

  @doc "Floors in order, each with its area ids."
  @spec floors(atom()) :: [%{floor: Hassock.Floor.t(), area_ids: [String.t()]}]
  def floors(table \\ @defaults[:table]), do: lookup(table, :floors, [])

  @doc "Ids of the areas that aren't on a known floor, by name."
  @spec floorless_area_ids(atom()) :: [String.t()]
  def floorless_area_ids(table \\ @defaults[:table]),
    do: lookup(table, :floorless_area_ids, [])

  @doc "Ids of devices with shown entities but no area, by name."
  @spec no_area_device_ids(atom()) :: [String.t()]
  def no_area_device_ids(table \\ @defaults[:table]),
    do: lookup(table, :no_area_device_ids, [])

  @doc "Ids of every shown entity."
  @spec entity_ids(atom()) :: [String.t()]
  def entity_ids(table \\ @defaults[:table]), do: lookup(table, :entity_ids, [])

  @doc "An area and the ids of its shown entities, or `nil`."
  @spec area(String.t(), atom()) :: %{area: Hassock.Area.t(), entity_ids: [String.t()]} | nil
  def area(area_id, table \\ @defaults[:table]), do: lookup(table, {:area, area_id}, nil)

  @doc "A shown entity, or `nil`."
  @spec entity(String.t(), atom()) :: Index.Entity.t() | nil
  def entity(entity_id, table \\ @defaults[:table]), do: lookup(table, {:entity, entity_id}, nil)

  @doc "A device, or `nil`."
  @spec device(String.t() | nil, atom()) :: Hassock.Device.t() | nil
  def device(device_id, table \\ @defaults[:table])
  def device(nil, _table), do: nil
  def device(device_id, table), do: lookup(table, {:device, device_id}, nil)

  @doc "The model revision: 0 until the first build."
  @spec revision(atom()) :: non_neg_integer()
  def revision(table \\ @defaults[:table]), do: lookup(table, :revision, 0)

  @doc "An entity's current state from the hassock cache, or `nil`."
  @spec state(String.t(), GenServer.server()) :: Hassock.EntityState.t() | nil
  def state(entity_id, cache \\ @defaults[:cache_name]) do
    if GenServer.whereis(cache), do: Cache.get(cache, entity_id)
  end

  defp lookup(table, key, default) do
    case :ets.lookup(table, key) do
      [{^key, value}] -> value
      [] -> default
    end
  rescue
    ArgumentError -> default
  end

  # -- GenServer --

  @impl GenServer
  def init(opts) do
    opts = Keyword.merge(@defaults, opts)
    table = :ets.new(opts[:table], [:named_table, :protected, :set, read_concurrency: true])

    state = %{
      opts: Map.new(opts),
      table: table,
      settings_fun: Keyword.get(opts, :settings, &Settings.current/0),
      notify: Keyword.get(opts, :notify, &notify_app/1),
      registries_fun: Keyword.get(opts, :registries, &registries/1),
      state_ids_fun: Keyword.get(opts, :state_ids, &state_ids/1),
      start_fun: Keyword.get(opts, :start_hassock, &start_hassock/2),
      ha: nil,
      hassock: nil,
      status: :unconfigured,
      # the hassock entity cache and registry cache that reported :ready,
      # {pid, monitor}: readiness belongs to that instance and goes with it
      ready: %{states: nil, registries: nil},
      # ids of entities whose state changed since the last flush
      changed: MapSet.new(),
      flush_timer: nil,
      rebuild_timer: nil,
      revision: 0,
      app_monitor: nil
    }

    {:ok, state, {:continue, :start}}
  end

  @impl GenServer
  def handle_continue(:start, state),
    do: {:noreply, state |> subscribe_settings() |> apply_settings()}

  @impl GenServer
  def handle_info({:hassock_cache, cache, event}, state),
    do: {:noreply, cache_event(event, cache, state)}

  def handle_info({:hassock_registry, cache, :ready}, state),
    do: {:noreply, state |> mark_ready(:registries, cache) |> schedule_rebuild()}

  def handle_info({:hassock_registry, _cache, {:changed, _kind}}, state),
    do: {:noreply, schedule_rebuild(state)}

  def handle_info(:rebuild, state), do: {:noreply, rebuild(%{state | rebuild_timer: nil})}

  def handle_info(:flush_states, state) do
    case state.changed |> MapSet.to_list() |> Enum.sort() do
      [] -> :ok
      ids -> state.notify.({:states, ids})
    end

    {:noreply, %{state | changed: MapSet.new(), flush_timer: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{hassock: {_hassock, ref}} = state) do
    Logger.warning("HA: hassock stopped (#{inspect(reason)}), restarting")
    Process.send_after(self(), :restart_hassock, state.opts.restart_ms)
    {:noreply, %{state | hassock: nil} |> clear_ready() |> set_status(:disconnected)}
  end

  # A cache that reported :ready went away (hassock restarted it).
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{ready: %{states: {_, ref}}} = state),
    do: {:noreply, put_in(state.ready.states, nil)}

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{ready: %{registries: {_, ref}}} = state
      ),
      do: {:noreply, put_in(state.ready.registries, nil)}

  def handle_info(:restart_hassock, %{hassock: nil, ha: %Settings.HomeAssistant{}} = state),
    do: {:noreply, start(state)}

  def handle_info(:restart_hassock, state), do: {:noreply, state}

  # The settings controller changed: re-read them (with credentials).
  def handle_info(%Solve.Message{}, state), do: {:noreply, apply_settings(state)}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{app_monitor: ref} = state) do
    Process.send_after(self(), :resubscribe, 1_000)
    {:noreply, %{state | app_monitor: nil}}
  end

  def handle_info(:resubscribe, state),
    do: {:noreply, state |> subscribe_settings() |> apply_settings()}

  def handle_info(_message, state), do: {:noreply, state}

  # -- Hassock events --

  defp cache_event(:ready, cache, state),
    do: state |> mark_ready(:states, cache) |> set_status(:connected) |> schedule_rebuild()

  defp cache_event({:changes, changes}, _cache, state) do
    changed = Enum.map(changes.added, &elem(&1, 0)) ++ Enum.map(changes.changed, &elem(&1, 0))
    state = if changed != [], do: queue_states(state, changed), else: state

    # Entities that appear or go away change the model; state changes don't.
    if changes.added != [] or changes.removed != [], do: schedule_rebuild(state), else: state
  end

  defp cache_event(:disconnected, _cache, state), do: set_status(state, :disconnected)

  defp cache_event({:auth_failed, reason}, _cache, state) do
    Logger.warning("HA: Home Assistant refused the token (#{inspect(reason)})")
    set_status(state, {:auth_failed, reason})
  end

  defp cache_event(_event, _cache, state), do: state

  # State changes go to the :ha controller as one batch per
  # states_flush_ms, however fast Home Assistant sends them.
  defp queue_states(state, ids) do
    state = %{state | changed: Enum.into(ids, state.changed)}

    if state.flush_timer,
      do: state,
      else: %{
        state
        | flush_timer: Process.send_after(self(), :flush_states, state.opts.states_flush_ms)
      }
  end

  defp mark_ready(state, kind, pid) do
    case state.ready[kind] do
      {^pid, _ref} ->
        state

      old ->
        if old, do: Process.demonitor(elem(old, 1), [:flush])
        %{state | ready: Map.put(state.ready, kind, {pid, Process.monitor(pid)})}
    end
  end

  defp clear_ready(state) do
    for {_kind, {_pid, ref}} <- state.ready, do: Process.demonitor(ref, [:flush])
    %{state | ready: %{states: nil, registries: nil}}
  end

  # -- Model --

  defp schedule_rebuild(%{rebuild_timer: nil} = state),
    do: %{state | rebuild_timer: Process.send_after(self(), :rebuild, state.opts.rebuild_ms)}

  defp schedule_rebuild(state), do: state

  defp rebuild(%{ready: %{states: {_, _}, registries: {_, _}}} = state) do
    index = Index.build(state.registries_fun.(state.opts), state.state_ids_fun.(state.opts))
    revision = state.revision + 1
    store(state.table, index, revision)
    state.notify.({:model, revision})
    %{state | revision: revision}
  end

  defp rebuild(state), do: state

  # New rows first, then stale ones out, so a reader never finds the table
  # empty; each row is whole on its own. Public for tests that need a model
  # table without a connection.
  @doc false
  @spec store(atom() | :ets.tid(), Index.t(), non_neg_integer()) :: true
  def store(table, %Index{} = index, revision) do
    rows =
      [
        {:floors, index.floors},
        {:floorless_area_ids, index.floorless_area_ids},
        {:no_area_device_ids, index.no_area_device_ids},
        {:entity_ids, index.entities |> Map.keys() |> Enum.sort()}
      ] ++
        Enum.map(index.areas, fn {id, area} ->
          {{:area, id}, %{area: area, entity_ids: Map.get(index.area_entities, id, [])}}
        end) ++
        Enum.map(index.entities, fn {id, entity} -> {{:entity, id}, entity} end) ++
        Enum.map(index.devices, fn {id, device} -> {{:device, id}, device} end)

    :ets.insert(table, rows)
    keep = MapSet.new(rows, &elem(&1, 0))

    for [key] <- :ets.match(table, {:"$1", :_}),
        key not in [:revision, :status],
        not MapSet.member?(keep, key),
        do: :ets.delete(table, key)

    :ets.insert(table, {:revision, revision})
  end

  defp registries(opts) do
    cache = opts.registry_cache_name
    Map.new([:floor, :area, :device, :entity], &{&1, RegistryCache.list(cache, &1)})
  end

  defp state_ids(opts), do: opts.cache_name |> Cache.get_all() |> Enum.map(& &1.entity_id)

  # -- Settings and the connection --

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
    ha = state.settings_fun.().home_assistant

    cond do
      ha == state.ha ->
        state

      ha == nil ->
        Logger.info("HA: Home Assistant isn't configured")
        state |> stop() |> Map.put(:ha, nil) |> set_status(:unconfigured)

      true ->
        state |> stop() |> Map.put(:ha, ha) |> start()
    end
  end

  defp start(state) do
    case state.start_fun.(state.ha, state.opts) do
      {:ok, pid} ->
        %{clear_ready(state) | hassock: {pid, Process.monitor(pid)}}
        |> set_status(:connecting)

      {:error, reason} ->
        Logger.warning("HA: couldn't start hassock: #{inspect(reason)}")
        Process.send_after(self(), :restart_hassock, state.opts.restart_ms)
        set_status(state, :disconnected)
    end
  end

  defp stop(%{hassock: {pid, ref}} = state) do
    Process.demonitor(ref, [:flush])
    DynamicSupervisor.terminate_child(state.opts.conn_sup, pid)
    %{clear_ready(state) | hassock: nil}
  end

  defp stop(state), do: state

  defp start_hassock(%Settings.HomeAssistant{} = ha, opts) do
    spec =
      Supervisor.child_spec(
        {Hassock.Supervisor,
         config: config(ha),
         cache: true,
         registries: true,
         controller: self(),
         connection_name: opts.connection_name,
         cache_name: opts.cache_name,
         registry_cache_name: opts.registry_cache_name},
        # restarted by the model (monitor + :restart_hassock), not here
        restart: :temporary
      )

    DynamicSupervisor.start_child(opts.conn_sup, spec)
  end

  @doc false
  @spec config(Settings.HomeAssistant.t()) :: Hassock.Config.t()
  def config(%Settings.HomeAssistant{url: url, token: token, ssl_verify: verify?}) do
    %Hassock.Config{
      url: url,
      token: token,
      # nil: verify against the system CA store
      ssl_options: if(verify?, do: nil, else: [verify: :verify_none])
    }
  end

  defp set_status(%{status: status} = state, status), do: state

  defp set_status(state, status) do
    :ets.insert(state.table, {:status, status})
    state.notify.({:status, status})
    %{state | status: status}
  end

  defp notify_app({event, payload}) do
    if Process.whereis(PictureRail.App), do: Solve.dispatch(PictureRail.App, :ha, event, payload)
  end
end
