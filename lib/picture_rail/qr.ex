defmodule PictureRail.QR do
  @moduledoc """
  A QR code as data: rows of runs of dark and light modules, for
  `PictureRail.View.QR` to draw (one element per run rather than one per
  module). Encoding is pure Elixir and not cheap, so it's done once per
  text by whoever owns the text (the `:pairing` controller), not on every
  render.
  """

  @type runs :: [[{:dark | :light, pos_integer()}]]

  @doc "`text` as a QR code (error correction M), in runs per row."
  @spec encode(String.t()) :: runs()
  def encode(text), do: text |> EQRCode.encode(:m) |> Map.fetch!(:matrix) |> runs()

  @doc """
  A matrix (rows of `0`/`1`, as tuples or lists) as runs per row:
  `[{:dark | :light, length}]`.
  """
  @spec runs(tuple() | [list()]) :: runs()
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
end
