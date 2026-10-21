defmodule PictureRail.View.KeyboardTest do
  use ExUnit.Case, async: true

  alias Emerge.UI.Event
  alias PictureRail.View.Keyboard

  defp keys(rows), do: Enum.map(rows, fn row -> Enum.map(row, &elem(&1, 0)) end)
  defp labels(row), do: Enum.map_join(row, &elem(&1, 1))

  test "letters, shifted letters and the two symbol pages" do
    [r1, r2, r3, r4] = Keyboard.layout(:letters, :off, :text)
    assert labels(r1) == "qwertyuiop"
    assert labels(r2) == "asdfghjkl"
    assert [{:shift, "SHIFT", _} | _] = r3
    assert List.last(r3) |> elem(0) == :backspace

    assert Enum.map(r4, &elem(&1, 0)) ==
             [{:layer, :symbols}, :left, :right, :space, :cancel, :done]

    assert :letters |> Keyboard.layout(:once, :text) |> hd() |> labels() == "QWERTYUIOP"
    assert :letters |> Keyboard.layout(:caps, :text) |> Enum.at(1) |> labels() == "ASDFGHJKL"

    [s1, s2, s3, s4] = Keyboard.layout(:symbols, :off, :text)
    assert labels(s1) == "1234567890"
    assert labels(s2) == ~S{-/:;()$&@"}
    assert [{:shift, "#+=", _} | _] = s3
    assert hd(s4) |> elem(0) == {:layer, :letters}

    [m1 | _] = Keyboard.layout(:symbols, :once, :text)
    assert labels(m1) == "[]{}#%^*+="
  end

  test "URL fields get a row of URL pieces; masked mode has no caret keys" do
    [url | _] = Keyboard.layout(:letters, :off, :url)
    assert Enum.map(url, &elem(&1, 1)) == ["https://", "http://", ".", "/", ":", ".local"]
    assert {:char, "https://"} = url |> hd() |> elem(0)

    masked = Keyboard.layout(:letters, :off, :secret, :masked)
    refute Enum.any?(List.flatten(keys(masked)), &(&1 in [:left, :right]))
  end

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

  test "key specs: native keys type, the rest are the caller's presses" do
    pid = self()
    on_key = &{pid, {:pressed, &1}}
    assert Keyboard.key_spec({:char, "a"}, :native, on_key) == %{tap: {:text, "a"}}

    assert %{tap: {:key, :backspace, []}, hold: :repeat} =
             Keyboard.key_spec(:backspace, :native, on_key)

    assert %{tap: {:key, :arrow_left, []}} = Keyboard.key_spec(:left, :native, on_key)

    assert %{hold: {:event, {^pid, {:pressed, :done}}}, hold_ms: 0} =
             Keyboard.key_spec(:done, :native, on_key)

    assert %{hold: {:event, {^pid, {:pressed, {:char, "a"}}}}} =
             Keyboard.key_spec({:char, "a"}, :masked, on_key)

    # nowhere to send it (the controller is down): no hold event
    refute Map.has_key?(Keyboard.key_spec(:done, :native, fn _ -> nil end), :hold)

    # every spec is one Emerge accepts
    for row <- Keyboard.layout(:letters, :off, :url),
        {key, _, _} <- row,
        mode <- [:native, :masked] do
      assert {:virtual_key, _} = Event.virtual_key(Keyboard.key_spec(key, mode, on_key))
    end
  end

  # Antonio (and Noto Sans) have ASCII and these, but no arrows or ⌫-like
  # symbols (checked with fc-query).
  @drawable ~c"‹›•€£¥"

  test "every label is drawable in the bundled fonts" do
    for layer <- [:letters, :symbols],
        shift <- [:off, :once, :caps],
        type <- [:text, :url],
        mode <- [:native, :masked],
        row <- Keyboard.layout(layer, shift, type, mode),
        {_key, label, _} <- row,
        c <- String.to_charlist(label) do
      assert c in 0x20..0x7E or c in @drawable, "#{label} has #{<<c::utf8>>}"
    end
  end
end
