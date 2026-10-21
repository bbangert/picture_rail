defmodule PictureRail.HA.ActionsTest do
  use ExUnit.Case, async: true

  alias Hassock.EntityState
  alias PictureRail.HA.Actions

  defp es(id, state), do: %EntityState{entity_id: id, state: state, attributes: %{}}

  test "a tap toggles what switches, runs what runs, and nothing else" do
    assert %{service: "turn_off", optimistic: "off"} =
             Actions.tap("light.hall", es("light.hall", "on"))

    assert %{service: "turn_on", optimistic: "on"} =
             Actions.tap("switch.fan", es("switch.fan", "off"))

    assert %{domain: "scene", service: "turn_on"} =
             Actions.tap("scene.movie", es("scene.movie", "scening"))

    assert Actions.tap("climate.hall", es("climate.hall", "heat")) == nil
    assert Actions.tap("light.hall", es("light.hall", "unavailable")) == nil
    assert Actions.tap("light.hall", nil) == nil
  end

  test "detail views, and a slider's service call" do
    assert Actions.detail?("climate.hall")
    refute Actions.detail?("scene.movie")

    assert %{
             domain: "light",
             data: %{brightness_pct: 40},
             optimistic_attrs: %{"brightness" => 102}
           } = Actions.slider("light.hall", :brightness, 40)

    assert %{service: "volume_set", data: %{volume_level: 0.25}} =
             Actions.slider("media_player.tv", :volume, 25)
  end
end
