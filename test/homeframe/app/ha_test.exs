defmodule HomeFrame.App.HATest do
  use ExUnit.Case, async: true

  alias HomeFrame.App.HA
  alias HomeFrame.HA.Overview
  alias HomeFrame.HAFixture

  setup do
    src = HAFixture.source()

    state = %{
      status: :connected,
      revision: 1,
      tick: 0,
      shown: nil,
      pending: %{},
      error: nil
    }

    %{src: src, params: %{source: src}, state: state}
  end

  defp panel(view, visible? \\ true), do: %{panel: %{visible?: visible?, view: view}}

  test "no slice while the panel is down", %{state: state, params: params} do
    assert %{slice: nil, states: states, view: nil} =
             HA.expose(state, panel(:overview, false), params)

    assert states == %{}
  end

  test "the slice and its states follow the panel's view", %{state: state, params: params} do
    %{slice: overview, states: states} = HA.expose(state, panel(:overview), params)
    assert [%{kind: :light} | _] = overview.summaries
    assert states["light.ceiling"].state == "on"
    # area temperatures are on screen too
    assert Map.has_key?(states, "sensor.kitchen_temperature")

    %{slice: area, states: states} = HA.expose(state, panel({:area, "living"}), params)
    assert area.area.area_id == "living"
    assert Map.has_key?(states, "sensor.hall_battery")
  end

  test "a state change recomputes only when it's on screen", %{state: state, params: params} do
    deps = panel({:area, "kitchen"})

    state = HA.states(["light.bedroom"], state, deps, %{}, params)
    assert state.tick == 0

    state = HA.states(["light.ceiling"], state, deps, %{}, params)
    assert state.tick == 1

    # hidden: nothing is on screen
    assert HA.states(["light.ceiling"], state, panel(:overview, false), %{}, params).tick == 1
  end

  test "an optimistic call shows at once and HA's report replaces it",
       %{state: state, params: params} do
    callbacks = %{call_service: fn _request -> %{ref: make_ref()} end}

    request = %{
      domain: "light",
      service: "turn_off",
      entity_id: "light.ceiling",
      optimistic: "off"
    }

    state = HA.start_call(request, state, callbacks)
    assert HA.expose(state, panel(:overview), params).states["light.ceiling"].state == "off"

    state = HA.states(["light.ceiling"], state, panel(:overview), %{}, params)
    assert state.pending == %{}
  end

  test "a failed call rolls back and reports the error", %{state: state, params: params} do
    ref = make_ref()
    callbacks = %{call_service: fn _request -> %{ref: ref} end}

    request = %{
      domain: "light",
      service: "turn_off",
      entity_id: "light.ceiling",
      optimistic: "off"
    }

    state =
      state
      |> then(&HA.start_call(request, &1, callbacks))
      |> then(&HA.call_done(ref, {:error, :timeout}, &1))

    exposed = HA.expose(state, panel(:overview), params)
    assert exposed.states["light.ceiling"].state == "on"
    assert exposed.error == :timeout
  end

  test "a successful call keeps the optimistic state until HA reports it",
       %{state: state, params: params} do
    ref = make_ref()
    callbacks = %{call_service: fn _request -> %{ref: ref} end}

    request = %{
      domain: "light",
      service: "turn_off",
      entity_id: "light.ceiling",
      optimistic: "off"
    }

    state = request |> HA.start_call(state, callbacks) |> then(&HA.call_done(ref, {:ok, %{}}, &1))
    assert HA.expose(state, panel(:overview), params).states["light.ceiling"].state == "off"
  end

  test "slice ids cover summaries, sections, badges and readouts", %{src: src} do
    ids = src |> Overview.area_view("kitchen") |> HA.slice_ids()
    assert "sensor.kitchen_temperature" in ids
    assert "light.ceiling" in ids
  end
end
