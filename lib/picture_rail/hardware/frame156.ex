defmodule PictureRail.Hardware.Frame156 do
  @moduledoc """
  Pastigio FRAME156: Rockchip PX30, 1920x1080 panel over DSI and an
  LT8911EXB bridge, Silead GSL3676 touchscreen, MC3419-family
  accelerometer, Mali-G31 (Panfrost) GPU.

  Needs nerves_system_rk3326_frame156 and the touchscreen firmware in
  `rootfs_overlay/lib/firmware/silead/gsl3676.fw` (see the README).
  """
  @behaviour PictureRail.Hardware

  alias PictureRail.Hardware.Frame156.{Accelerometer, DdrRate}

  @impl PictureRail.Hardware
  def children, do: [Accelerometer, DdrRate]

  # The panel varies by unit (1920x1080 or 1366x768), so read the mode.
  @impl PictureRail.Hardware
  def screen_size, do: PictureRail.Hardware.drm_screen_size("card0")

  # The accelerometer starts before the app and never calls into it.
  @impl PictureRail.Hardware
  def orientation do
    if Process.whereis(Accelerometer), do: Accelerometer.get(), else: :unknown
  end

  @impl PictureRail.Hardware
  def emerge_config do
    [
      # One fixed panel: no hotplug polling
      output: %Emerge.Config.DRM{card: "/dev/dri/card0", hotplug_interval_ms: nil},
      renderer: %Emerge.Config.Renderer{api: :opengl},
      input: [events: [:touch]]
    ]
  end
end
