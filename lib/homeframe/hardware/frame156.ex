defmodule HomeFrame.Hardware.Frame156 do
  @moduledoc """
  Pastigio FRAME156: Rockchip PX30, 1920x1080 panel over DSI and an
  LT8911EXB bridge, Silead GSL3676 touchscreen, MC3419-family
  accelerometer, Mali-G31 (Panfrost) GPU.

  Needs nerves_system_rk3326_frame156 and the touchscreen firmware in
  `rootfs_overlay/lib/firmware/silead/gsl3676.fw` (see the README).
  """
  @behaviour HomeFrame.Hardware

  alias HomeFrame.Hardware.Frame156.{Accelerometer, DdrRate}

  @impl HomeFrame.Hardware
  def children, do: [Accelerometer, DdrRate]

  @impl HomeFrame.Hardware
  def emerge_config do
    [
      # One fixed panel: no hotplug polling
      output: %Emerge.Config.DRM{card: "/dev/dri/card0", hotplug_interval_ms: nil},
      renderer: %Emerge.Config.Renderer{api: :opengl},
      input: [events: [:touch]]
    ]
  end
end
