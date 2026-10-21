defmodule PictureRail.AppTest do
  use ExUnit.Case, async: true

  test "no first boot without the network (its backend isn't there to ask)" do
    refute Process.whereis(PictureRail.Network)
    refute PictureRail.App.first_boot?(%{photo_source: false, home_assistant: false})
  end
end
