defmodule PictureRail.View.QR do
  @moduledoc """
  A QR code (`EQRCode`) drawn with Emerge elements, for a phone's camera to
  read off the screen: dark on white with a quiet zone around it, one row
  per module row, and one element per run of dark or light modules (a few
  hundred elements rather than a thousand cells).
  """
  use Emerge.UI

  alias PictureRail.View.Theme

  @quiet 4

  @doc """
  A matrix (rows of `0`/`1`, as tuples or lists) as runs per row:
  `[{:dark | :light, length}]`.
  """
  @spec runs(tuple() | [list()]) :: [[{:dark | :light, pos_integer()}]]
  def runs(matrix) do
    for row <- to_list(matrix) do
      row
      |> to_list()
      |> Enum.chunk_by(&(&1 == 1))
      |> Enum.map(fn [first | _] = run ->
        {if(first == 1, do: :dark, else: :light), length(run)}
      end)
    end
  end

  defp to_list(tuple) when is_tuple(tuple), do: Tuple.to_list(tuple)
  defp to_list(list) when is_list(list), do: list

  @doc """
  `text` as a QR code, `module` px per module: `{side, element}`, `side`
  the element's width and height in px.
  """
  @spec render(String.t(), pos_integer()) :: {pos_integer(), term()}
  def render(text, module) do
    rows = text |> EQRCode.encode(:m) |> Map.fetch!(:matrix) |> runs()
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
