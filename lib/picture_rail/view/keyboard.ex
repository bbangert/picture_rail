defmodule PictureRail.View.Keyboard do
  @moduledoc """
  The on-screen keyboard for the Setup page's text fields.

  Keys work in one of two modes:

    * `:native` - the field is Emerge's own `Input.text`, focused, and the
      keys are `Event.virtual_key/1`s that type into it (text at the caret,
      backspace repeating while held, arrows moving the caret), as a
      hardware keyboard would. Shift, the layer keys, Done and Cancel are
      app events (`hold: {:event, ...}` with `hold_ms: 0`): a virtual
      Enter doesn't reach the field, and any `on_press` button would take
      the focus away from it.
    * `:masked` - for a secret that isn't shown: Emerge has no password
      field, so the page draws bullets itself and every key is an app
      event, which the `:setup` controller applies with `edit/2` (append
      and backspace only).

  The app events go where the caller says: `on_key` gives the press for a
  key (an event tuple, `key -> {pid, message}`, `nil` for nowhere), so the
  keyboard knows nothing of who handles them.

  Shift and the layer are the `:setup` controller's state
  (`PictureRail.Setup.Keyboard`); the keys are drawn with the cased
  letters.

  Labels use only characters Antonio has (it has no arrows or ⌫-style
  symbols; the test checks).

  Keys: `{:char, text}`, `:space`, `:backspace`, `:left`, `:right`,
  `:shift`, `{:layer, :letters | :symbols}`, `:done`, `:cancel`, and
  `:reveal` (the editor's SHOW/HIDE for secrets).
  """
  use Emerge.UI

  alias PictureRail.Setup.Keyboard, as: KeyboardState
  alias PictureRail.View.Theme

  @type key :: KeyboardState.key()
  @type layer :: KeyboardState.layer()
  @type shift :: KeyboardState.shift()
  @type state :: KeyboardState.t()

  @type mode :: :native | :masked

  @letters ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
  @symbols ["1234567890", ~S{-/:;()$&@"}, ".,?!'"]
  @more_symbols ["[]{}#%^*+=", "_\\|~<>€£¥•", ".,?!'`"]
  @url_row ["https://", "http://", ".", "/", ":", ".local"]

  # -- Layout --

  @doc """
  The rows of keys as `{key, label, weight}` (weight: its share of the
  row's width). `:url` fields get a row of URL pieces on top; in `:masked`
  mode there are no caret keys.
  """
  @spec layout(layer(), shift(), atom(), mode()) :: [[{key(), String.t(), number()}]]
  def layout(layer, shift, field_type, mode \\ :native) do
    [r1, r2, r3] = char_rows(layer, shift)

    url =
      if field_type == :url,
        do: [Enum.map(@url_row, &{{:char, &1}, &1, String.length(&1) / 3 + 0.6})],
        else: []

    shift_label =
      case {layer, shift} do
        {:letters, _} -> "SHIFT"
        {:symbols, :off} -> "#+="
        {:symbols, _} -> "123"
      end

    caret = if mode == :native, do: [{:left, "‹", 1}, {:right, "›", 1}], else: []

    layer_key =
      if layer == :letters,
        do: {{:layer, :symbols}, "?123", 1.5},
        else: {{:layer, :letters}, "ABC", 1.5}

    url ++
      [
        chars(r1),
        chars(r2),
        [{:shift, shift_label, 1.5}] ++ chars(r3) ++ [{:backspace, "DEL", 1.5}],
        [layer_key] ++ caret ++ [{:space, "SPACE", 4}, {:cancel, "CANCEL", 2}, {:done, "DONE", 2}]
      ]
  end

  defp char_rows(:letters, :off), do: @letters
  defp char_rows(:letters, _shift), do: Enum.map(@letters, &String.upcase/1)
  defp char_rows(:symbols, :off), do: @symbols
  defp char_rows(:symbols, _shift), do: @more_symbols

  defp chars(row), do: for(c <- String.graphemes(row), do: {{:char, c}, c, 1})

  # -- Keys --

  @doc """
  A key's `Event.virtual_key/1` spec. `on_key` gives the app events'
  presses (see the moduledoc).
  """
  @spec key_spec(key(), mode(), (key() -> term())) :: map()
  def key_spec({:char, text}, :native, _on_key), do: %{tap: {:text, text}}
  def key_spec(:space, :native, _on_key), do: %{tap: {:text, " "}}
  def key_spec(:backspace, :native, _on_key), do: %{tap: {:key, :backspace, []}, hold: :repeat}
  def key_spec(:left, :native, _on_key), do: %{tap: {:key, :arrow_left, []}, hold: :repeat}
  def key_spec(:right, :native, _on_key), do: %{tap: {:key, :arrow_right, []}, hold: :repeat}

  # Everything else is the app's: the hold fires at once (hold_ms 0), so
  # the tap (a no-op shift press) never happens.
  def key_spec(key, _mode, on_key) do
    case on_key.(key) do
      nil -> %{tap: {:key, :shift, []}}
      press -> %{tap: {:key, :shift, []}, hold: {:event, press}, hold_ms: 0}
    end
  end

  # -- Drawing --

  @doc """
  The keyboard for `kb`, `w` px wide with keys `key_h` tall, the app
  events' presses from `on_key`.
  """
  @spec render(state(), atom(), mode(), number(), number(), (key() -> term())) :: term()
  def render(kb, field_type, mode, w, key_h, on_key) do
    gap = 8
    font = round(Kernel.min(key_h * 0.42, 40))

    rows =
      for keys <- layout(kb.layer, kb.shift, field_type, mode) do
        elements =
          for {key, label, weight} <- keys,
              do: key_element(kb, key, label, weight, mode, on_key, font)

        row([width(px(w)), height(px(key_h)), spacing(gap)], elements)
      end

    column([width(px(w)), spacing(gap)], rows)
  end

  @doc """
  A single key outside the keyboard (the editor's SHOW/HIDE), `w` x `h`,
  in `color` (hex). Like every key it never takes the focus.
  """
  @spec key(key(), String.t(), number(), number(), non_neg_integer(), (key() -> term())) ::
          term()
  def key(key, label, w, h, color, on_key) do
    Input.button(
      [
        Event.virtual_key(key_spec(key, :masked, on_key)),
        width(px(w)),
        height(px(h)),
        Background.color(Theme.color(color)),
        Border.rounded(h / 2),
        Font.color(Theme.color(:black)),
        Font.size(Theme.size(:label)),
        Interactive.mouse_down([Background.color(Theme.color(:white))])
      ],
      el([center_x(), center_y()], text(label))
    )
  end

  defp key_element(kb, key, label, weight, mode, on_key, font) do
    color = key_color(kb, key)

    Input.button(
      [
        Event.virtual_key(key_spec(key, mode, on_key)),
        width(fill(weight)),
        height(fill()),
        Background.color(Theme.color(color)),
        Border.rounded(12),
        Font.color(Theme.color(:black)),
        Font.size(font),
        Interactive.mouse_down([Background.color(Theme.color(:white))])
      ],
      el([center_x(), center_y()], text(label))
    )
  end

  defp key_color(%{shift: :once}, :shift), do: Theme.hex(:white)
  defp key_color(%{shift: :caps}, :shift), do: Theme.hex(:gold)
  defp key_color(_kb, {:char, _}), do: Theme.hex(:peach)
  defp key_color(_kb, :space), do: Theme.hex(:almond)
  defp key_color(_kb, :done), do: Theme.hex(:orange)
  defp key_color(_kb, :cancel), do: Theme.hex(:mauve)
  defp key_color(_kb, _key), do: Theme.hex(:lilac)
end
