defmodule PictureRail.NetworkTest do
  # the fake backend is a named singleton
  use ExUnit.Case, async: false

  alias PictureRail.Network
  alias PictureRail.Network.Fake

  defp ap(ssid, signal, flags),
    do: %{ssid: ssid, bssid: "b-#{ssid}-#{signal}", signal_percent: signal, flags: flags}

  test "networks: one per name, strongest first, hidden and mesh left out, security marked" do
    aps = [
      ap("Home", 40, [:wpa2, :psk, :ccmp, :ess]),
      ap("Home", 80, [:wpa2, :psk, :ccmp, :ess]),
      ap("", 90, [:wpa2, :psk]),
      ap("hid\0den", 90, [:psk]),
      ap("Mesh", 70, [:mesh]),
      ap("Cafe", 60, [:ess]),
      ap("New", 50, [:sae, :ess]),
      ap("Both", 50, [:sae, :psk]),
      ap("Work", 30, [:wpa2, :eap]),
      ap("Old", 20, [:wep])
    ]

    assert Network.networks(aps) == [
             %{ssid: "Home", signal: 80, security: :wpa2},
             %{ssid: "Cafe", signal: 60, security: :open},
             %{ssid: "Both", signal: 50, security: :wpa2},
             %{ssid: "New", signal: 50, security: :wpa3_only},
             %{ssid: "Work", signal: 30, security: :eap},
             %{ssid: "Old", signal: 20, security: :wep}
           ]
  end

  test "first boot: only with nothing configured and no network at all" do
    nothing = %{photo_source: false, home_assistant: false}
    assert Network.first_boot?(false, false, nothing)
    refute Network.first_boot?(true, false, nothing)
    refute Network.first_boot?(false, true, nothing)
    refute Network.first_boot?(false, false, %{nothing | home_assistant: true})
  end

  describe "joining" do
    setup do
      start_supervised!({Fake, running: %{ssid: "Old", password: "oldpassword", hidden?: false}})
      test = self()
      name = :"network_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Network,
         name: name,
         backend: Fake,
         notify: &send(test, {:report, &1}),
         held_ms: 50,
         trial_ms: 300,
         scan_ms: 30}
      )

      %{net: name}
    end

    defp connected(ssid) do
      Fake.send_event({:current_ap, %{ssid: ssid}})
      Fake.send_event({:addresses, [%{family: :inet, address: {192, 168, 1, 40}}]})
      Fake.send_event({:connection, :lan})
    end

    defp await_result do
      receive do
        {:report, %{result: result}} when result != nil -> result
      after
        2_000 -> flunk("no result")
      end
    end

    test "a network that holds a connection is kept and saved", %{net: net} do
      assert :ok = Network.join("Home", "goodpassword", false, net)
      assert %{trial: %{ssid: "Home"}} = Network.status(net)
      # the old network's password stays out of a crash report
      refute inspect(:sys.get_state(net)) =~ "oldpassword"
      connected("Home")

      assert await_result() == {:connected, "Home"}

      assert %{status: :connected, ssid: "Home", ip: "192.168.1.40", trial: nil} =
               Network.status(net)

      assert Fake.saved() == %{ssid: "Home", password: "goodpassword", hidden?: false}
      assert Enum.any?(Fake.calls(), &match?({:configure, %{ssid: "Home"}}, &1))
      assert :persist in Fake.calls()
    end

    test "a wrong password puts the old network back, unsaved", %{net: net} do
      # an old event, from before the trial: ignored
      Fake.send_event(
        {:wifi_event, %{name: "CTRL-EVENT-SSID-TEMP-DISABLED", ssid: "Home", reason: "WRONG_KEY"},
         System.monotonic_time()}
      )

      assert :ok = Network.join("Home", "badpassword", false, net)
      assert %{trial: %{ssid: "Home"}} = Network.status(net)

      Fake.send_event(
        {:wifi_event, %{name: "CTRL-EVENT-SSID-TEMP-DISABLED", ssid: "Home", reason: "WRONG_KEY"},
         System.monotonic_time()}
      )

      assert await_result() == {:failed, :wrong_password, "Home"}
      assert Fake.get_configuration() == %{ssid: "Old", password: "oldpassword", hidden?: false}
      refute :persist in Fake.calls()
    end

    test "no connection in time puts the old network back", %{net: net} do
      assert :ok = Network.join("Far", "goodpassword", false, net)
      # associated with something else: not a success
      connected("Old")
      assert await_result() == {:failed, :timeout, "Far"}
      assert Fake.get_configuration().ssid == "Old"
      refute :persist in Fake.calls()
    end

    test "a connection that drops and comes back has to hold again", %{net: net} do
      assert :ok = Network.join("Home", "goodpassword", false, net)
      connected("Home")
      Fake.send_event({:connection, :disconnected})
      # back before the first connection's hold (50 ms) is up
      Process.sleep(20)
      back = System.monotonic_time(:millisecond)
      Fake.send_event({:connection, :lan})

      assert await_result() == {:connected, "Home"}
      assert System.monotonic_time(:millisecond) - back >= 50
    end

    test "a connection that drops before it has held doesn't count", %{net: net} do
      assert :ok = Network.join("Home", "goodpassword", false, net)
      connected("Home")
      Fake.send_event({:connection, :disconnected})
      assert await_result() == {:failed, :timeout, "Home"}
    end

    test "without an access point from wpa_supplicant, a new connection still counts", %{net: net} do
      # on the old network, its address, no current_ap (as on the frame)
      Fake.send_event({:addresses, [%{family: :inet, address: {192, 168, 1, 40}}]})
      Fake.send_event({:connection, :internet})
      assert %{status: :connected, ssid: "Old"} = Network.status(net)

      assert :ok = Network.join("Home", "goodpassword", false, net)
      # wpa_supplicant restarts: the old link goes, the new one comes up
      Fake.send_event({:connection, :disconnected})
      Fake.send_event({:addresses, []})
      Fake.send_event({:addresses, [%{family: :inet, address: {192, 168, 1, 41}}]})
      Fake.send_event({:connection, :lan})

      assert await_result() == {:connected, "Home"}
      assert %{ssid: "Home", ip: "192.168.1.41"} = Network.status(net)
    end

    test "the old link staying up isn't a success", %{net: net} do
      Fake.send_event({:addresses, [%{family: :inet, address: {192, 168, 1, 40}}]})
      Fake.send_event({:connection, :internet})
      assert :ok = Network.join("Home", "goodpassword", false, net)
      assert await_result() == {:failed, :timeout, "Home"}
    end

    test "the same network and password, connected: nothing to do", %{net: net} do
      connected("Old")
      assert :ok = Network.join("Old", "oldpassword", false, net)
      assert await_result() == {:connected, "Old"}
      refute Enum.any?(Fake.calls(), &match?({:configure, _}, &1))
    end

    test "bad passwords are refused at once; hidden networks say so", %{net: net} do
      assert {:error, "The password needs at least 8 characters"} =
               Network.join("Home", "short", false, net)

      refute Enum.any?(Fake.calls(), &match?({:configure, _}, &1))

      assert :ok = Network.join("Secret", nil, true, net)
      assert {:configure, %{ssid: "Secret", password: nil, hidden?: true}} in Fake.calls()
      assert {:error, "Already joining Secret"} = Network.join("Home", "goodpassword", false, net)
    end

    test "watching scans now and again, but not during a trial", %{net: net} do
      Network.watch(net)
      assert %{scanning?: true} = Network.status(net)
      Process.sleep(100)
      scans = Enum.count(Fake.calls(), &(&1 == :scan))
      assert scans >= 2

      assert :ok = Network.join("Home", "goodpassword", false, net)
      # counted once the join is in: a scan already on its way may land first
      _ = :sys.get_state(net)
      scans = Enum.count(Fake.calls(), &(&1 == :scan))
      Process.sleep(100)
      assert Enum.count(Fake.calls(), &(&1 == :scan)) == scans
    end
  end
end
