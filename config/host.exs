import Config

# Add configuration that is only needed when running on the host here.

config :nerves_runtime,
  kv_backend:
    {Nerves.Runtime.KVBackend.InMemory,
     contents: %{
       # The KV store on Nerves systems is typically read from UBoot-env, but
       # this allows us to use a pre-populated InMemory store when running on
       # host for development and testing.
       #
       # https://nerves-runtime.hexdocs.pm/readme.html#using-nerves_runtime-in-tests
       # https://nerves-runtime.hexdocs.pm/readme.html#nerves-system-and-firmware-metadata

       "nerves_fw_active" => "a",
       "a.nerves_fw_architecture" => "generic",
       "a.nerves_fw_description" => "N/A",
       "a.nerves_fw_platform" => "host",
       "a.nerves_fw_version" => "0.0.0"
     }}

# Development on a laptop: Emerge's default windowed backend, no sensors,
# settings and caches under tmp/ in the project.
config :homeframe,
  hardware: HomeFrame.Hardware.Host,
  data_dir: Path.expand("../tmp/data", __DIR__)

# The desktop's udevd owns input devices; Nerves.UEvent shouldn't.
config :nerves_uevent, manage_udev: false

# Tests drive controllers and modules directly; don't open a window.
if config_env() == :test do
  config :homeframe, start_view: false, data_dir: Path.expand("../tmp/test-data", __DIR__)
end
