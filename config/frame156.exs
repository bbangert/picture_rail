import Config

# Pastigio FRAME156 (Rockchip PX30, 1920x1080 touch panel), built with
# nerves_system_rk3326_frame156.
config :picture_rail,
  hardware: PictureRail.Hardware.Frame156,
  data_dir: "/root"
