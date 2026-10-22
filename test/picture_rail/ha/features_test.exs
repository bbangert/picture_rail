defmodule PictureRail.HA.FeaturesTest do
  use ExUnit.Case, async: true

  alias Hassock.EntityState
  alias PictureRail.HA.Features

  defp es(id, mask),
    do: %EntityState{entity_id: id, state: "on", attributes: %{"supported_features" => mask}}

  test "features by name, per domain" do
    # the Resideo T9s: target, range, turn on/off
    t9 = es("climate.t9", 387)
    assert Features.list(t9) == [:target_temperature, :target_range, :turn_off, :turn_on]
    refute Features.has?(t9, :fan_mode)

    # the Anthem receiver: no transport
    anthem = es("media_player.anthem", 69_004)
    assert Features.has?(anthem, :select_sound_mode)
    assert Features.has?(anthem, :volume_step)
    refute Features.has?(anthem, :pause)
  end

  test "nothing for an unknown feature, domain, mask or entity" do
    refute Features.has?(es("climate.t9", 387), :effect)
    refute Features.has?(es("sensor.x", 255), :open)

    refute Features.has?(
             %EntityState{entity_id: "lock.x", state: "locked", attributes: %{}},
             :open
           )

    refute Features.has?(nil, :open)
    assert Features.list(nil) == []
  end
end
