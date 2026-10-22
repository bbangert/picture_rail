defmodule PictureRail.HA.PendingTest do
  use ExUnit.Case, async: true

  alias Hassock.EntityState
  alias PictureRail.HA.{Actions, Pending}

  defp es(id, state, attrs), do: %EntityState{entity_id: id, state: state, attributes: attrs}

  defp put(pending, request), do: Pending.put(pending, request, make_ref())

  test "each value settles on its own" do
    light = es("light.a", "on", %{"hs_color" => [30.0, 64.0], "brightness" => 255})

    pending =
      %{}
      |> put(Actions.color("light.a", [200, 64]))
      |> put(Actions.slider("light.a", :brightness, 40))

    # HA has the brightness, not the hue yet: the hue stays
    pending =
      Pending.settle(pending, "light.a", %{
        light
        | attributes: %{light.attributes | "brightness" => 102}
      })

    assert %{"light.a" => %{attrs: %{"hs_color" => {[200, 64], _}}}} = pending
    refute Map.has_key?(pending["light.a"].attrs, "brightness")

    shown = Pending.shown(light, pending["light.a"])
    assert shown.attributes["hs_color"] == [200, 64]
    assert shown.attributes["brightness"] == 255

    assert Pending.settle(pending, "light.a", %{
             light
             | attributes: %{"hs_color" => [199.0, 63.0]}
           }) == %{}
  end

  test "a colour and a colour temperature replace each other" do
    pending = put(%{}, Actions.slider("light.a", :color_temp, 3000))
    pending = put(pending, Actions.color("light.a", [200, 64]))
    refute Map.has_key?(pending["light.a"].attrs, "color_temp_kelvin")

    pending = put(pending, Actions.slider("light.a", :color_temp, 2700))
    refute Map.has_key?(pending["light.a"].attrs, "hs_color")
    assert %{"color_temp_kelvin" => {2700, _}} = pending["light.a"].attrs
  end

  test "a new mode ends the old mode's setpoints" do
    t9 =
      es("climate.t9", "heat", %{
        "temperature" => 70,
        "min_temp" => 50,
        "max_temp" => 90
      })

    pending = put(%{}, Actions.climate_target(t9, :temperature, 1))
    pending = put(pending, Actions.option("climate.t9", :hvac_mode, "heat_cool"))
    assert pending["climate.t9"].attrs == %{}

    # HA's range-mode report settles it
    report = es("climate.t9", "heat_cool", %{"temperature" => nil, "target_temp_low" => 68})
    assert Pending.settle(pending, "climate.t9", report) == %{}
  end

  test "another state ends the attributes pending for the old one" do
    pending = put(%{}, Actions.slider("light.a", :brightness, 40))

    pending =
      put(pending, %{
        domain: "light",
        service: "turn_off",
        entity_id: "light.a",
        optimistic: "off"
      })

    assert %{state: {"off", _}, attrs: attrs} = pending["light.a"]
    assert attrs == %{}
  end

  test "off ends what was pending for on, also once on is reported" do
    pending = put(%{}, Actions.color("light.a", [200, 64]))

    # HA has turned it on, the colour isn't there yet
    pending =
      Pending.settle(pending, "light.a", es("light.a", "on", %{"hs_color" => [30.0, 64.0]}))

    assert %{state: nil, attrs: %{"hs_color" => _}} = pending["light.a"]

    off = %{domain: "light", service: "turn_off", entity_id: "light.a", optimistic: "off"}
    assert %{state: {"off", _}, attrs: attrs} = put(pending, off)["light.a"]
    assert attrs == %{}
  end

  test "a colour temperature after off turns it on" do
    off = %{domain: "light", service: "turn_off", entity_id: "light.a", optimistic: "off"}
    pending = %{} |> put(off) |> put(Actions.slider("light.a", :color_temp, 2700))
    assert %{state: {"on", _}} = pending["light.a"]

    report = es("light.a", "on", %{"color_temp_kelvin" => 2702})
    assert Pending.settle(pending, "light.a", report) == %{}
  end

  test "a failure or an expiry ends only its own call's values" do
    first = make_ref()
    second = make_ref()

    pending =
      %{}
      |> Pending.put(Actions.color("light.a", [200, 64]), first)
      |> Pending.put(Actions.slider("light.a", :brightness, 40), second)

    assert %{state: {"on", ^second}, attrs: attrs} = Pending.drop(pending, first)["light.a"]
    assert Map.keys(attrs) == ["brightness"]

    assert Pending.expire(pending, "light.a", second)["light.a"].attrs |> Map.keys() == [
             "hs_color"
           ]

    assert Pending.expire(pending, "light.b", second) == pending
    assert pending |> Pending.drop(first) |> Pending.drop(second) == %{}
  end

  test "white is white whatever the hue" do
    pending = put(%{}, Actions.color("light.a", [200, 0]))

    assert Pending.settle(pending, "light.a", es("light.a", "on", %{"hs_color" => [0.0, 0.0]})) ==
             %{}

    # a colour still needs its hue
    pending = put(%{}, Actions.color("light.a", [200, 50]))

    refute Pending.settle(pending, "light.a", es("light.a", "on", %{"hs_color" => [0.0, 50.0]})) ==
             %{}
  end
end
