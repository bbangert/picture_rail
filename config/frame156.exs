import Config

# Pastigio FRAME156 (Rockchip PX30, 1920x1080 touch panel), built with
# nerves_system_rk3326_frame156.
config :homeframe,
  hardware: HomeFrame.Hardware.Frame156,
  data_dir: "/root"
