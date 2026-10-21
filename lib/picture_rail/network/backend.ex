defmodule PictureRail.Network.Backend do
  @moduledoc """
  What `PictureRail.Network` needs from the network stack, as a behaviour:
  VintageNet on the device (`PictureRail.Network.VintageNet`), a scripted
  stand-in on the host and in tests (`PictureRail.Network.Fake`). Chosen
  with `config :picture_rail, network_backend: ...`.

  Changes reach the subscriber as messages the backend turns into events
  with `event/1`:

    * `{:connection, :disconnected | :lan | :internet}`
    * `{:addresses, [%{family: :inet | :inet6, address: tuple}]}`
    * `{:current_ap, access_point | nil}` - `%{ssid: ...}` while associated
    * `{:access_points, [access_point]}` - scan results: maps or structs
      with `:ssid`, `:bssid`, `:signal_percent` and `:flags`
    * `{:wifi_event, %{name:, ssid:, reason:}, timestamp}` - wpa_supplicant's
      last event; `timestamp` in `System.monotonic_time/0` units
  """

  @type event ::
          {:connection, :disconnected | :lan | :internet}
          | {:addresses, [map()]}
          | {:current_ap, map() | nil}
          | {:access_points, [map()]}
          | {:wifi_event, map(), integer()}

  @doc "Ask for a scan; results come as `{:access_points, list}`."
  @callback scan() :: :ok | {:error, term()}

  @doc "Subscribe the caller to Wi-Fi changes."
  @callback subscribe() :: :ok

  @doc "Turn a message the subscriber got into an event."
  @callback event(message :: term()) :: {:ok, event()} | :ignore

  @doc "The current values, as events, for a fresh subscriber."
  @callback current() :: [event()]

  @doc "The running Wi-Fi configuration."
  @callback get_configuration() :: map()

  @doc "Apply a configuration without saving it (a reboot brings back the saved one)."
  @callback configure(map()) :: :ok | {:error, term()}

  @doc "Save the running configuration, so it's there after a reboot."
  @callback persist() :: :ok | {:error, term()}

  @doc "A configuration joining one network: WPA2 with a password, or open (`nil`)."
  @callback build(ssid :: String.t(), password :: String.t() | nil, hidden? :: boolean()) ::
              {:ok, map()} | {:error, String.t()}

  @doc "Whether the running configuration already is this network and password."
  @callback running?(ssid :: String.t(), password :: String.t() | nil) :: boolean()

  @doc "The name of the network the running configuration joins (`nil` for none)."
  @callback configured_ssid() :: String.t() | nil

  @doc "Whether any Wi-Fi network is configured."
  @callback configured_networks?() :: boolean()

  @doc "Whether wired Ethernet has a link."
  @callback ethernet_up?() :: boolean()

  @doc "The configured backend."
  @spec impl() :: module()
  def impl, do: Application.get_env(:picture_rail, :network_backend, PictureRail.Network.Fake)
end
