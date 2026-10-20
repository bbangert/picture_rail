defmodule HomeFrame.View.LCARS do
  @moduledoc """
  LCARS-style building blocks, drawn with flat fills on the black panel:

    * `elbow/2` - the corner joining the sidebar to a horizontal bar: an
      outer rounded block with a black, rounded patch over its inner corner
    * `bar/2` and `cap/3` - bar segments and half-round end caps
    * `block/3` - a sidebar block with its label at the bottom right
    * `pill/2` - a rounded button with a label
    * `heading/2` - a section heading: a cap, the title, a thin bar

  "LCARS-style" describes the look only; no Star Trek assets are used.
  """
  use Emerge.UI

  alias HomeFrame.View.Theme

  @doc """
  An elbow. Options: `:corner` (`:top` or `:bottom`), `:color` (hex),
  `:width` (the sidebar's), `:arm` (how far it reaches right of the
  sidebar), `:height`, `:bar` (the horizontal bar's thickness) and
  `:label` (an element in the sidebar part).
  """
  @spec elbow(keyword()) :: term()
  def elbow(opts) do
    color = Theme.color(Keyword.fetch!(opts, :color))
    width = Keyword.fetch!(opts, :width)
    arm = Keyword.fetch!(opts, :arm)
    height = Keyword.fetch!(opts, :height)
    bar = Keyword.fetch!(opts, :bar)
    outer = Kernel.min(height, width) * 0.5
    inner = Kernel.min(arm, height - bar) * 0.75

    {outer_r, patch_align, inner_r} =
      case Keyword.get(opts, :corner, :top) do
        :top ->
          {Border.rounded_each(outer, 0, 0, 0), align_bottom(),
           Border.rounded_each(inner, 0, 0, 0)}

        :bottom ->
          {Border.rounded_each(0, 0, 0, outer), align_top(), Border.rounded_each(0, 0, 0, inner)}
      end

    patch =
      el(
        [
          align_right(),
          patch_align,
          width(px(arm)),
          height(px(height - bar)),
          Background.color(Theme.color(:black)),
          inner_r
        ],
        none()
      )

    el(
      [
        width(px(width + arm)),
        height(px(height)),
        Background.color(color),
        outer_r,
        Nearby.in_front(patch)
      ],
      el([width(px(width)), height(fill())], Keyword.get(opts, :label, none()))
    )
  end

  @doc "A flat bar segment (hex colour); `attrs` size it."
  @spec bar(non_neg_integer(), list()) :: term()
  def bar(color, attrs), do: el([Background.color(Theme.color(color))] ++ attrs, none())

  @doc "A half-round end cap, `:left` or `:right`, `height` tall."
  @spec cap(non_neg_integer(), number(), :left | :right) :: term()
  def cap(color, height, side) do
    r = height / 2

    radius =
      case side do
        :left -> Border.rounded_each(r, 0, 0, r)
        :right -> Border.rounded_each(0, r, r, 0)
      end

    el(
      [width(px(height)), height(px(height)), Background.color(Theme.color(color)), radius],
      none()
    )
  end

  @doc """
  A sidebar block: full width, `height` tall, label at the bottom right.
  `attrs` add events; `active?` marks the current view (white), `dim?`
  an unavailable step.
  """
  @spec block(non_neg_integer(), String.t(), keyword()) :: term()
  def block(color, label, opts \\ []) do
    color =
      cond do
        Keyword.get(opts, :active?, false) -> Theme.hex(:white)
        Keyword.get(opts, :dim?, false) -> Theme.dim(color)
        true -> color
      end

    height = Keyword.get(opts, :height, Theme.size(:nav))
    size = Keyword.get(opts, :font, Theme.size(:label))

    Input.button(
      [
        width(fill()),
        height(px(height)),
        Background.color(Theme.color(color)),
        padding_each(0, 14, 8, 0),
        Font.color(Theme.color(:black)),
        Font.size(size)
      ] ++ Keyword.get(opts, :attrs, []),
      el([align_right(), align_bottom()], text(String.upcase(label)))
    )
  end

  @doc """
  A pill button. Options: `:color` (hex), `:label`, `:sub` (a second line),
  `:width`, `:height`, `:attrs` (events), `:rounded` (`:both`, `:left`,
  `:right`).
  """
  @spec pill(keyword()) :: term()
  def pill(opts) do
    height = Keyword.get(opts, :height, Theme.size(:pill))
    r = height / 2

    radius =
      case Keyword.get(opts, :rounded, :both) do
        :both -> Border.rounded(r)
        :left -> Border.rounded_each(r, 0, 0, r)
        :right -> Border.rounded_each(0, r, r, 0)
      end

    label =
      el(
        [Font.size(Keyword.get(opts, :font, Theme.size(:label)))],
        text(Keyword.get(opts, :label, ""))
      )

    content =
      case Keyword.get(opts, :sub) do
        # filling the pill: a wrapped row of only centred labels collapses
        nil ->
          el([width(fill()), height(fill())], el([center_y(), align_right()], label))

        sub ->
          column([width(fill()), height(fill()), padding_xy(0, 6)], [
            el([align_left()], label),
            el([align_right(), align_bottom(), Font.size(Theme.size(:small))], text(sub))
          ])
      end

    Input.button(
      [
        width(Keyword.get(opts, :width, fill())),
        height(px(height)),
        Background.color(
          Keyword.get_lazy(opts, :fill, fn -> Theme.color(Keyword.fetch!(opts, :color)) end)
        ),
        radius,
        padding_xy(Kernel.max(r * 0.6, 18), 0),
        Font.color(Theme.color(:black))
      ] ++ Keyword.get(opts, :attrs, []),
      content
    )
  end

  @doc "A section heading in `color` (hex)."
  @spec heading(non_neg_integer(), String.t()) :: term()
  def heading(color, title) do
    h = Theme.size(:heading) + 8

    row([width(fill()), height(px(h)), spacing(12)], [
      cap(color, h, :left),
      el(
        [center_y(), Font.size(Theme.size(:heading)), Font.color(Theme.color(color))],
        text(String.upcase(title))
      ),
      el([width(fill()), height(px(6)), center_y(), Background.color(Theme.color(color))], none())
    ])
  end

  @doc "A smaller heading inside a section (an area under its floor), in `color` (hex)."
  @spec subheading(non_neg_integer(), String.t()) :: term()
  def subheading(color, title) do
    el(
      [
        height(px(30)),
        padding_each(0, 0, 0, 52),
        Font.size(Theme.size(:small) + 3),
        Font.color(Theme.color(color))
      ],
      el([center_y()], text(String.upcase(title)))
    )
  end

  @doc "Cut `text` to about `chars` characters, with an ellipsis."
  @spec fit(String.t(), pos_integer()) :: String.t()
  def fit(text, chars) do
    if String.length(text) <= chars, do: text, else: String.slice(text, 0, chars - 1) <> "…"
  end
end
