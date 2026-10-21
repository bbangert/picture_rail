if Code.ensure_loaded?(VintageNet) do
  defmodule PictureRail.Network.VintageNet do
    @moduledoc """
    `PictureRail.Network.Backend` on VintageNet, for `wlan0` (and `eth0`'s
    link, for first boot).

    Trials apply with `persist: false`; `persist/0` saves the running
    configuration with `VintageNet.Persistence` directly, because
    configuring the same thing again is a no-op that saves nothing.
    Passwords go through `Cookbook.wpa_psk/2`, so only the derived PSK is
    kept, never the passphrase.
    """
    @behaviour PictureRail.Network.Backend

    alias VintageNetWiFi.{Cookbook, WPA2}

    @ifname "wlan0"
    @wifi ["interface", @ifname, "wifi"]
    @properties [
      {["interface", @ifname, "connection"], :connection},
      {["interface", @ifname, "addresses"], :addresses},
      {@wifi ++ ["current_ap"], :current_ap},
      {@wifi ++ ["access_points"], :access_points},
      {@wifi ++ ["event"], :wifi_event}
    ]

    @impl true
    def scan, do: VintageNet.scan(@ifname)

    @impl true
    def subscribe do
      for {property, _kind} <- @properties, do: VintageNet.subscribe(property)
      :ok
    end

    @impl true
    def event({VintageNet, property, _old, new, meta}) do
      case List.keyfind(@properties, property, 0) do
        {_, :wifi_event} when is_struct(new) ->
          {:ok, {:wifi_event, Map.from_struct(new), meta[:new_timestamp] || 0}}

        {_, :wifi_event} ->
          :ignore

        {_, kind} ->
          {:ok, {kind, new}}

        nil ->
          :ignore
      end
    end

    def event(_message), do: :ignore

    @impl true
    def current do
      for {property, kind} <- @properties,
          kind != :wifi_event,
          do: {kind, VintageNet.get(property)}
    end

    @impl true
    def get_configuration, do: VintageNet.get_configuration(@ifname)

    @impl true
    def configure(config), do: VintageNet.configure(@ifname, config, persist: false)

    @impl true
    def persist, do: VintageNet.Persistence.call(:save, [@ifname, get_configuration()])

    @impl true
    def build(ssid, password, hidden?) do
      built = if password, do: Cookbook.wpa_psk(ssid, password), else: Cookbook.open_wifi(ssid)

      case built do
        {:ok, config} when hidden? ->
          {:ok,
           update_in(
             config,
             [:vintage_net_wifi, :networks],
             &Enum.map(&1, fn n -> Map.put(n, :scan_ssid, 1) end)
           )}

        {:ok, config} ->
          {:ok, config}

        {:error, reason} ->
          {:error, describe(reason)}
      end
    end

    defp describe(:password_too_short), do: "The password needs at least 8 characters"
    defp describe(:password_too_long), do: "The password is too long (63 characters at most)"
    defp describe(:invalid_characters), do: "The password can only have plain (ASCII) characters"
    defp describe(:ssid_too_long), do: "The network name is too long"
    defp describe(:ssid_too_short), do: "Enter the network's name"
    defp describe(other), do: inspect(other)

    @impl true
    def running?(ssid, password) do
      case networks(get_configuration()) do
        [%{ssid: ^ssid} = network] -> same_key?(network, ssid, password)
        _ -> false
      end
    end

    defp same_key?(network, _ssid, nil), do: network[:key_mgmt] == :none

    defp same_key?(network, ssid, password) do
      case WPA2.to_psk(ssid, password) do
        {:ok, psk} -> network[:psk] == psk
        _ -> false
      end
    end

    @impl true
    def configured_networks?, do: networks(get_configuration()) != []

    defp networks(config), do: get_in(config, [:vintage_net_wifi, :networks]) || []

    @impl true
    def ethernet_up?, do: VintageNet.get(["interface", "eth0", "lower_up"]) == true
  end
end
