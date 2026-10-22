defmodule PictureRail.App.HATest do
  use ExUnit.Case, async: true

  alias Hassock.EntityState
  alias PictureRail.App.HA
  alias PictureRail.HA.{Actions, Index, Model, Overview}
  alias PictureRail.HAFixture

  # The source reads entity states from the test process, so a test can
  # play Home Assistant reporting a change (`report/2`).
  setup do
    Process.put(:states, HAFixture.states())
    src = %{HAFixture.source() | state: &Map.get(Process.get(:states), &1)}

    state = %{
      status: :connected,
      revision: 1,
      tick: 0,
      pending: %{},
      error: nil,
      energy: nil,
      sliding: %{},
      armed: %{}
    }

    %{src: src, params: %{source: src}, state: state}
  end

  defp report(id, fun), do: Process.put(:states, Map.update!(Process.get(:states), id, fun))

  defp panel(view, visible? \\ true), do: %{panel: %{visible?: visible?, view: view}}

  defp light_off(state, callbacks) do
    HA.start_call(
      %{domain: "light", service: "turn_off", entity_id: "light.ceiling", optimistic: "off"},
      state,
      callbacks
    )
  end

  test "no slice while the panel is down", %{state: state, params: params} do
    assert %{slice: nil, states: states, view: nil, nav: []} =
             HA.expose(state, panel(:overview, false), params)

    assert states == %{}
  end

  test "the slice, its states and the navigation follow the panel", %{
    state: state,
    params: params
  } do
    %{slice: overview, states: states, nav: nav} = HA.expose(state, panel(:overview), params)
    assert [%{kind: :light} | _] = overview.summaries
    assert states["light.ceiling"].state == "on"
    assert Map.has_key?(states, "sensor.kitchen_temperature")
    assert [{:view, :overview, "Overview"} | _] = nav

    %{slice: area} = HA.expose(state, panel({:area, "living"}), params)
    assert area.area.area_id == "living"
  end

  test "names of what's on screen, in each form; a renamed entity follows", %{
    state: state,
    src: src,
    params: params
  } do
    deps = panel({:area, "living"})
    %{states: states, names: names} = HA.expose(state, deps, params)

    for id <- Map.keys(states), form <- [:full, :own, :device] do
      assert names[{id, form}] == Overview.name(src, id, form)
    end

    id = "media_player.tv"
    assert Map.has_key?(states, id)

    report(id, fn es ->
      %{es | attributes: Map.put(es.attributes, "friendly_name", "Big Light")}
    end)

    # Home Assistant reports the change: the on-screen tick moves
    state = HA.states([id], state, deps, %{}, params)
    assert HA.expose(state, deps, params).names[{id, :full}] == "Big Light"
  end

  test "loading before the first build; gone when it was removed", %{
    state: state,
    params: params
  } do
    assert %{slice: :loading} = HA.expose(%{state | revision: 0}, panel(:overview), params)
    assert %{slice: :gone} = HA.expose(state, panel({:area, "nowhere"}), params)
    assert %{slice: :gone} = HA.expose(state, panel({:device, "nothing"}), params)
    assert %{slice: :gone} = HA.expose(state, panel({:entity, "light.nothing"}), params)
  end

  test "the slice is computed once per view, revision and on-screen change", %{
    state: state,
    params: params,
    src: src
  } do
    deps = panel({:area, "kitchen"})
    %{slice: before} = HA.expose(state, deps, params)

    # The model loses the kitchen. An off-screen change: the cached slice
    # stands (recomputing it would now say :gone).
    :ets.delete(src.table, {:area, "kitchen"})
    state = HA.states(["light.bedroom"], state, deps, %{}, params)
    assert state.tick == 0
    assert %{slice: ^before} = HA.expose(state, deps, params)

    # an on-screen change recomputes it
    state = HA.states(["light.ceiling"], state, deps, %{}, params)
    assert state.tick == 1
    assert %{slice: :gone} = HA.expose(state, deps, params)
  end

  test "a device's entities aren't on screen in its area, only on its own page", %{
    state: state,
    params: params
  } do
    %{states: states} = HA.expose(state, panel({:area, "living"}), params)
    assert Map.has_key?(states, "sensor.hall_battery")
    refute Map.has_key?(states, "sensor.hall_temperature")

    area = panel({:area, "living"})
    assert HA.states(["sensor.hall_temperature"], state, area, %{}, params).tick == 0

    device = panel({:device, "dev_thermostat"})
    assert HA.states(["sensor.hall_temperature"], state, device, %{}, params).tick == 1
  end

  test "a summary's slice is its floor/area groups", %{state: state, params: params} do
    %{slice: slice, states: states} = HA.expose(state, panel({:summary, :maintenance}), params)
    assert %{kind: :maintenance, sections: [_ | _]} = slice

    assert states |> Map.keys() |> Enum.sort() ==
             ~w(sensor.door_battery sensor.hall_battery sensor.phone_battery)
  end

  test "an optimistic value shows at once and ends when HA reports it", %{
    state: state,
    params: params
  } do
    state = light_off(state, %{call_service: fn _ -> %{ref: make_ref()} end})
    assert HA.expose(state, panel(:overview), params).states["light.ceiling"].state == "off"

    # a report that isn't the new value (sent before the call ran) leaves it
    state = HA.states(["light.ceiling"], state, panel(:overview), %{}, params)
    assert %{"light.ceiling" => _} = state.pending

    report("light.ceiling", &%{&1 | state: "off"})
    state = HA.states(["light.ceiling"], state, panel(:overview), %{}, params)
    assert state.pending == %{}
  end

  test "a failed call rolls back and reports the error", %{state: state, params: params} do
    ref = make_ref()

    state =
      state
      |> light_off(%{call_service: fn _ -> %{ref: ref} end})
      |> then(&HA.call_done(ref, {:error, :timeout}, &1))

    exposed = HA.expose(state, panel(:overview), params)
    assert exposed.states["light.ceiling"].state == "on"
    assert exposed.error == :timeout
  end

  test "optimistic attributes (a slider) settle within HA's rounding", %{
    state: state,
    params: params
  } do
    request = %{
      domain: "light",
      service: "turn_on",
      entity_id: "light.ceiling",
      data: %{brightness_pct: 80},
      optimistic_attrs: %{"brightness" => 204}
    }

    state = HA.start_call(request, state, %{call_service: fn _ -> %{ref: make_ref()} end})
    shown = HA.expose(state, panel({:entity, "light.ceiling"}), params).states["light.ceiling"]
    assert shown.attributes["brightness"] == 204
    assert shown.state == "on"

    report("light.ceiling", fn %EntityState{} = es ->
      %{es | attributes: Map.put(es.attributes, "brightness", 203)}
    end)

    state = HA.states(["light.ceiling"], state, panel({:entity, "light.ceiling"}), %{}, params)
    assert state.pending == %{}
  end

  # callbacks that tell the test what the controller did
  defp callbacks do
    test = self()

    %{
      call_service: fn request ->
        send(test, {:called, request})
        %{ref: make_ref()}
      end,
      open: &send(test, {:opened, &1}),
      activity: fn -> send(test, :activity) end
    }
  end

  test "a press: long opens the detail; a tap toggles, or opens what can't be tapped", %{
    state: state,
    params: params
  } do
    deps = panel(:overview)

    HA.press({"light.ceiling", true}, state, deps, callbacks(), params)
    assert_received {:opened, {:entity, "light.ceiling"}}
    refute_received {:called, _}

    state = HA.press({"light.ceiling", false}, state, deps, callbacks(), params)
    assert_received {:called, %{entity_id: "light.ceiling", service: "turn_off"}}
    assert {"off", _ref} = state.pending["light.ceiling"].state

    # a tap again goes by what's shown (off, pending): on
    HA.press({"light.ceiling", false}, state, deps, callbacks(), params)
    assert_received {:called, %{entity_id: "light.ceiling", service: "turn_on"}}

    HA.press({"climate.hall", false}, state, deps, callbacks(), params)
    assert_received {:opened, {:entity, "climate.hall"}}

    # nothing to do and no detail: nothing
    assert HA.press({"sensor.hall_battery", false}, state, deps, callbacks(), params) == state
    refute_received {_, _}
  end

  test "a slider: shown at once, sent once per 250 ms with the latest value", %{
    state: state,
    params: params
  } do
    key = {"light.ceiling", :brightness}
    deps = panel({:entity, "light.ceiling"})
    slide = &HA.slide({key, &1}, &2, deps, callbacks())
    state = state |> then(&slide.(30, &1)) |> then(&slide.(55, &1))
    assert HA.expose(state, deps, params).sliders == %{key => 55}

    # every move keeps the panel up
    assert_received :activity
    assert_received :activity

    # one send timer for the two moves
    assert_receive {:slide_send, ^key}, 500
    refute_received {:slide_send, _}

    state = HA.handle_info({:slide_send, key}, state, deps, callbacks(), params)
    assert_received {:called, %{service: "turn_on", data: %{brightness_pct: 55}}}
    assert HA.expose(state, deps, params).sliders == %{}
    assert {140, _ref} = state.pending["light.ceiling"].attrs["brightness"]
  end

  test "unlocking takes a second press within 5 s; a call disarms", %{
    state: state,
    params: params
  } do
    deps = panel({:entity, "light.ceiling"})
    state = HA.arm({"lock.door", :unlock}, state)
    assert HA.expose(state, deps, params).armed == %{"lock.door" => :unlock}

    # a disarm from an earlier arming is ignored
    {_action, ref} = state.armed["lock.door"]
    assert HA.handle_info({:disarm, "lock.door", make_ref()}, state, deps, %{}, params) == state
    assert HA.handle_info({:disarm, "lock.door", ref}, state, deps, %{}, params).armed == %{}

    request = %{domain: "lock", service: "unlock", entity_id: "lock.door", optimistic: "unlocked"}
    state = HA.call(request, state, deps, callbacks())
    assert_received {:called, %{service: "unlock"}}
    assert state.armed == %{}
  end

  test "a colour slider sends the colour shown, with the other half kept", %{
    state: state,
    params: params
  } do
    report("light.ceiling", fn es ->
      %{es | attributes: Map.put(es.attributes, "hs_color", [30.0, 64.0])}
    end)

    deps = panel({:entity, "light.ceiling"})
    state = HA.slide({{"light.ceiling", :hue}, 200}, state, deps, callbacks())

    state =
      HA.handle_info({:slide_send, {"light.ceiling", :hue}}, state, deps, callbacks(), params)

    assert_received {:called, %{data: %{hs_color: [200, 64.0]}}}

    # saturation right after: the hue sent (pending) is kept, not HA's old one
    state = HA.slide({{"light.ceiling", :saturation}, 20}, state, deps, callbacks())

    HA.handle_info(
      {:slide_send, {"light.ceiling", :saturation}},
      state,
      deps,
      callbacks(),
      params
    )

    assert_received {:called, %{data: %{hs_color: [200, 20]}}}
  end

  test "a confirm after the arming ran out does nothing", %{state: state, params: params} do
    deps = panel({:entity, "light.ceiling"})
    state = HA.arm({"lock.door", :unlock}, state)
    {_action, ref} = state.armed["lock.door"]
    disarmed = HA.handle_info({:disarm, "lock.door", ref}, state, deps, %{}, params)

    assert HA.confirm({"lock.door", :unlock}, disarmed, deps, callbacks()) == disarmed
    # nor does one for another action
    assert HA.confirm({"lock.door", :open}, state, deps, callbacks()) == state
    refute_received {:called, _}

    state = HA.confirm({"lock.door", :unlock}, state, deps, callbacks())
    assert_received {:called, %{domain: "lock", service: "unlock", entity_id: "lock.door"}}
    assert state.armed == %{}
  end

  test "controls used one after another keep each other's pending values", %{
    state: state,
    params: params
  } do
    deps = panel({:entity, "light.ceiling"})

    report("light.ceiling", fn es ->
      %{es | attributes: Map.put(es.attributes, "hs_color", [30.0, 64.0])}
    end)

    send_slider = fn state, kind, value ->
      state = HA.slide({{"light.ceiling", kind}, value}, state, deps, callbacks())
      HA.handle_info({:slide_send, {"light.ceiling", kind}}, state, deps, callbacks(), params)
    end

    state = state |> send_slider.(:hue, 200) |> send_slider.(:brightness, 40)
    send_slider.(state, :saturation, 20)
    assert_received {:called, %{data: %{hs_color: [200, 20]}}}

    # turning it off is a new state: what was pending for on goes
    state =
      HA.start_call(
        %{domain: "light", service: "turn_off", entity_id: "light.ceiling", optimistic: "off"},
        state,
        callbacks()
      )

    assert state.pending["light.ceiling"].attrs == %{}
  end

  test "a failed call rolls back only what it set", %{state: state, params: params} do
    deps = panel({:entity, "light.ceiling"})
    hue = make_ref()
    brightness = make_ref()

    state =
      Actions.color("light.ceiling", [200, 64])
      |> HA.start_call(state, %{call_service: fn _ -> %{ref: hue} end})
      |> then(
        &HA.start_call(Actions.slider("light.ceiling", :brightness, 40), &1, %{
          call_service: fn _ -> %{ref: brightness} end
        })
      )
      |> then(&HA.call_done(hue, {:error, :timeout}, &1))

    shown = HA.expose(state, deps, params).states["light.ceiling"]
    refute shown.attributes["hs_color"] == [200, 64]
    assert shown.attributes["brightness"] == 102

    # and HA reporting the brightness ends it, with no failed hue in the way
    report(
      "light.ceiling",
      &%{&1 | state: "on", attributes: Map.put(&1.attributes, "brightness", 102)}
    )

    assert HA.states(["light.ceiling"], state, deps, %{}, params).pending == %{}
  end

  test "a colour settles around the hue circle", %{state: state, params: params} do
    deps = panel({:entity, "light.ceiling"})
    callbacks = %{call_service: fn _ -> %{ref: make_ref()} end}

    for {sent, reported} <- [
          {[360, 80], [0.0, 80.0]},
          {[359, 80], [1.0, 80.0]},
          {[2, 80], [358.5, 80.0]},
          {[200, 0], [0.0, 0.0]}
        ] do
      state = HA.start_call(Actions.color("light.ceiling", sent), state, callbacks)

      report("light.ceiling", fn es ->
        %{es | state: "on", attributes: Map.put(es.attributes, "hs_color", reported)}
      end)

      assert HA.states(["light.ceiling"], state, deps, %{}, params).pending == %{}
    end

    # a different colour doesn't
    state = HA.start_call(Actions.color("light.ceiling", [180, 80]), state, callbacks)
    report("light.ceiling", &%{&1 | attributes: Map.put(&1.attributes, "hs_color", [10.0, 80.0])})
    refute HA.states(["light.ceiling"], state, deps, %{}, params).pending == %{}
  end

  test "a setpoint settles only when HA reports it exactly", %{state: state, params: params} do
    deps = panel({:entity, "climate.hall"})

    request = %{
      domain: "climate",
      service: "set_temperature",
      entity_id: "climate.hall",
      data: %{target_temp_low: 69, target_temp_high: 76},
      optimistic_attrs: %{"target_temp_low" => 69, "target_temp_high" => 76}
    }

    state = HA.start_call(request, state, %{call_service: fn _ -> %{ref: make_ref()} end})

    set = fn low ->
      &%{
        &1
        | attributes:
            Map.merge(&1.attributes, %{"target_temp_low" => low, "target_temp_high" => 76})
      }
    end

    # one degree off is the old value, not HA's rounding
    report("climate.hall", set.(68))
    state = HA.states(["climate.hall"], state, deps, %{}, params)

    assert HA.expose(state, deps, params).states["climate.hall"].attributes["target_temp_low"] ==
             69

    report("climate.hall", set.(69))
    assert HA.states(["climate.hall"], state, deps, %{}, params).pending == %{}
  end

  test "an entity's detail: its integration, and the players it can group with", %{
    state: state
  } do
    player = fn id, platform, features ->
      {%{
         "entity_id" => id,
         "platform" => platform,
         "device_id" => nil,
         "has_entity_name" => false
       },
       %EntityState{
         entity_id: id,
         state: "idle",
         attributes: %{"supported_features" => features, "friendly_name" => id}
       }}
    end

    # 524_288: grouping
    players = [
      player.("media_player.kitchen", "music_assistant", 524_288),
      player.("media_player.office", "music_assistant", 524_288),
      player.("media_player.attic", "music_assistant", 0),
      player.("media_player.den", "sonos", 524_288)
    ]

    registries = HAFixture.registries()

    registries = %{
      registries
      | entity:
          registries.entity ++
            Enum.map(players, fn {entry, _} -> Hassock.Registries.decode(:entity, entry) end)
    }

    states =
      Map.merge(HAFixture.states(), Map.new(players, fn {_, es} -> {es.entity_id, es} end))

    table = :"ha_group_#{System.unique_integer([:positive])}"
    :ets.new(table, [:named_table, :public])
    Model.store(table, Index.build(registries, Map.keys(states)), 1)
    params = %{source: %{table: table, state: &Map.get(states, &1)}}

    exposed = HA.expose(state, panel({:entity, "media_player.kitchen"}), params)

    assert %{platform: "music_assistant", group: ["media_player.office"]} = exposed.slice

    assert Map.keys(exposed.states) |> Enum.sort() == [
             "media_player.kitchen",
             "media_player.office"
           ]

    # one that doesn't group: none
    assert %{platform: "music_assistant", group: []} =
             HA.expose(state, panel({:entity, "media_player.attic"}), params).slice
  end

  test "slice ids cover summaries, sections, badges and readouts", %{src: src} do
    ids = src |> Overview.area_view("kitchen") |> HA.slice_ids()
    assert "sensor.kitchen_temperature" in ids
    assert "light.ceiling" in ids
  end
end
