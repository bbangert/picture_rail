defmodule PictureRail.HA.EnergyPoller do
  @moduledoc """
  Keeps today's energy summary (`PictureRail.HA.Energy`) current.

  Every 5 minutes (every 30 s until the first success) it asks Home
  Assistant for the energy preferences, the statistics' units and today's
  statistics, in a task so it stays responsive while HA answers. Without a
  connection, or with no energy dashboard set up, it tries again next time.

  The latest summary is kept in a named ETS table (`latest/1` reads it
  without waiting on this process) and sent to the `:ha` controller as an
  `:energy` event.
  """
  use GenServer

  require Logger

  alias PictureRail.HA.Energy

  @defaults [
    table: :picture_rail_energy,
    connection: PictureRail.HA.Connection,
    task_sup: PictureRail.TaskSup,
    interval_ms: 300_000,
    retry_ms: 30_000
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "The latest summary, or `nil` before the first one (or without an energy dashboard)."
  @spec latest(atom()) :: Energy.t() | nil
  def latest(table \\ @defaults[:table]) do
    case :ets.lookup(table, :summary) do
      [{:summary, summary}] -> summary
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  # -- GenServer --

  @impl GenServer
  def init(opts) do
    opts = Keyword.merge(@defaults, opts)
    table = :ets.new(opts[:table], [:named_table, :protected, :set, read_concurrency: true])

    state = %{
      opts: Map.new(opts),
      table: table,
      command: Keyword.get(opts, :command, &Hassock.command/4),
      notify: Keyword.get(opts, :notify, &notify_app/1),
      task: nil,
      have?: false
    }

    {:ok, state, {:continue, :refresh}}
  end

  @impl GenServer
  def handle_continue(:refresh, state), do: handle_info(:refresh, state)

  @impl GenServer
  def handle_info(:refresh, %{task: nil} = state) do
    command = state.command
    conn = state.opts.connection

    task = Task.Supervisor.async_nolink(state.opts.task_sup, fn -> fetch(command, conn) end)
    {:noreply, %{state | task: task.ref}}
  end

  # a fetch is still running: its result schedules the next one
  def handle_info(:refresh, state), do: {:noreply, state}

  def handle_info({ref, result}, %{task: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, done(result, %{state | task: nil})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: ref} = state),
    do: {:noreply, done({:error, {:crashed, reason}}, %{state | task: nil})}

  def handle_info(_message, state), do: {:noreply, state}

  defp done({:ok, summary}, state) do
    :ets.insert(state.table, {:summary, summary})
    state.notify.(summary)
    schedule(state.opts.interval_ms)
    %{state | have?: true}
  end

  defp done({:error, reason}, state) do
    Logger.debug("HA energy: #{inspect(reason)}")
    schedule(if state.have?, do: state.opts.interval_ms, else: state.opts.retry_ms)
    state
  end

  defp schedule(ms), do: Process.send_after(self(), :refresh, ms)

  @doc false
  # The fetch itself, in the task. `command` is `Hassock.command/4`'s shape.
  @spec fetch((term(), String.t(), map(), keyword() -> term()), GenServer.server()) ::
          {:ok, Energy.t() | nil} | {:error, term()}
  def fetch(command, conn) do
    if GenServer.whereis(conn) do
      with {:ok, prefs} <- command.(conn, "energy/get_prefs", %{}, []) do
        summarize(command, conn, prefs)
      end
    else
      {:error, :no_connection}
    end
  end

  defp summarize(command, conn, prefs) do
    case Energy.statistic_ids(prefs) do
      [] ->
        {:ok, nil}

      ids ->
        now = DateTime.utc_now()

        with {:ok, meta} <-
               command.(conn, "recorder/get_statistics_metadata", %{statistic_ids: ids}, []),
             {:ok, day} <- statistics(command, conn, ids, "day", DateTime.add(now, -36 * 3600)),
             start when is_integer(start) <- Energy.day_start(day) || {:error, :no_data},
             {:ok, hour} <-
               statistics(command, conn, ids, "hour", DateTime.from_unix!(start, :millisecond)) do
          units = Map.new(meta, &{&1["statistic_id"], &1["statistics_unit_of_measurement"]})
          {:ok, Energy.summarize(prefs, day, hour, units)}
        end
    end
  end

  defp statistics(command, conn, ids, period, start) do
    command.(
      conn,
      "recorder/statistics_during_period",
      %{
        start_time: DateTime.to_iso8601(start),
        statistic_ids: ids,
        period: period,
        types: ["change"],
        units: %{energy: "kWh"}
      },
      timeout: 20_000
    )
  end

  defp notify_app(summary) do
    if Process.whereis(PictureRail.App),
      do: Solve.dispatch(PictureRail.App, :ha, :energy, summary)
  end
end
