defmodule PictureRail.App.SlideshowTest do
  use ExUnit.Case, async: true

  alias PictureRail.App.Slideshow

  @deps %{
    settings: %{settings: %{slideshow: %{interval_ms: 50, fade_ms: 10}}},
    panel: %{visible?: false}
  }

  defp entry(n, w \\ 4, h \\ 3),
    do: %{id: "p#{n}", width: w, height: h, path: "/cache/p#{n}.jpg", clip: nil}

  # A callback that hands out the given photos in turn, then :none.
  defp photos(entries) do
    {:ok, agent} = Agent.start_link(fn -> entries end)

    %{
      next_photo: fn ->
        Agent.get_and_update(agent, fn
          [e | rest] -> {{:ok, e}, rest}
          [] -> {:none, []}
        end)
      end
    }
  end

  defp init do
    state = Slideshow.init(nil, @deps)
    assert_receive :tick
    state
  end

  test "each tick shows the next photo and keeps the last one for the fade" do
    callbacks = photos([entry(1), entry(2, 3, 4)])

    state = Slideshow.tick(init(), @deps, callbacks)

    assert %{current: %{id: "p1", portrait?: false}, previous: nil, index: 1, fade_ms: 10} =
             Slideshow.expose(state, @deps, nil)

    state = Slideshow.tick(state, @deps, callbacks)

    assert %{current: %{id: "p2", portrait?: true}, previous: %{id: "p1"}, index: 2} =
             Slideshow.expose(state, @deps, nil)

    assert_receive {:clear_previous, 2}, 1_000
  end

  test "nothing advances while the panel is up" do
    callbacks = photos([entry(1), entry(2)])
    state = Slideshow.tick(init(), @deps, callbacks)
    panel_up = %{@deps | panel: %{visible?: true}}

    state = Slideshow.tick(state, panel_up, callbacks)
    assert Slideshow.expose(state, panel_up, nil).current.id == "p1"

    state = Slideshow.tick(state, @deps, callbacks)
    assert Slideshow.expose(state, @deps, nil).current.id == "p2"
  end

  test "rescheduling drops a tick its old timer already delivered" do
    callbacks = photos([entry(1), entry(2), entry(3)])
    state = Slideshow.tick(init(), @deps, callbacks)

    # let the timer fire, so its :tick is waiting in the mailbox
    wait_until(fn -> Process.read_timer(state.timer) == false end)
    {:messages, waiting} = Process.info(self(), :messages)
    assert :tick in waiting

    # rescheduling now (a tick handled out of turn) must not leave that
    # one behind, or the slideshow would advance twice
    state = Slideshow.tick(state, @deps, callbacks)
    refute_received :tick
    assert Slideshow.expose(state, @deps, nil).current.id == "p2"

    # the replacement timer still ticks, once
    assert_receive :tick, 1_000
    refute_receive :tick, 100
  end

  defp wait_until(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("timed out waiting")
      true -> wait_again(fun, tries)
    end
  end

  defp wait_again(fun, tries) do
    Process.sleep(5)
    wait_until(fun, tries - 1)
  end

  test "with nothing to show yet it looks again soon; the same photo isn't re-shown" do
    # soon: the empty retry (2 s), not the (here, minute-long) slide interval
    slow = put_in(@deps.settings.settings.slideshow.interval_ms, 60_000)
    empty = Slideshow.tick(init(), slow, photos([]))
    assert Process.read_timer(empty.timer) in 1_000..2_000

    state = Slideshow.tick(init(), @deps, photos([]))
    assert %{current: nil, index: 0} = Slideshow.expose(state, @deps, nil)

    state = Slideshow.tick(state, @deps, photos([entry(1)]))
    state = Slideshow.tick(state, @deps, photos([entry(1)]))
    assert %{current: %{id: "p1"}, previous: nil, index: 1} = Slideshow.expose(state, @deps, nil)
  end
end
