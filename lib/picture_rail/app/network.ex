defmodule PictureRail.App.Network do
  @moduledoc """
  `:network` controller: the Wi-Fi status, the networks around and how a
  join is going, as reported by `PictureRail.Network` (see there for the
  shape).
  """
  use Solve.Controller, events: [:status]

  @impl Solve.Controller
  # A restarted controller asks the network process again.
  def init(_params, _dependencies) do
    if Process.whereis(PictureRail.Network),
      do: PictureRail.Network.status(),
      else: %{
        status: :disconnected,
        ssid: nil,
        ip: nil,
        networks: [],
        scanning?: false,
        trial: nil,
        result: nil
      }
  end

  def status(report, _state), do: report
end
