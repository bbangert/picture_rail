defmodule PictureRail.HA.OverviewTest do
  use ExUnit.Case, async: true

  alias PictureRail.HA.{Index, Model, Overview}
  alias PictureRail.HAFixture

  describe "index" do
    setup do
      %{index: HAFixture.index()}
    end

    test "hidden, disabled, disabled-device and stateless entities are left out", %{index: index} do
      for id <- ~w(light.hidden light.old light.retired switch.not_loaded),
          do: refute(Map.has_key?(index.entities, id), id)

      # in categories: kept, for the summaries that count them
      assert Map.has_key?(index.entities, "sensor.hall_battery")
      # a state with no registry entry: kept, with no area
      assert %Index.Entity{area_id: nil, device_id: nil, entry: nil} = index.entities["sun.sun"]
    end

    test "an entity's area is its own, else its device's, else the parent device's",
         %{index: index} do
      assert index.entities["sensor.kitchen_temperature"].area_id == "kitchen"
      assert index.entities["light.ceiling"].area_id == "kitchen"
      assert index.entities["binary_sensor.garage_door"].area_id == "garage"
      assert index.entities["switch.plug"].area_id == nil
    end

    test "floors by level (none last), areas by name; unknown floors are floorless",
         %{index: index} do
      assert Enum.map(index.floors, &{&1.floor.floor_id, &1.area_ids}) == [
               {"ground", ["kitchen", "living"]},
               {"upstairs", ["bedroom"]},
               {"attic", []}
             ]

      assert index.floorless_area_ids == ["garage", "shed"]
      assert index.no_area_device_ids == ["dev_bridge", "dev_phone", "dev_plug"]
    end
  end

  describe "overview" do
    setup do
      %{src: HAFixture.source()}
    end

    test "summaries in HA's order with what's active", %{src: src} do
      %{summaries: summaries} = Overview.overview(src)

      assert Enum.map(summaries, &{&1.kind, &1.entity_ids, &1.active}) == [
               {:light, ["light.bedroom", "light.ceiling"], 1},
               {:climate, ["climate.hall"], 1},
               {:security, ["binary_sensor.garage_door", "lock.front"], 2},
               {:media_players, ["media_player.tv"], 1},
               {:maintenance,
                ["sensor.door_battery", "sensor.hall_battery", "sensor.phone_battery"], 1},
               {:persons, ["person.someone"], 1}
             ]
    end

    test "floors with areas (empty floors left out), floorless areas, devices",
         %{src: src} do
      overview = Overview.overview(src)

      assert Enum.map(overview.floors, fn f ->
               {f.floor.name,
                Enum.map(f.areas, &{&1.area.name, &1.temperature && &1.temperature.state})}
             end) == [
               {"Ground", [{"Kitchen", "21.5"}, {"Living room", nil}]},
               {"Upstairs", [{"Bedroom", nil}]}
             ]

      assert Enum.map(overview.other_areas, & &1.area.name) == ["Garage", "Shed"]
      assert overview.devices?
    end

    test "an area: summary sections, scenes, devices with a battery badge, automations",
         %{src: src} do
      view = Overview.area_view(src, "living")

      assert Enum.map(view.sections, &{&1.kind, &1.entity_ids}) == [
               {:climate, ["climate.hall"]},
               {:media_players, ["media_player.tv"]},
               {:scenes, ["scene.movie"]},
               {:device, ["sensor.hall_temperature"]},
               {:automations, ["automation.morning"]}
             ]

      device = Enum.find(view.sections, &(&1.kind == :device))
      assert %{name: "Hall thermostat", battery: "sensor.hall_battery"} = device
    end

    test "an area's readouts and its entities without a device, last", %{src: src} do
      view = Overview.area_view(src, "kitchen")

      assert view.temperature.state == "21.5"
      assert view.humidity.state == "40"

      # the ceiling light's only other entity is diagnostic: no device group
      assert Enum.map(view.sections, &{&1.kind, Map.get(&1, :device_id), &1.entity_ids}) == [
               {:light, nil, ["light.ceiling"]},
               {:device, nil, ["sensor.kitchen_humidity", "sensor.kitchen_temperature"]}
             ]
    end

    test "a battery-only device shows nothing; a parent's area counts", %{src: src} do
      assert [%{kind: :security, entity_ids: ["binary_sensor.garage_door"]}] =
               Overview.area_view(src, "garage").sections

      assert Overview.area_view(src, "gone") == nil
    end

    test "media players by area", %{src: src} do
      assert [%{area: %{area_id: "living"}, entity_ids: ["media_player.tv"]}] =
               Overview.media_view(src)
    end

    test "devices without an area, minus apps' devices and category-only devices",
         %{src: src} do
      assert [
               %{
                 device_id: "dev_plug",
                 name: "Plug",
                 entity_ids: ["switch.plug", "sensor.plug_energy"]
               }
             ] =
               Overview.devices_view(src)
    end
  end

  describe "a read overlapping a model rebuild" do
    # The model stores row by row: a list can name an entity whose row a
    # rebuild already removed. It counts as gone; nothing raises.
    setup do
      src = HAFixture.source()
      :ets.delete(src.table, {:entity, "sensor.hall_temperature"})
      :ets.delete(src.table, {:entity, "switch.plug"})
      :ets.delete(src.table, {:entity, "media_player.tv"})
      %{src: src}
    end

    test "every view still builds", %{src: src} do
      assert %{sections: _} = Overview.area_view(src, "living")
      assert [%{entity_ids: ["sensor.plug_energy"]}] = Overview.devices_view(src)
      # the thermostat's temperature row is gone; its other entity stays
      assert %{entity_ids: ["climate.hall"]} = Overview.device_view(src, "dev_thermostat")
      assert Overview.media_view(src) == []
      assert %{floors: _} = Overview.overview(src)
    end
  end

  test "summary pages: floor sections, area groups, then no area" do
    src = HAFixture.source()

    assert %{sections: sections} = Overview.summary_view(src, :maintenance)

    assert Enum.map(sections, fn s ->
             {s.title, Enum.map(s.groups, &{&1.title, &1.entity_ids})}
           end) ==
             [
               {"Ground", [{"Living room", ["sensor.hall_battery"]}]},
               {"Other areas", [{"Garage", ["sensor.door_battery"]}]},
               {"Other devices", [{nil, ["sensor.phone_battery"]}]}
             ]

    assert %{sections: [%{title: "Ground"}, %{title: "Upstairs"}]} =
             Overview.summary_view(src, :light)

    assert Overview.summary_view(src, :persons).sections == [
             %{title: "Devices", groups: [%{title: nil, entity_ids: ["person.someone"]}]}
           ]
  end

  test "navigation: floors with their areas, then other areas" do
    assert Overview.nav(HAFixture.source()) == [
             {:view, :overview, "Overview"},
             {:divider, "Ground"},
             {:view, {:area, "kitchen"}, "Kitchen"},
             {:view, {:area, "living"}, "Living room"},
             {:divider, "Upstairs"},
             {:view, {:area, "bedroom"}, "Bedroom"},
             {:divider, "Other areas"},
             {:view, {:area, "garage"}, "Garage"},
             {:view, {:area, "shed"}, "Shed"},
             {:view, :media, "Media"},
             {:view, :devices, "Devices"}
           ]
  end

  test "names: full from HA, own part under a device heading" do
    src = HAFixture.source()

    assert Overview.name(src, "sensor.hall_temperature") == "Hall thermostat Temperature"
    assert Overview.name(src, "sensor.hall_temperature", :own) == "Temperature"
    # no name of its own: the device's (the user's name for it first)
    assert Overview.name(src, "climate.hall", :own) == "Hall thermostat"
    assert Overview.name(src, "sun.sun", :own) == "Sun"
    # maintenance pages go by the device (and a battery without one by itself)
    assert Overview.name(src, "sensor.door_battery", :device) == "Door sensor"
    assert Overview.name(src, "sun.sun", :device) == "Sun"
  end

  test "availability: unavailable, unknown and missing states are greyed out" do
    src = HAFixture.source()

    assert Overview.available?(src.state.("light.ceiling"))
    refute Overview.available?(src.state.("switch.plug"))
    refute Overview.available?(%{src.state.("light.ceiling") | state: "unknown"})
    refute Overview.available?(nil)
  end

  test "a scene never run (unknown) still works" do
    src = HAFixture.source()
    assert Overview.available?(src.state.("scene.movie"))
    refute Overview.available?(%{src.state.("scene.movie") | state: "unavailable"})
  end

  test "a rebuilt model drops what's gone and keeps the revision current" do
    src = HAFixture.source()
    registries = HAFixture.registries()
    smaller = %{registries | area: Enum.reject(registries.area, &(&1.area_id == "shed"))}

    Model.store(src.table, Index.build(smaller, Map.keys(HAFixture.states())), 2)

    assert Model.area("shed", src.table) == nil
    assert Model.floorless_area_ids(src.table) == ["garage"]
    assert Model.revision(src.table) == 2
  end
end
