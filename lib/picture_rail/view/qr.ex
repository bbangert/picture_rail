defmodule PictureRail.View.QR do
  @moduledoc """
  A QR code (`PictureRail.QR`'s runs) drawn with Emerge elements, for a
  phone's camera to read off the screen: dark on white with a quiet zone
  around it, one row per module row, and one element per run of dark or
  light modules (a few hundred elements rather than a thousand cells).
  """
  use Emerge.UI

  alias PictureRail.View.Theme

  @quiet 4

  @doc """
  The runs (`PictureRail.QR.encode/1`), `module` px per module:
  `{side, element}`, `side` the element's width and height in px.
  """
  @spec render(PictureRail.QR.runs(), pos_integer()) :: {pos_integer(), term()}
  def render(rows, module) do
    side = (length(rows) + 2 * @quiet) * module

    lines =
      for runs <- rows do
        row(
          [height(px(module))],
          for {kind, n} <- runs do
            el([width(px(n * module)), height(px(module))] ++ module_fill(kind), none())
          end
        )
      end

    {side,
     el(
       [
         width(px(side)),
         height(px(side)),
         padding(@quiet * module),
         Background.color(Theme.color(0xFFFFFF))
       ],
       column([], lines)
     )}
  end

  defp module_fill(:dark), do: [Background.color(Theme.color(0x000000))]
  defp module_fill(:light), do: []
end
