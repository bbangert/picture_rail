defmodule PictureRail.Setup.Keyboard do
  @moduledoc """
  The on-screen keyboard's state, which the `:setup` controller holds: the
  layer (letters or symbols) and shift, and editing a masked field.
  `PictureRail.View.Keyboard` draws it.

  Shift is one-shot (the next letter, then off); a second tap within
  400 ms locks it (caps lock) until it's tapped again. On the symbols
  layer shift flips between the two symbol pages.
  """

  @type key ::
          {:char, String.t()}
          | :space
          | :backspace
          | :left
          | :right
          | :shift
          | {:layer, :letters | :symbols}
          | :done
          | :cancel
          | :reveal
  @type layer :: :letters | :symbols
  @type shift :: :off | :once | :caps
  @type t :: %{layer: layer(), shift: shift(), shift_at: integer() | nil}

  @double_tap_ms 400

  @doc "A fresh keyboard: letters, shift off."
  @spec new() :: t()
  def new, do: %{layer: :letters, shift: :off, shift_at: nil}

  @doc """
  A tap on shift at `now` (ms): off → once; once → caps when it's a
  double tap, else off; caps → off. On the symbols layer shift flips
  between the two symbol pages (no caps lock).
  """
  @spec press_shift(t(), integer()) :: t()
  def press_shift(%{shift: :off} = kb, now), do: %{kb | shift: :once, shift_at: now}

  def press_shift(%{shift: :once, layer: :letters, shift_at: at} = kb, now)
      when is_integer(at) and now - at <= @double_tap_ms,
      do: %{kb | shift: :caps, shift_at: now}

  def press_shift(kb, now), do: %{kb | shift: :off, shift_at: now}

  @doc "After a character is typed: a one-shot shift on the letters ends."
  @spec typed(t()) :: t()
  def typed(%{shift: :once, layer: :letters} = kb), do: %{kb | shift: :off}
  def typed(kb), do: kb

  @doc "Switch layers (shift off)."
  @spec layer(t(), layer()) :: t()
  def layer(kb, layer), do: %{kb | layer: layer, shift: :off, shift_at: nil}

  @doc """
  A masked field's value after a key (`:masked` mode), at most `max`
  characters: characters and space are appended, backspace takes the last
  one off; other keys leave it alone.
  """
  @spec edit(String.t(), key(), pos_integer()) :: String.t()
  def edit(value, {:char, text}, max), do: String.slice(value <> text, 0, max)
  def edit(value, :space, max), do: String.slice(value <> " ", 0, max)
  def edit(value, :backspace, _max), do: String.slice(value, 0..-2//1)
  def edit(value, _key, _max), do: value
end
