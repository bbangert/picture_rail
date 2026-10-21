defmodule PictureRail.View.SetupPageTest do
  use ExUnit.Case, async: true

  alias PictureRail.{Settings, Setup}
  alias PictureRail.Setup.Secret
  alias PictureRail.View.SetupPage

  defp exposed(map) do
    {:ok, settings} = Settings.parse(map)
    %{settings: Settings.public(settings)}
  end

  @immich %{
    "photo_source" => %{
      "type" => "immich",
      "url" => "https://photos.example.com",
      "api_key" => "k",
      "album_ids" => ["a1", "a2", "a3"]
    },
    "home_assistant" => %{"url" => "http://homeassistant.local:8123", "token" => "t"},
    "slideshow" => %{"interval_ms" => 10_000, "fade_ms" => 1_250}
  }

  test "section summaries" do
    settings = exposed(@immich)
    assert SetupPage.section_summary(:photo_source, settings) == "Immich · 3 albums"

    assert SetupPage.section_summary(:photo_source, settings, %{status: :online, photos: 40}) ==
             "Immich · 3 albums · 40 photos"

    assert SetupPage.section_summary(:home_assistant, settings) == "homeassistant.local"
    assert SetupPage.section_summary(:display, settings) == "Every 10 s · fade 1.25 s"
    assert SetupPage.section_summary(:photo_source, exposed(%{})) == "Not set up"
    assert SetupPage.section_summary(:home_assistant, exposed(%{})) == "Not set up"
    assert SetupPage.section_summary(:photo_source, nil) == "Not set up"
  end

  test "field rows of a section: values, masked or set secrets, bounds, choices" do
    public = exposed(@immich).settings
    draft = Setup.draft(:photo_source, public)

    setup = %{
      section: :photo_source,
      draft: draft,
      errors: %{{"photo_source", "url"} => "must start with http:// or https://"},
      choices: %{{"photo_source", "album_ids"} => :loading}
    }

    assert SetupPage.field_rows(setup, public, nil) == [
             {:text, {"photo_source", "url"}, "Server URL", "https://photos.example.com", true,
              "must start with http:// or https://"},
             {:text, {"photo_source", "api_key"}, "API key", "•••• set", true, nil},
             {:choices, {"photo_source", "album_ids"}, "Albums", :loading, ["a1", "a2", "a3"],
              nil}
           ]

    typed = %{setup | draft: Map.put(draft, {"photo_source", "api_key"}, %Secret{value: "abc"})}

    assert {:text, _, _, "•••", true, nil} =
             typed |> SetupPage.field_rows(public, nil) |> Enum.at(1)

    unset = Setup.draft(:home_assistant, exposed(%{}).settings)

    assert [
             {:text, _, "Server URL", nil, false, nil},
             {:text, _, "Access token", nil, false, nil},
             {:toggle, {"home_assistant", "ssl_verify"}, _, true, nil}
           ] =
             SetupPage.field_rows(
               %{section: :home_assistant, draft: unset, errors: %{}, choices: %{}},
               exposed(%{}).settings,
               nil
             )

    display = %{
      section: :display,
      draft: Setup.draft(:display, exposed(%{}).settings),
      errors: %{},
      choices: %{}
    }

    rows = SetupPage.field_rows(display, exposed(%{}).settings, nil)
    assert {:stepper, _, "Photo interval", "6 s", true, true, nil} = hd(rows)
    assert {:stepper, _, "Fade", "1.5 s", true, true, nil} = Enum.at(rows, 1)

    at_min = put_in(display, [:draft, {"slideshow", "fade_ms"}], 0)

    assert {:stepper, _, "Fade", "0 s", false, true, nil} =
             at_min |> SetupPage.field_rows(exposed(%{}).settings, nil) |> Enum.at(1)
  end

  test "durations" do
    assert SetupPage.seconds(6_000) == "6 s"
    assert SetupPage.seconds(500) == "0.5 s"
    assert SetupPage.seconds(0) == "0 s"
  end
end
