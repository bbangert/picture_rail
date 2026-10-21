defmodule PictureRail.App.PairingTest do
  use ExUnit.Case, async: true

  alias PictureRail.App.Pairing
  alias PictureRail.{QR, Web}

  @state %{code: "01234567", forget_failed?: false, address: "http://frame.local"}
  @connected %{status: :connected, ip: "192.168.1.40"}

  test "the QR code of the pairing link while connected, encoded once per link" do
    exposed = Pairing.expose(@state, %{network: @connected}, true)
    url = Web.pair_url("192.168.1.40", "01234567")
    assert exposed.qr == QR.encode(url)
    assert exposed.address == "http://frame.local"

    # another network report, the same link: the same runs, not re-encoded
    assert Process.get(Pairing) == {url, exposed.qr}
    again = Pairing.expose(@state, %{network: Map.put(@connected, :ssid, "Home")}, true)
    assert again.qr === exposed.qr
  end

  test "no QR code without a code or a connection" do
    assert Pairing.expose(%{@state | code: nil}, %{network: @connected}, true).qr == nil

    for network <- [nil, %{@connected | status: :disconnected}] do
      assert Pairing.expose(@state, %{network: network}, true).qr == nil
    end
  end
end
