defmodule HomeFrame.App.OrientationTest do
  use ExUnit.Case, async: true

  alias HomeFrame.App.Orientation

  defp init, do: Orientation.init(%{default: :landscape, settle_ms: 10}, %{})

  test "a new orientation applies once it has held for the settle time" do
    state = Orientation.reading(:portrait_x_pos, init())
    assert Orientation.expose(state, %{}, nil).orientation == :landscape

    assert_receive {:settle, token}
    state = Orientation.settle(token, state)

    assert %{orientation: :portrait_x_pos, rotation: 270, portrait?: true} =
             Orientation.expose(state, %{}, nil)
  end

  test "going back before it settles cancels the change" do
    state =
      init()
      |> then(&Orientation.reading(:landscape_inverted, &1))
      |> then(&Orientation.reading(:landscape, &1))

    assert_receive {:settle, token}
    state = Orientation.settle(token, state)
    assert Orientation.expose(state, %{}, nil).orientation == :landscape
  end

  test "a different reading restarts the settle time; the old timer is ignored" do
    state = Orientation.reading(:portrait_x_pos, init())
    assert_receive {:settle, first}
    state = Orientation.reading(:portrait_x_neg, state)
    assert_receive {:settle, second}

    assert Orientation.settle(first, state) == state
    state = Orientation.settle(second, state)

    assert Orientation.expose(state, %{}, nil) == %{
             orientation: :portrait_x_neg,
             rotation: 90,
             portrait?: true
           }
  end

  test "flat readings keep the last orientation" do
    state = Orientation.reading(:flat, init())
    refute_receive {:settle, _}
    assert Orientation.expose(state, %{}, nil).orientation == :landscape
  end
end
