defmodule PictureRail.SetupTest do
  use ExUnit.Case, async: true

  alias PictureRail.{Settings, Setup}
  alias PictureRail.Setup.Secret

  defp public(map) do
    {:ok, settings} = Settings.parse(map)
    Settings.public(settings)
  end

  @immich %{
    "photo_source" => %{
      "type" => "immich",
      "url" => "https://photos.example.com",
      "api_key" => "secret-key",
      "album_ids" => ["a1"]
    }
  }

  test "a draft holds what's saved, or the defaults, and never a stored secret" do
    draft = Setup.draft(:photo_source, public(@immich))

    assert draft == %{
             {"photo_source", "type"} => "immich",
             {"photo_source", "url"} => "https://photos.example.com",
             {"photo_source", "album_ids"} => ["a1"]
           }

    assert Setup.draft(:photo_source, public(%{})) == %{
             {"photo_source", "type"} => "immich",
             {"photo_source", "url"} => nil,
             {"photo_source", "album_ids"} => []
           }

    assert Setup.draft(:home_assistant, public(%{})) == %{
             {"home_assistant", "url"} => nil,
             {"home_assistant", "ssl_verify"} => true
           }

    display = Setup.draft(:display, public(%{"slideshow" => %{"interval_ms" => 9_000}}))
    assert display[{"slideshow", "interval_ms"}] == 9_000
    assert display[{"cache", "include_live_photos"}] == true
    assert display[{"live_photo", "pause_ms"}] == 3_000
  end

  test "secret_set? from the public settings, only for the stored type" do
    p = public(@immich)
    draft = Setup.draft(:photo_source, p)
    assert Setup.secret_set?({"photo_source", "api_key"}, draft, p)

    refute Setup.secret_set?(
             {"photo_source", "api_key"},
             %{draft | {"photo_source", "type"} => "x"},
             p
           )

    refute Setup.secret_set?({"home_assistant", "token"}, %{}, p)
  end

  test "values to save: typed secrets unwrapped, untouched ones left out" do
    draft = Setup.draft(:photo_source, public(@immich))

    assert Setup.values(:photo_source, draft) == %{
             "photo_source" => %{
               "type" => "immich",
               "url" => "https://photos.example.com",
               "album_ids" => ["a1"]
             }
           }

    typed = Map.put(draft, {"photo_source", "api_key"}, %Secret{value: "new"})
    assert Setup.values(:photo_source, typed)["photo_source"]["api_key"] == "new"

    emptied = Map.put(draft, {"photo_source", "api_key"}, %Secret{value: ""})
    refute Map.has_key?(Setup.values(:photo_source, emptied)["photo_source"], "api_key")

    assert Map.keys(Setup.values(:display, Setup.draft(:display, public(%{})))) ==
             ~w(cache live_photo panel slideshow)
  end

  test "the config to try a draft with fills in the stored secret" do
    draft = Setup.draft(:photo_source, public(@immich))
    stored = Map.put(@immich["photo_source"], "album_ids", ["old"])
    config = Setup.source_config(Map.put(draft, {"photo_source", "url"}, "http://new"), stored)
    assert config["api_key"] == "secret-key"
    assert config["url"] == "http://new"
    assert config["album_ids"] == ["a1"]

    assert Setup.source_config(draft, %{"type" => "other", "api_key" => "k"})["api_key"] == nil
    assert Setup.source_config(draft, nil)["api_key"] == nil
  end

  test "steps stay within the field's bounds" do
    interval = Setup.field(:display, %{}, {"slideshow", "interval_ms"})
    assert Setup.step(interval, 6_000, 1) == 7_000
    assert Setup.step(interval, 1_000, -1) == 1
    assert Setup.step(interval, 3_600_000, 1) == 3_600_000
    assert Setup.step(interval, nil, 1) == 7_000
  end

  test "choices toggle in and out" do
    assert Setup.toggle_choice(nil, "a") == ["a"]
    assert Setup.toggle_choice(["a", "b"], "a") == ["b"]
    assert Setup.toggle_choice(["b"], "a") == ["b", "a"]
  end

  test "validation messages land on their fields; the rest stay with the section" do
    messages = [
      "slideshow.fade_ms must be shorter than slideshow.interval_ms",
      "panel.timeout_ms must be a positive integer",
      "the settings file must contain a JSON object"
    ]

    assert Setup.field_errors(:display, %{}, messages) ==
             {%{
                {"slideshow", "fade_ms"} => "must be shorter than slideshow.interval_ms",
                {"panel", "timeout_ms"} => "must be a positive integer"
              }, ["the settings file must contain a JSON object"]}
  end

  test "secrets in a draft don't show in inspect" do
    refute inspect(%{x: %Secret{value: "hunter2"}}) =~ "hunter2"
  end
end
