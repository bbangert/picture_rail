import Config

# Pastigio FRAME156 (Rockchip PX30, 1920x1080 touch panel), built with
# nerves_system_rk3326_frame156.
config :homeframe,
  hardware: HomeFrame.Hardware.Frame156,
  data_dir: "/root"

# The viewport is started by hand over SSH (HomeFrame.View.start()) until
# it has passed the on-device soak (plan task 8.4).
config :homeframe, start_view: false
