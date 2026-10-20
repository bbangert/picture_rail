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
  Firmware that is already validated is left alone. Enabled with
  `config :picture_rail, firmware_guard: true` (the Nerves targets).

  Options, for tests: `:valid?`, `:validate`, `:reboot` and `:viewport`
  (functions standing in for `Nerves.Runtime` and `PictureRail.View.whereis/0`),
  `:view?`, and the `:steady_ms`, `:deadline_ms` and `:poll_ms` timings.
  """
  use GenServer, restart: :transient

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
    valid? = Keyword.get(opts, :valid?, &Nerves.Runtime.firmware_valid?/0)

    if valid?.() do
      :ignore
    else
      state = %{
        validate: Keyword.get(opts, :validate, &Nerves.Runtime.validate_firmware/0),
        reboot: Keyword.get(opts, :reboot, &Nerves.Runtime.reboot/0),
        viewport: Keyword.get(opts, :viewport, &PictureRail.View.whereis/0),
        view?: Keyword.get(opts, :view?, Application.get_env(:picture_rail, :start_view, true)),
        steady_ms: Keyword.get(opts, :steady_ms, @steady_ms),
        deadline: now() + Keyword.get(opts, :deadline_ms, @deadline_ms),
        poll_ms: Keyword.get(opts, :poll_ms, @poll_ms),
        # {viewport pid, when it was first seen}
        seen: nil
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

  defp check(state) do
    now = now()

    seen =
      case {viewport(state), state.seen} do
        {nil, _} -> nil
        {pid, {pid, since}} -> {pid, since}
        {pid, _} -> {pid, now}
      end

    state = %{state | seen: seen}

    cond do
      steady?(seen, now, state.steady_ms) ->
        validate(state, "the viewport has been up for #{div(state.steady_ms, 1000)} s")

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

  # A lookup that fails counts as no viewport. Above all it mustn't take
  # this process down: a :transient child that exits with {:shutdown, _}
  # (what a call to a stopping supervisor exits with) is neither logged
  # nor restarted, and nothing would be left to reboot.
  defp viewport(state) do
    state.viewport.()
  catch
    kind, reason ->
      Logger.warning("FirmwareGuard: viewport lookup failed: #{inspect({kind, reason})}")
      nil
  end

  defp steady?({_pid, since}, now, steady_ms), do: now - since >= steady_ms
  defp steady?(nil, _now, _steady_ms), do: false

  defp validate(state, why) do
    case state.validate.() do
      :ok -> Logger.info("FirmwareGuard: firmware validated (#{why})")
      other -> Logger.error("FirmwareGuard: validating the firmware failed: #{inspect(other)}")
    end

    {:stop, :normal, state}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
