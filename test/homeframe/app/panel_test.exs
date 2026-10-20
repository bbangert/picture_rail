defmodule HomeFrame.App.PanelTest do
  use ExUnit.Case, async: true

  alias HomeFrame.App.Panel

  @deps %{settings: %{settings: %{panel: %{timeout_ms: 10}}}}

  defp exposed(state), do: Panel.expose(state, @deps, nil)

  test "a tap shows the panel on the overview, and it hides after the timeout" do
    state = Panel.show(nil, Panel.init(nil, @deps), @deps)
    assert exposed(state) == %{visible?: true, view: :overview, depth: 0}

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

  test "activity while hidden doesn't show the panel" do
    state = Panel.activity(nil, Panel.init(nil, @deps), @deps)
    refute exposed(state).visible?
    refute_receive {:timeout, _}
  end
end
