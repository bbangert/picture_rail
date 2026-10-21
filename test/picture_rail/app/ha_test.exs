defmodule PictureRail.App.HATest do
  use ExUnit.Case, async: true

  alias Hassock.EntityState
  alias PictureRail.App.HA
  alias PictureRail.HA.Overview
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
      sliding: %{}
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
      open: &send(test, {:opened, &1})
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
    assert state.pending["light.ceiling"].state == "off"

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
    state = state |> then(&HA.slide({key, 30}, &1)) |> then(&HA.slide({key, 55}, &1))
    deps = panel({:entity, "light.ceiling"})
    assert HA.expose(state, deps, params).sliders == %{key => 55}

    # one send timer for the two moves
    assert_receive {:slide_send, ^key}, 500
    refute_received {:slide_send, _}

    state = HA.handle_info({:slide_send, key}, state, deps, callbacks())
    assert_received {:called, %{service: "turn_on", data: %{brightness_pct: 55}}}
    assert HA.expose(state, deps, params).sliders == %{}
    assert state.pending["light.ceiling"].attrs["brightness"] == round(55 * 255 / 100)
  end

  test "slice ids cover summaries, sections, badges and readouts", %{src: src} do
    ids = src |> Overview.area_view("kitchen") |> HA.slice_ids()
    assert "sensor.kitchen_temperature" in ids
    assert "light.ceiling" in ids
  end
end
