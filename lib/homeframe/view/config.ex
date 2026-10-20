defmodule HomeFrame.View.Config do
  @moduledoc """
  The Emerge configuration for the viewport: the hardware module's screen
  settings plus the app's fonts and asset rules.

  Photos are decoded at their on-screen size and the decoded-image cache
  is kept small (16 images, 64 MB), so a device with 1 GB of RAM never
  holds full-size originals.
  """

  alias Emerge.Config.{AssetCache, Assets, Font, RuntimePaths}

  @fonts [
    {"Antonio", "fonts/Antonio-Regular.ttf", 400},
    {"Antonio", "fonts/Antonio-Bold.ttf", 700},
    {"Noto Sans", "fonts/NotoSans-Regular.ttf", 400},
    {"Noto Sans", "fonts/NotoSans-Bold.ttf", 700}
  ]

  @doc "Build the config for `hardware` (default: the configured hardware module)."
  @spec build(module()) :: Emerge.Config.t()
  def build(hardware \\ HomeFrame.Hardware.impl()) do
    base = %Emerge.Config{
      assets: %Assets{
        otp_app: :homeframe,
        decode_at_size: true,
        cache: %AssetCache{max_entries: 16, max_bytes: 64 * 1024 * 1024},
        runtime_paths: %RuntimePaths{
          enabled: true,
          allowlist: [HomeFrame.Paths.photo_cache_dir()]
        },
        fonts:
          for(
            {family, source, weight} <- @fonts,
            do: %Font{family: family, source: source, weight: weight}
          )
      }
    }

    struct!(base, hardware.emerge_config())
  end
end
