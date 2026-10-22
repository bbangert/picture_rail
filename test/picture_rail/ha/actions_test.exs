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

  test "locks and selects open their detail; sirens and remotes toggle" do
    assert Actions.detail?("lock.door")
    assert Actions.detail?("select.scene")
    assert Actions.tap("lock.door", es("lock.door", "locked")) == nil

    assert %{domain: "siren", service: "turn_on"} =
             Actions.tap("siren.door", es("siren.door", "unknown"))

    assert %{domain: "remote", service: "turn_off"} =
             Actions.tap("remote.tv", es("remote.tv", "on"))
  end

  test "a colour slider keeps the other half of the colour" do
    light = %EntityState{
      entity_id: "light.hue",
      state: "on",
      attributes: %{"hs_color" => [30.0, 64.0]}
    }

    assert %{data: %{hs_color: [200, 64.0]}, optimistic_attrs: %{"hs_color" => [200, 64.0]}} =
             Actions.slider("light.hue", :hue, 200, light)

    assert %{data: %{hs_color: [30.0, 10]}} = Actions.slider("light.hue", :saturation, 10, light)

    # off: no colour reported, so full saturation
    assert %{data: %{hs_color: [120, 100]}} =
             Actions.slider("light.hue", :hue, 120, es("light.hue", "off"))
  end

  describe "thermostats" do
    defp thermostat(attrs) do
      %EntityState{
        entity_id: "climate.t9",
        state: "heat_cool",
        attributes:
          Map.merge(
            %{"min_temp" => 50, "max_temp" => 90, "temperature" => nil},
            attrs
          )
      }
    end

    test "the step: the entity's own, else 1 in °F and 0.5 in °C" do
      assert Actions.climate_step(%{"target_temp_step" => 0.1, "max_temp" => 90}) == 0.1
      assert Actions.climate_step(%{"max_temp" => 90}) == 1
      assert Actions.climate_step(%{"max_temp" => 35}) == 0.5
      assert Actions.climate_step(%{}) == 0.5
    end

    test "heat/cool moves one end of the range, sending both" do
      t9 = thermostat(%{"target_temp_low" => 68, "target_temp_high" => 76})
      assert Actions.range?(t9)

      assert %{
               service: "set_temperature",
               data: %{target_temp_low: 69, target_temp_high: 76},
               optimistic_attrs: %{"target_temp_low" => 69, "target_temp_high" => 76}
             } = Actions.climate_target(t9, :low, 1)

      assert %{data: %{target_temp_low: 68, target_temp_high: 75}} =
               Actions.climate_target(t9, :high, -1)
    end

    test "the ends stay a step apart and inside the limits" do
      close = thermostat(%{"target_temp_low" => 74, "target_temp_high" => 75})
      assert Actions.climate_target(close, :low, 1) == nil
      assert Actions.climate_target(close, :high, -1) == nil

      edges = thermostat(%{"target_temp_low" => 50, "target_temp_high" => 90})
      assert Actions.climate_target(edges, :low, -1) == nil
      assert Actions.climate_target(edges, :high, 1) == nil

      # no room at all: nothing, rather than a value past a limit
      squeezed = thermostat(%{"target_temp_low" => 50, "target_temp_high" => 50})
      assert Actions.climate_target(squeezed, :low, -1) == nil
      assert Actions.climate_target(squeezed, :low, 1) == nil

      assert Actions.climate_target(
               %{
                 squeezed
                 | attributes: %{
                     squeezed.attributes
                     | "target_temp_low" => 90,
                       "target_temp_high" => 90
                   }
               },
               :high,
               1
             ) == nil
    end

    test "one target, on the step's grid" do
      heat = thermostat(%{"temperature" => 20.3, "max_temp" => 35, "min_temp" => 7})
      refute Actions.range?(heat)

      assert %{data: %{temperature: 21}, optimistic_attrs: %{"temperature" => 21}} =
               Actions.climate_target(heat, :temperature, 1)

      assert %{data: %{temperature: 20.5}} =
               Actions.climate_target(
                 %{heat | attributes: %{heat.attributes | "temperature" => 21}},
                 :temperature,
                 -1
               )

      # no target (off): nothing to move
      assert Actions.climate_target(thermostat(%{}), :temperature, 1) == nil
    end
  end

  test "lists to pick from, and the call that picks" do
    tv = %EntityState{
      entity_id: "media_player.tv",
      state: "on",
      attributes: %{"source_list" => ["HDMI 1", "TV"], "source" => "TV"}
    }

    assert Actions.options(tv, :source) == {["HDMI 1", "TV"], "TV"}
    assert Actions.options(tv, :sound_mode) == {[], nil}

    assert %{service: "select_source", data: %{source: "HDMI 1"}} =
             Actions.option("media_player.tv", :source, "HDMI 1")

    select = %EntityState{
      entity_id: "select.scene",
      state: "Relax",
      attributes: %{"options" => ["Relax", "Focus"]}
    }

    assert Actions.options(select, :option) == {["Relax", "Focus"], "Relax"}

    assert %{domain: "select", service: "select_option", optimistic: "Focus"} =
             Actions.option("select.scene", :option, "Focus")

    assert %{service: "set_hvac_mode", optimistic: "cool"} =
             Actions.option("climate.t9", :hvac_mode, "cool")

    assert %{service: "set_fan_mode", data: %{fan_mode: "auto"}} =
             Actions.option("climate.t9", :fan_mode, "auto")
  end

  test "grouping: join a player, take one out, or leave as the leader" do
    kitchen = %EntityState{
      entity_id: "media_player.kitchen",
      state: "playing",
      attributes: %{"group_members" => ["media_player.kitchen", "media_player.office"]}
    }

    assert %{
             service: "join",
             entity_id: "media_player.kitchen",
             data: %{group_members: ["media_player.den"]}
           } =
             Actions.group(kitchen, "media_player.den")

    assert %{service: "unjoin", entity_id: "media_player.office"} =
             Actions.group(kitchen, "media_player.office")

    # in the office's group, the kitchen (its leader) can't be taken out: the office leaves
    office = %{kitchen | entity_id: "media_player.office"}

    assert %{service: "unjoin", entity_id: "media_player.office"} =
             Actions.group(office, "media_player.kitchen")

    # no group reported: join
    assert %{service: "join"} = Actions.group(%{kitchen | attributes: %{}}, "media_player.den")
  end

  test "remote commands by integration" do
    assert %{select: "select", back: "menu", play_pause: "play_pause"} = Actions.pad("apple_tv")

    assert %{select: "Confirm", back: "Return", play: "Play", pause: "Pause"} =
             Actions.pad("braviatv")

    assert Actions.pad("broadlink") == nil
    assert Actions.pad(nil) == nil

    assert Actions.command("remote.loft", "up") == %{
             domain: "remote",
             service: "send_command",
             entity_id: "remote.loft",
             data: %{command: "up"}
           }

    assert Actions.detail?("remote.loft")
    assert Actions.detail?("camera.door")
    assert Actions.detail?("image.porch")
  end

  test "media toggles go from what's shown" do
    tv = %EntityState{
      entity_id: "media_player.tv",
      state: "on",
      attributes: %{"is_volume_muted" => true, "shuffle" => false, "repeat" => "all"}
    }

    assert %{data: %{is_volume_muted: false}} = Actions.toggle_mute(tv)
    assert %{data: %{shuffle: true}} = Actions.toggle_shuffle(tv)
    assert %{data: %{repeat: "one"}} = Actions.cycle_repeat(tv)

    for repeat <- [nil, "off"],
        do:
          assert(
            %{data: %{repeat: "all"}} =
              Actions.cycle_repeat(%{tv | attributes: %{"repeat" => repeat}})
          )

    assert %{data: %{repeat: "all"}} = Actions.cycle_repeat(%{tv | attributes: %{}})
    # on reports idle/playing/paused, off off/standby: nothing to hold
    assert Actions.power("media_player.tv", true) ==
             %{domain: "media_player", service: "turn_on", entity_id: "media_player.tv"}
  end
end
