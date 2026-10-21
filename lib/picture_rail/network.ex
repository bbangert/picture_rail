defmodule PictureRail.Network do
  @moduledoc """
  The frame's Wi-Fi: what it's connected to, the networks around, and
  joining one on trial.

  `join/3` tries a network without saving it:

    1. the same network and password as the running one, connected: done
    2. the configuration is built (bad passwords are refused at once) and
       applied, replacing the old network (one network at a time)
    3. it's kept once the old connection has gone and a new one has held
       a connection and an IPv4 address for 3 s (and, when wpa_supplicant
       says which access point it's on, that it's the chosen network):
       then saved. `current_ap` can't be required: when wpa_supplicant
       connects before VintageNetWiFi is listening (at boot, seen on the
       frame), it stays unset.
    4. a wrong password reported by wpa_supplicant (after the trial
       started), or no connection within 30 s, puts the previous
       configuration back

  A reboot during a trial comes back on the saved configuration, since
  the trial is never saved. While someone looks at the Wi-Fi page
  (`watch/0`), it rescans every 20 s, but never during a trial.

  Reports `%{status:, ssid:, ip:, networks:, scanning?:, trial:, result:}`
  to the `:network` controller: `status` `:connected` (a network and an
  address) or `:disconnected`; `trial` `%{ssid:, started_at:}` or nil;
  `result` the last join's outcome, `{:connected, ssid}` or
  `{:failed, :wrong_password | :timeout, ssid}`.
  """
  use GenServer

  require Logger

  alias PictureRail.Network.Backend

  @held_ms 3_000
  @trial_ms 30_000
  @scan_ms 20_000
  @watch_ms 300_000

  # -- Pure --

  @doc """
  The networks worth listing, from scan results: one per name (the
  strongest), hidden and mesh ones left out, strongest first. Each is
  `%{ssid:, signal:, security:}` with `security` `:open`, `:wpa2`,
  `:wpa3_only` (may not work on this Wi-Fi chip), `:eap` or `:wep` (not
  supported).
  """
  @spec networks([map()]) :: [%{ssid: String.t(), signal: integer(), security: atom()}]
  def networks(access_points) do
    access_points
    |> Enum.reject(fn ap ->
      ap.ssid in [nil, ""] or String.contains?(ap.ssid, <<0>>) or :mesh in ap.flags
    end)
    |> Enum.group_by(& &1.ssid)
    |> Enum.map(fn {ssid, aps} ->
      ap = Enum.max_by(aps, & &1.signal_percent)
      %{ssid: ssid, signal: ap.signal_percent, security: security(ap.flags)}
    end)
    |> Enum.sort_by(&{-&1.signal, &1.ssid})
  end

  defp security(flags) do
    cond do
      :eap in flags -> :eap
      :psk in flags -> :wpa2
      :sae in flags -> :wpa3_only
      :wep in flags -> :wep
      true -> :open
    end
  end

  @doc """
  Whether the frame should open Wi-Fi setup by itself: no Wi-Fi
  configured, no Ethernet, and nothing set up.
  """
  @spec first_boot?(boolean(), boolean(), map()) :: boolean()
  def first_boot?(wifi_configured?, ethernet_up?, configured) do
    not wifi_configured? and not ethernet_up? and not Enum.any?(Map.values(configured))
  end

  # -- API --

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Join a network on trial. `{:error, message}` for a configuration that
  can't work (a password too short); the outcome is reported as `result`.
  """
  @spec join(String.t(), String.t() | nil, boolean(), GenServer.server()) ::
          :ok | {:error, String.t()}
  def join(ssid, password, hidden? \\ false, server \\ __MODULE__),
    do: GenServer.call(server, {:join, ssid, password, hidden?})

  @doc "Someone is looking at the networks: scan now, and every 20 s for a while."
  @spec watch(GenServer.server()) :: :ok
  def watch(server \\ __MODULE__), do: GenServer.cast(server, :watch)

  @doc "The current report."
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  # -- GenServer --

  @impl GenServer
  def init(opts) do
    backend = Keyword.get_lazy(opts, :backend, &Backend.impl/0)
    backend.subscribe()

    state = %{
      backend: backend,
      notify: Keyword.get(opts, :notify, &notify_app/1),
      held_ms: Keyword.get(opts, :held_ms, @held_ms),
      trial_ms: Keyword.get(opts, :trial_ms, @trial_ms),
      scan_ms: Keyword.get(opts, :scan_ms, @scan_ms),
      connection: :disconnected,
      addresses: [],
      current_ap: nil,
      access_points: [],
      watch_until: nil,
      scan_timer: nil,
      trial: nil,
      result: nil
    }

    state = Enum.reduce(backend.current(), state, &apply_event/2)
    {:ok, report(state)}
  end

  @impl GenServer
  def handle_call(:status, _from, state), do: {:reply, report_of(state), state}

  def handle_call({:join, ssid, password, hidden?}, _from, state) do
    backend = state.backend

    cond do
      state.trial != nil ->
        {:reply, {:error, "Already joining #{state.trial.ssid}"}, state}

      connected?(state, ssid) and backend.running?(ssid, password) ->
        {:reply, :ok, report(%{state | result: {:connected, ssid}})}

      true ->
        start_trial(state, ssid, password, hidden?)
    end
  end

  @impl GenServer
  def handle_cast(:watch, state) do
    state = %{state | watch_until: now() + @watch_ms}
    {:noreply, if(state.scan_timer, do: state, else: scan(state))}
  end

  @impl GenServer
  def handle_info(:scan, state), do: {:noreply, scan(%{state | scan_timer: nil})}

  def handle_info({:held, ref}, %{trial: %{ref: ref, ok_since: since}} = state)
      when since != nil do
    {:noreply, commit(state)}
  end

  def handle_info({:trial_timeout, ref}, %{trial: %{ref: ref}} = state),
    do: {:noreply, revert(state, :timeout)}

  def handle_info(message, state) do
    case state.backend.event(message) do
      {:ok, event} -> {:noreply, event |> apply_event(state) |> check_trial() |> report()}
      :ignore -> {:noreply, state}
    end
  end

  # -- Events --

  defp apply_event({:connection, connection}, state), do: %{state | connection: connection}
  defp apply_event({:addresses, addresses}, state), do: %{state | addresses: addresses || []}
  defp apply_event({:current_ap, ap}, state), do: %{state | current_ap: ap}
  defp apply_event({:access_points, aps}, state), do: %{state | access_points: aps || []}

  # A wrong password for the network on trial, reported after it started
  # (the property keeps the last event, from any earlier attempt too).
  defp apply_event({:wifi_event, %{reason: "WRONG_KEY", ssid: ssid}, at}, %{trial: trial} = state)
       when trial != nil and ssid == trial.ssid and at > trial.started_at,
       do: %{state | trial: %{trial | wrong_key?: true}}

  defp apply_event(_event, state), do: state

  defp ipv4(state) do
    Enum.find_value(state.addresses, fn
      %{family: :inet, address: address} -> address |> :inet.ntoa() |> to_string()
      _ -> nil
    end)
  end

  defp connected?(state), do: state.connection in [:lan, :internet] and ipv4(state) != nil

  # Connected, and not known to be on another network.
  defp connected?(state, ssid) do
    connected?(state) and
      case state.current_ap do
        %{ssid: current} when current not in [nil, ""] -> current == ssid
        _ -> state.backend.configured_ssid() == ssid
      end
  end

  # -- Trial --

  defp start_trial(state, ssid, password, hidden?) do
    backend = state.backend

    case backend.build(ssid, password, hidden?) do
      {:ok, config} -> apply_trial(state, config, ssid)
      {:error, message} -> {:reply, {:error, message}, state}
    end
  end

  defp apply_trial(state, config, ssid) do
    previous = state.backend.get_configuration()
    state = cancel_scan(state)
    started_at = System.monotonic_time()

    case state.backend.configure(config) do
      :ok ->
        ref = make_ref()
        Process.send_after(self(), {:trial_timeout, ref}, state.trial_ms)
        Logger.info("Network: trying #{inspect(ssid)}")

        trial = %{
          ssid: ssid,
          ref: ref,
          started_at: started_at,
          previous: previous,
          ok_since: nil,
          dropped?: false,
          wrong_key?: false
        }

        {:reply, :ok, report(%{state | trial: trial, result: nil})}

      {:error, reason} ->
        {:reply, {:error, describe(reason)}, state}
    end
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)

  defp check_trial(%{trial: nil} = state), do: state
  defp check_trial(%{trial: %{wrong_key?: true}} = state), do: revert(state, :wrong_password)

  # The old connection has to go first (configure restarts
  # wpa_supplicant): until then a connection is the previous network's.
  defp check_trial(%{trial: %{dropped?: false} = trial} = state) do
    if connected?(state),
      do: state,
      else: check_trial(%{state | trial: %{trial | dropped?: true}})
  end

  defp check_trial(%{trial: trial} = state) do
    case {connected?(state, trial.ssid), trial.ok_since} do
      {true, nil} ->
        Process.send_after(self(), {:held, trial.ref}, state.held_ms)
        %{state | trial: %{trial | ok_since: now()}}

      {true, _since} ->
        state

      {false, _} ->
        %{state | trial: %{trial | ok_since: nil}}
    end
  end

  defp commit(%{trial: trial} = state) do
    case state.backend.persist() do
      :ok ->
        Logger.info("Network: joined #{inspect(trial.ssid)}, saved")

      error ->
        Logger.error(
          "Network: joined #{inspect(trial.ssid)} but couldn't save: #{inspect(error)}"
        )
    end

    report(%{state | trial: nil, result: {:connected, trial.ssid}})
  end

  defp revert(%{trial: trial} = state, reason) do
    Logger.warning("Network: #{inspect(trial.ssid)} failed (#{reason}), going back")

    case state.backend.configure(trial.previous) do
      :ok -> :ok
      error -> Logger.error("Network: couldn't put the previous network back: #{inspect(error)}")
    end

    report(%{state | trial: nil, result: {:failed, reason, trial.ssid}})
  end

  # -- Scanning --

  defp scan(%{trial: nil} = state) do
    if state.watch_until && now() < state.watch_until do
      case state.backend.scan() do
        :ok -> :ok
        error -> Logger.debug("Network: scan: #{inspect(error)}")
      end

      %{state | scan_timer: Process.send_after(self(), :scan, state.scan_ms)} |> report()
    else
      report(%{state | watch_until: nil})
    end
  end

  # no scans during a trial (a scan would be cancelled by configure anyway)
  defp scan(state),
    do: %{state | scan_timer: Process.send_after(self(), :scan, state.scan_ms)}

  defp cancel_scan(%{scan_timer: nil} = state), do: state

  defp cancel_scan(state) do
    Process.cancel_timer(state.scan_timer)
    %{state | scan_timer: nil}
  end

  # -- Report --

  defp report(state) do
    state.notify.(report_of(state))
    state
  end

  defp report_of(state) do
    %{
      status: if(connected?(state), do: :connected, else: :disconnected),
      ssid: ssid(state),
      ip: ipv4(state),
      networks: networks(state.access_points),
      scanning?: state.watch_until != nil,
      trial: state.trial && Map.take(state.trial, [:ssid, :started_at]),
      result: state.result
    }
  end

  defp ssid(state) do
    case state.current_ap do
      %{ssid: ssid} when ssid not in [nil, ""] -> ssid
      _ -> if connected?(state), do: state.backend.configured_ssid()
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp notify_app(report) do
    if Process.whereis(PictureRail.App),
      do: Solve.dispatch(PictureRail.App, :network, :status, report)

    :ok
  end
end
