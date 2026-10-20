defmodule HomeFrame.SettingsTest do
  use ExUnit.Case, async: true

  alias HomeFrame.Settings
  alias HomeFrame.Settings.{HomeAssistant, Immich}

  @full %{
    "immich" => %{
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

    assert %Immich{
             url: "https://photos.example.com",
             api_key: "secret-key",
             album_ids: ["a1", "a2"]
           } =
             settings.immich

    assert %HomeAssistant{url: "http://ha.lan:8123", token: "secret-token", ssl_verify: true} =
             settings.home_assistant

    assert settings.slideshow == %{interval_ms: 10_000, fade_ms: 1_500}
    assert settings.cache == %{window: 40, include_live_photos: false}
    assert settings.panel == %{timeout_ms: 30_000, long_press_ms: 500}
  end

  test "an empty object is the defaults: nothing configured" do
    assert Settings.parse(%{}) == {:ok, Settings.defaults()}
    assert Settings.defaults().immich == nil
  end

  test "incomplete or wrongly typed sections are reported, all at once" do
    bad = %{
      "immich" => %{"url" => "photos.example.com", "album_ids" => "a1"},
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
             "panel must be an object"
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
    assert public.immich.url == "https://photos.example.com"
    assert public.home_assistant.ssl_verify
  end

  test "a missing file gives the defaults" do
    assert Settings.load("/nonexistent/homeframe.json") == {:ok, Settings.defaults()}
  end
end
