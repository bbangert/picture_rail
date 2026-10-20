defmodule HomeFrame.View.ConfigTest do
  use ExUnit.Case, async: true

  alias HomeFrame.View.Config

  test "FRAME156 gets DRM output, OpenGL and touch input" do
    config = Config.build(HomeFrame.Hardware.Frame156)
    assert %Emerge.Config.DRM{card: "/dev/dri/card0", hotplug_interval_ms: nil} = config.output
    assert %Emerge.Config.Renderer{api: :opengl} = config.renderer
    assert config.input == [events: [:touch]]
  end

  test "the host gets a window" do
    assert %Emerge.Config.Window{size: {1920, 1080}} =
             Config.build(HomeFrame.Hardware.Host).output
  end

  test "assets: screen-sized decodes, a small cache, the photo cache readable, the fonts" do
    assets = Config.build(HomeFrame.Hardware.Host).assets
    assert assets.decode_at_size
    assert assets.cache.max_entries == 16
    assert assets.runtime_paths.allowlist == [HomeFrame.Paths.photo_cache_dir()]

    for font <- assets.fonts do
      assert File.exists?(Application.app_dir(:homeframe, Path.join("priv", font.source)))
    end

    assert Enum.map(assets.fonts, &{&1.family, &1.weight}) == [
             {"Antonio", 400},
             {"Antonio", 700},
             {"Noto Sans", 400},
             {"Noto Sans", 700}
           ]
  end
end
