defmodule PictureRail.QRTest do
  use ExUnit.Case, async: true

  alias PictureRail.QR

  test "a matrix as runs of dark and light modules per row" do
    assert QR.runs({{1, 1, 0, 1}, {0, 0, 0, 0}}) == [
             [dark: 2, light: 1, dark: 1],
             [light: 4]
           ]

    assert QR.runs([[0, 1]]) == [[light: 1, dark: 1]]
  end

  test "drawn with a quiet zone: the side covers every module" do
    text = "http://192.168.1.40/pair?code=12345678"
    matrix = EQRCode.encode(text, :m).matrix
    rows = QR.encode(text)
    assert length(rows) == tuple_size(matrix)

    {side, _element} = PictureRail.View.QR.render(rows, 7)
    assert side == (tuple_size(matrix) + 8) * 7
  end
end
