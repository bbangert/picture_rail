defmodule PictureRail.ViewWhereisTest do
  # Registers stand-ins under PictureRail.View.Supervisor's name
  use ExUnit.Case, async: false

  alias PictureRail.View

  test "nil when the viewport isn't running" do
    refute Process.whereis(View.Supervisor)
    assert View.whereis() == nil
  end

  test "the viewport's pid from its supervisor" do
    viewport = %{id: View, start: {Agent, :start_link, [fn -> nil end]}}

    sup =
      start_supervised!(%{
        id: :sup,
        start:
          {Supervisor, :start_link, [[viewport], [strategy: :one_for_one, name: View.Supervisor]]},
        type: :supervisor
      })

    [{View, pid, _, _}] = Supervisor.which_children(sup)

    assert View.whereis() == pid
  end

  test "nil, not an exit, when its supervisor stops during the lookup" do
    # Answers the which_children call by exiting, as a supervisor that is
    # shutting down does
    test = self()

    stopping =
      spawn(fn ->
        Process.register(self(), View.Supervisor)
        send(test, :registered)

        receive do
          {:"$gen_call", _, _} -> exit(:shutdown)
        end
      end)

    assert_receive :registered
    ref = Process.monitor(stopping)
    assert View.whereis() == nil
    assert_receive {:DOWN, ^ref, :process, ^stopping, :shutdown}
  end
end
