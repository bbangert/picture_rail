defmodule PictureRail.App.PanelTest do
  use ExUnit.Case, async: true

  alias PictureRail.App.Panel

  @deps %{settings: %{settings: %{panel: %{timeout_ms: 10}}}}

  defp exposed(state), do: Panel.expose(state, @deps, nil)

  test "a tap shows the panel on the overview, and it hides after the timeout" do
    state = Panel.show(nil, Panel.init(nil, @deps), @deps)
    assert exposed(state) == %{visible?: true, view: :overview, depth: 0, page: 0, nav_page: 0}

    assert_receive {:timeout, token}
    state = Panel.timed_out(token, state)
    assert exposed(state).visible? == false
  end

  test "activity restarts the timeout; the earlier timer is ignored" do
    state = Panel.show(nil, Panel.init(nil, @deps), @deps)
    assert_receive {:timeout, first}
    state = Panel.activity(nil, state, @deps)
    assert_receive {:timeout, second}

    assert exposed(Panel.timed_out(first, state)).visible?
    refute exposed(Panel.timed_out(second, state)).visible?
  end

  test "views stack and unwind, and the panel reopens on the overview" do
    state = Panel.show(nil, Panel.init(nil, @deps), @deps)
    state = Panel.open({:area, "kitchen"}, state, @deps)
    state = Panel.open({:entity, "light.kitchen"}, state, @deps)
    assert %{view: {:entity, "light.kitchen"}, depth: 2} = exposed(state)

    state = Panel.back(nil, state, @deps)
    assert %{view: {:area, "kitchen"}, depth: 1} = exposed(state)

    state = Panel.hide(nil, state)
    state = Panel.show(nil, state, @deps)
    assert %{view: :overview, depth: 0} = exposed(state)
  end

  test "pages belong to their view: back returns to the page left; hiding resets them" do
    state = Panel.show(nil, Panel.init(nil, @deps), @deps)
    state = Panel.page(2, state, @deps)
    state = Panel.nav_page(1, state, @deps)
    state = Panel.open({:area, "kitchen"}, state, @deps)
    assert %{view: {:area, "kitchen"}, page: 0, nav_page: 1} = exposed(state)

    state = Panel.page(1, state, @deps)
    state = Panel.open({:device, "d"}, state, @deps)
    state = Panel.back(nil, state, @deps)
    assert %{view: {:area, "kitchen"}, page: 1} = exposed(state)
    assert %{view: :overview, page: 2} = exposed(Panel.back(nil, state, @deps))

    # the idle timeout (the current timer's) brings it back fresh
    state = state |> then(&Panel.timed_out(&1.token, &1)) |> then(&Panel.show(nil, &1, @deps))
    assert %{view: :overview, page: 0, nav_page: 0} = exposed(state)
  end

  test "activity while hidden doesn't show the panel" do
    state = Panel.activity(nil, Panel.init(nil, @deps), @deps)
    refute exposed(state).visible?
    refute_receive {:timeout, _}
  end

  test "Setup's Next replaces the section; Back goes to what was under it" do
    state = Panel.open(:setup, Panel.init(nil, @deps), @deps)
    state = Panel.open({:setup, :wifi}, state, @deps)
    state = Panel.replace({:setup, :photo_source}, state, @deps)
    assert %{view: {:setup, :photo_source}, depth: 2} = exposed(state)
    assert %{view: :setup, depth: 1} = exposed(Panel.back(nil, state, @deps))

    # first boot: Wi-Fi alone, then Next: Back goes to the overview
    first = Panel.goto({:setup, :wifi}, Panel.init(nil, @deps), @deps)
    first = Panel.replace({:setup, :photo_source}, first, @deps)
    assert %{view: :overview} = exposed(Panel.back(nil, first, @deps))

    # nothing open: it's an open
    assert %{view: {:setup, :wifi}, depth: 1} =
             exposed(Panel.replace({:setup, :wifi}, Panel.init(nil, @deps), @deps))
  end

  test "a busy Setup page holds the panel for five minutes" do
    deps = %{settings: %{settings: %{panel: %{timeout_ms: 30_000}}}, setup: %{busy?: true}}
    setup = %{stack: [{{:setup, :display}, 0}]}

    assert Panel.timeout_ms(setup, deps) == 300_000
    assert Panel.timeout_ms(%{stack: [{:setup, 0}]}, deps) == 300_000
    assert Panel.timeout_ms(setup, %{deps | setup: %{busy?: false}}) == 30_000
    assert Panel.timeout_ms(%{stack: []}, deps) == 30_000

    # busy only once the timer was set (first boot opens Setup with the
    # panel): checked again when the time is up
    idle = %{settings: deps.settings, setup: %{busy?: false}}
    state = Panel.goto({:setup, :wifi}, Panel.init(nil, idle), idle)
    state = Panel.timed_out(state.token, state, deps)
    assert exposed(state).visible?
    assert exposed(Panel.timed_out(state.token, state, idle)).visible? == false
  end
end
