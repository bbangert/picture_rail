defmodule PictureRail.Setup.KeyboardTest do
  use ExUnit.Case, async: true

  alias PictureRail.Setup.Keyboard

  test "one-shot shift, double tap for caps lock, tap again to unlock" do
    kb = Keyboard.new()
    once = Keyboard.press_shift(kb, 1_000)
    assert once.shift == :once
    assert Keyboard.typed(once).shift == :off

    caps = Keyboard.press_shift(once, 1_300)
    assert caps.shift == :caps
    assert Keyboard.typed(caps).shift == :caps
    assert Keyboard.press_shift(caps, 5_000).shift == :off

    # too slow for a double tap: off again
    assert once |> Keyboard.press_shift(1_500) |> Map.get(:shift) == :off
  end

  test "on the symbols layer shift just flips pages" do
    kb = Keyboard.layer(Keyboard.press_shift(Keyboard.new(), 0), :symbols)
    assert kb.shift == :off
    more = Keyboard.press_shift(kb, 10)
    assert more.shift == :once
    assert Keyboard.typed(more).shift == :once
    assert Keyboard.press_shift(more, 20).shift == :off
  end

  test "masked editing: append, space, backspace, a limit" do
    assert Keyboard.edit("ab", {:char, "c"}, 10) == "abc"
    assert Keyboard.edit("ab", :space, 10) == "ab "
    assert Keyboard.edit("ab", :backspace, 10) == "a"
    assert Keyboard.edit("", :backspace, 10) == ""
    assert Keyboard.edit("abc", {:char, "d"}, 3) == "abc"
    assert Keyboard.edit("ab", :shift, 10) == "ab"
  end
end
