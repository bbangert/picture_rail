defmodule PictureRail.View.QRTest do
  use ExUnit.Case, async: true

  alias PictureRail.View.QR

  test "a matrix as runs of dark and light modules per row" do
    assert QR.runs({{1, 1, 0, 1}, {0, 0, 0, 0}}) == [
             [dark: 2, light: 1, dark: 1],
             [light: 4]
           ]

    assert QR.runs([[0, 1]]) == [[light: 1, dark: 1]]
  end

  test "rendered with a quiet zone: the side covers every module" do
    matrix = EQRCode.encode("http://192.168.1.40/pair?code=123456", :m).matrix
    {side, _element} = QR.render("http://192.168.1.40/pair?code=123456", 7)
    assert side == (tuple_size(matrix) + 8) * 7
  end
end
