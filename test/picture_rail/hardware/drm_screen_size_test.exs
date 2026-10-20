defmodule PictureRail.Hardware.DrmScreenSizeTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  defp connector(dir, name, status, modes) do
    path = Path.join(dir, name)
    File.mkdir_p!(path)
    File.write!(Path.join(path, "status"), status)
    File.write!(Path.join(path, "modes"), modes)
  end

  test "reads the first mode of the connected connector", %{tmp_dir: dir} do
    connector(dir, "card0-HDMI-A-1", "disconnected\n", "")
    connector(dir, "card0-eDP-1", "connected\n", "1366x768\n1024x768\n")
    assert PictureRail.Hardware.drm_screen_size("card0", dir) == {1366, 768}
  end

  test "nil without a connected connector", %{tmp_dir: dir} do
    connector(dir, "card0-eDP-1", "disconnected\n", "")
    assert PictureRail.Hardware.drm_screen_size("card0", dir) == nil
  end
end
