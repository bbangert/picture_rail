defmodule PictureRail.Network.Fake do
  @moduledoc """
  A stand-in `PictureRail.Network.Backend` for the host and tests: an
  Agent holding the "running" and "saved" configurations, with the
  subscriber's events sent by hand (`send_event/1`, or from a test).

  Configurations are plain maps: `%{ssid:, password:, hidden?:}`, or
  `%{}` for none.
  """
  @behaviour PictureRail.Network.Backend

  use Agent

  @doc "Start it (registered under this module's name)."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    state = %{
      running: Keyword.get(opts, :running, %{}),
      saved: Keyword.get(opts, :running, %{}),
      subscriber: nil,
      access_points: Keyword.get(opts, :access_points, []),
      calls: []
    }

    Agent.start_link(fn -> state end, name: __MODULE__)
  end

  @doc "What's been asked of it, oldest first (`{:configure, config}`, `:scan`, `:persist`)."
  @spec calls() :: [term()]
  def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))

  @doc "The saved configuration."
  @spec saved() :: map()
  def saved, do: Agent.get(__MODULE__, & &1.saved)

  @doc "Send the subscriber an event."
  @spec send_event(PictureRail.Network.Backend.event()) :: :ok
  def send_event(event) do
    if pid = Agent.get(__MODULE__, & &1.subscriber), do: send(pid, {__MODULE__, event})
    :ok
  end

  defp record(call), do: Agent.update(__MODULE__, &%{&1 | calls: [call | &1.calls]})

  @impl true
  def scan do
    record(:scan)
    send_event({:access_points, Agent.get(__MODULE__, & &1.access_points)})
  end

  @impl true
  def subscribe do
    pid = self()
    Agent.update(__MODULE__, &%{&1 | subscriber: pid})
  end

  @impl true
  def event({__MODULE__, event}), do: {:ok, event}
  def event(_message), do: :ignore

  @impl true
  def current, do: [{:connection, :disconnected}, {:addresses, []}, {:current_ap, nil}]

  @impl true
  def get_configuration, do: Agent.get(__MODULE__, & &1.running)

  @impl true
  def configure(config) do
    record({:configure, config})
    Agent.update(__MODULE__, &%{&1 | running: config})
  end

  @impl true
  def persist do
    record(:persist)
    Agent.update(__MODULE__, &%{&1 | saved: &1.running})
  end

  @impl true
  def build(_ssid, password, _hidden?) when is_binary(password) and byte_size(password) < 8,
    do: {:error, "The password needs at least 8 characters"}

  def build(ssid, password, hidden?),
    do: {:ok, %{ssid: ssid, password: password, hidden?: hidden?}}

  @impl true
  def running?(ssid, password) do
    match?(%{ssid: ^ssid, password: ^password}, get_configuration())
  end

  @impl true
  def configured_ssid, do: Map.get(get_configuration(), :ssid)

  @impl true
  def configured_networks?, do: Map.has_key?(get_configuration(), :ssid)

  @impl true
  def ethernet_up?, do: false
end
