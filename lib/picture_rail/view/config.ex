defmodule PictureRail.View.Config do
  @moduledoc """
  The Emerge configuration for the viewport: the hardware module's screen
  settings plus the app's fonts and asset rules.

  Images load from the photo cache and from the Home Assistant pictures
  the panel shows (`PictureRail.HA.Picture.dir/0`). Photos are decoded at their on-screen size and the decoded-image cache
  is kept small (16 images, 64 MB), so a device with 1 GB of RAM never
  holds full-size originals. The renderer's cache of painted layers (a
  full-screen layer is about 8 MB) is capped at 64 MB, down from 640 MB.
  """

  alias Emerge.Config.{
    AssetCache,
    Assets,
    Font,
    PaintLayerCache,
    Renderer,
    RendererCache,
    RuntimePaths
  }

  alias PictureRail.HA.Picture

  @fonts [
    {"Antonio", "fonts/Antonio-Regular.ttf", 400},
    {"Antonio", "fonts/Antonio-Bold.ttf", 700},
    {"Noto Sans", "fonts/NotoSans-Regular.ttf", 400},
    {"Noto Sans", "fonts/NotoSans-Bold.ttf", 700}
  ]

  @doc "Build the config for `hardware` (default: the configured hardware module)."
  @spec build(module()) :: Emerge.Config.t()
  def build(hardware \\ PictureRail.Hardware.impl()) do
    base = %Emerge.Config{
      assets: %Assets{
        otp_app: :picture_rail,
        decode_at_size: true,
        cache: %AssetCache{max_entries: 16, max_bytes: 64 * 1024 * 1024},
        runtime_paths: %RuntimePaths{
          enabled: true,
          allowlist: [PictureRail.Paths.photo_cache_dir(), Picture.dir()]
        },
        fonts:
          for(
            {family, source, weight} <- @fonts,
            do: %Font{family: family, source: source, weight: weight}
          )
      }
    }

    base
    |> struct!(hardware.emerge_config())
    |> cap_renderer_cache()
  end

  defp cap_renderer_cache(config) do
    renderer =
      case config.renderer do
        %Renderer{} = renderer -> renderer
        options -> struct!(Renderer, options)
      end

    cache = %RendererCache{
      paint_layer: %PaintLayerCache{
        max_bytes: 64 * 1024 * 1024,
        max_entry_bytes: 16 * 1024 * 1024
      }
    }

    %{config | renderer: %{renderer | cache: cache}}
  end
end
