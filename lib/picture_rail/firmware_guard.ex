defmodule PictureRail.FirmwareGuard do
  @moduledoc """
  Marks new firmware good once the viewport has run steadily, and reboots
  into the previous firmware if it doesn't.

  This replaces nerves_runtime's startup guard, which validates as soon as
  the applications have started: before the viewport has drawn anything,
  so a renderer that crashes the VM moments later would leave a validated
  slot in a reboot loop. Here the firmware is validated once the same
  viewport process has been up for 30 s. If that hasn't happened 3 minutes
  after this starts (the viewport kept crashing and its supervisor gave
  up), it reboots, and firmware still on trial boots the previous one.

  It starts after the rest of the app, so when the viewport isn't started
  at boot (`start_view: false`) the firmware is validated straight away.
  Firmware that is already validated is left alone, and so is firmware
  validated some other way (by hand over SSH) before the deadline. If
  validating fails, it's retried every 30 s; the guard stays up rather than
  crashing, since a restart storm would take the app down with it. The
  3 minutes count from this process's start, so they begin again if it's
  restarted. Enabled with `config :picture_rail, firmware_guard: true` (the
  Nerves targets).

  It also completes nerves_heart's init handshake when it starts, which
  nerves_runtime's startup guard used to do: without it, heart reboots the
  device 10 minutes after boot.

  Options, for tests: `:init_complete`, `:valid?`, `:validate`, `:reboot` and
  `:viewport` (functions standing in for `Nerves.Runtime`,
  `Nerves.Runtime.Heart` and `PictureRail.View.whereis/0`),
  `:view?`, and the `:steady_ms`, `:deadline_ms` and `:poll_ms` timings.
  """
  use GenServer, restart: :transient

  alias Nerves.Runtime.Heart

  require Logger

  @steady_ms 30_000
  @deadline_ms 180_000
  @poll_ms 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl GenServer
  def init(opts) do
    # nerves_heart reboots the device unless the app completes its init
    # handshake within HEART_INIT_TIMEOUT (rel/vm.args.eex). nerves_runtime's
    # startup guard did that; this does it now, validated firmware or not.
    Keyword.get(opts, :init_complete, &Heart.init_complete/0).()

    valid? = Keyword.get(opts, :valid?, &Nerves.Runtime.firmware_valid?/0)

    if valid?.() do
      :ignore
    else
      state = %{
        valid?: valid?,
        validate: Keyword.get(opts, :validate, &Nerves.Runtime.validate_firmware/0),
        reboot: Keyword.get(opts, :reboot, &Nerves.Runtime.reboot/0),
        viewport: Keyword.get(opts, :viewport, &PictureRail.View.whereis/0),
        view?: Keyword.get(opts, :view?, Application.get_env(:picture_rail, :start_view, true)),
        steady_ms: Keyword.get(opts, :steady_ms, @steady_ms),
        deadline: now() + Keyword.get(opts, :deadline_ms, @deadline_ms),
        poll_ms: Keyword.get(opts, :poll_ms, @poll_ms),
        # {viewport pid, when it was first seen}
        seen: nil,
        lookup_failed?: false
      }

      {:ok, state, {:continue, :check}}
    end
  end

  @impl GenServer
  def handle_continue(:check, %{view?: false} = state) do
    validate(state, "the viewport isn't started at boot")
  end

  def handle_continue(:check, state), do: check(state)

  @impl GenServer
  def handle_info(:check, state), do: check(state)
  def handle_info({:validate, why}, state), do: validate(state, why)

  defp check(state) do
    now = now()
    {pid, state} = viewport(state)

    seen =
      case {pid, state.seen} do
        {nil, _} -> nil
        {pid, {pid, since}} -> {pid, since}
        {pid, _} -> {pid, now}
      end

    state = %{state | seen: seen}

    cond do
      steady?(seen, now, state.steady_ms) ->
        validate(state, "the viewport has been up for #{div(state.steady_ms, 1000)} s")

      now >= state.deadline and state.valid?.() ->
        Logger.info("FirmwareGuard: the firmware was validated by something else")
        {:stop, :normal, state}

      now >= state.deadline ->
        Logger.error(
          "FirmwareGuard: the viewport never ran steadily; rebooting into the previous firmware"
        )

        state.reboot.()
        {:stop, :normal, state}

      true ->
        Process.send_after(self(), :check, state.poll_ms)
        {:noreply, state}
    end
  end

  # A failed lookup counts as no viewport, and never takes this process
  # down: an exit with {:shutdown, _} would end a :transient child without
  # a log or a restart, leaving nothing to reboot. Logged once per run of
  # failures.
  defp viewport(state) do
    {state.viewport.(), %{state | lookup_failed?: false}}
  catch
    kind, reason ->
      unless state.lookup_failed?,
        do: Logger.warning("FirmwareGuard: viewport lookup failed: #{inspect({kind, reason})}")

      {nil, %{state | lookup_failed?: true}}
  end

  defp steady?({_pid, since}, now, steady_ms), do: now - since >= steady_ms
  defp steady?(nil, _now, _steady_ms), do: false

  defp validate(state, why) do
    case state.validate.() do
      :ok ->
        Logger.info("FirmwareGuard: firmware validated (#{why})")
        {:stop, :normal, state}

      other ->
        Logger.error(
          "FirmwareGuard: validating the firmware failed: #{inspect(other)}; " <>
            "retrying in #{div(state.steady_ms, 1000)} s"
        )

        Process.send_after(self(), {:validate, why}, state.steady_ms)
        {:noreply, state}
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
