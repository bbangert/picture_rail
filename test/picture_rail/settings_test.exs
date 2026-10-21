defmodule PictureRail.SettingsTest do
  use ExUnit.Case, async: true

  alias PictureRail.Immich.Source
  alias PictureRail.Settings
  alias PictureRail.Settings.{HomeAssistant, PhotoSource}

  @full %{
    "photo_source" => %{
      "type" => "immich",
      "url" => "https://photos.example.com/",
      "api_key" => "secret-key",
      "album_ids" => ["a1", "a2"]
    },
    "home_assistant" => %{"url" => "http://ha.lan:8123", "token" => "secret-token"},
    "slideshow" => %{"interval_ms" => 10_000},
    "cache" => %{"window" => 40, "include_live_photos" => false}
  }

  test "a full file parses, with defaults for what's left out" do
    assert {:ok, settings} = Settings.parse(@full)

    assert %PhotoSource{
             module: Source,
             config: %{
               "url" => "https://photos.example.com",
               "api_key" => "secret-key",
               "album_ids" => ["a1", "a2"],
               "album_names" => []
             }
           } = settings.photo_source

    assert %HomeAssistant{url: "http://ha.lan:8123", token: "secret-token", ssl_verify: true} =
             settings.home_assistant

    assert settings.slideshow == %{interval_ms: 10_000, fade_ms: 1_500}
    assert settings.cache == %{window: 40, include_live_photos: false}
    assert settings.panel == %{timeout_ms: 30_000, long_press_ms: 500}
    assert settings.live_photo == %{pause_ms: 3_000}
  end

  test "a legacy immich section is read as an Immich photo source" do
    legacy = %{"immich" => Map.delete(@full["photo_source"], "type")}
    assert {:ok, settings} = Settings.parse(legacy)
    assert {:ok, current} = Settings.parse(@full)
    assert settings.photo_source == current.photo_source

    assert %PictureRail.Settings.Immich{url: "https://photos.example.com", api_key: "secret-key"} =
             Source.immich(settings)

    assert {:error, ["immich.api_key is required"]} =
             Settings.parse(%{"immich" => %{"url" => "http://immich"}})

    assert {:error, ["immich must be an object"]} = Settings.parse(%{"immich" => "x"})
  end

  test "with both, photo_source wins over the legacy section" do
    both = Map.put(@full, "immich", %{"url" => "nonsense"})
    assert {:ok, settings} = Settings.parse(both)
    assert settings.photo_source.config["url"] == "https://photos.example.com"
  end

  test "the photo source's type must be a known one" do
    assert {:error, ["photo_source.type must be one of: immich"]} =
             Settings.parse(%{"photo_source" => %{"type" => "flickr"}})

    assert {:error, ["photo_source.type must be one of: immich"]} =
             Settings.parse(%{"photo_source" => %{"type" => 1}})

    assert {:error, ["photo_source.type is required"]} =
             Settings.parse(%{"photo_source" => %{"url" => "http://x"}})

    assert {:error, ["photo_source must be an object"]} =
             Settings.parse(%{"photo_source" => []})

    assert {:error, ["photo_source.url is required", "photo_source.api_key is required"]} =
             Settings.parse(%{"photo_source" => %{"type" => "immich"}})
  end

  test "values, fields and credentials of each section" do
    {:ok, settings} = Settings.parse(@full)

    assert Settings.values(settings, "photo_source")["type"] == "immich"
    assert Settings.values(settings, "home_assistant")["token"] == "secret-token"

    assert Settings.values(settings, "slideshow") == %{
             "interval_ms" => 10_000,
             "fade_ms" => 1_500
           }

    assert Settings.values(Settings.defaults(), "photo_source") == nil
    assert Settings.fields(settings, "photo_source") == Source.fields()
    assert Settings.fields(Settings.defaults(), "photo_source") == []

    assert Settings.credentials(settings) == %{
             "photo_source" => %{"api_key" => "secret-key"},
             "home_assistant" => %{"token" => "secret-token"}
           }

    assert Settings.credentials(Settings.defaults()) == %{
             "photo_source" => %{},
             "home_assistant" => %{}
           }
  end

  test "an empty object is the defaults: nothing configured" do
    assert Settings.parse(%{}) == {:ok, Settings.defaults()}
    assert Settings.defaults().photo_source == nil
  end

  test "incomplete or wrongly typed sections are reported, all at once" do
    bad = %{
      "immich" => %{"url" => "photos.example.com", "album_ids" => "a1"},
      "live_photo" => %{"pause_ms" => 60_001},
      "home_assistant" => %{"url" => "http://ha", "token" => "", "ssl_verify" => "no"},
      "slideshow" => %{"interval_ms" => 0, "fade_ms" => -1},
      "panel" => "fast"
    }

    assert {:error, errors} = Settings.parse(bad)

    assert errors == [
             "immich.url must start with http:// or https://",
             "immich.api_key is required",
             "immich.album_ids must be a list of strings",
             "home_assistant.token must be a non-empty string",
             "home_assistant.ssl_verify must be true or false",
             "slideshow.interval_ms must be a positive integer",
             "slideshow.fade_ms must be a non-negative integer",
             "panel must be an object",
             "live_photo.pause_ms must be at most 60000"
           ]
  end

  test "the fade must be shorter than the interval" do
    assert {:error, ["slideshow.fade_ms must be shorter than slideshow.interval_ms"]} =
             Settings.parse(%{"slideshow" => %{"interval_ms" => 1_000, "fade_ms" => 1_000}})
  end

  test "bad JSON and non-objects are reported" do
    assert {:error, ["not valid JSON: " <> _]} = Settings.decode("{")
    assert {:error, ["the settings file must contain a JSON object"]} = Settings.decode("[]")
  end

  test "credentials stay out of inspect output and the public copy" do
    {:ok, settings} = Settings.parse(@full)
    refute inspect(settings) =~ "secret"
    public = Settings.public(settings)
    refute inspect(public) =~ "secret"
    assert public.photo_source["url"] == "https://photos.example.com"
    assert public.photo_source["type"] == "immich"
    assert public.photo_source["api_key_set?"]
    assert public.home_assistant["ssl_verify"]
    assert public.home_assistant["token_set?"]
    assert public.slideshow.interval_ms == 10_000
    assert Settings.public(Settings.defaults()).photo_source == nil
  end

  test "a missing file gives the defaults" do
    assert Settings.load("/nonexistent/picture_rail.json") == {:ok, Settings.defaults()}
  end
end
