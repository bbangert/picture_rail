defmodule PictureRail.Web.FormTest do
  use ExUnit.Case, async: true

  alias PictureRail.Settings
  alias PictureRail.Setup.Secret
  alias PictureRail.Web.Form

  @immich %{
    "type" => "immich",
    "url" => "https://photos.example.com",
    "api_key" => "secret-key",
    "album_ids" => ["a1"]
  }

  defp public(map) do
    {:ok, settings} = Settings.parse(map)
    Settings.public(settings)
  end

  defp shown(ids), do: Enum.map(ids, &Form.shown_id/1)

  test "sections by path; Wi-Fi isn't one" do
    assert Form.section("home_assistant") == {:ok, :home_assistant}
    assert Form.section("wifi") == :error
    assert Form.slug(:photo_source) == "photo_source"
  end

  test "shown inputs override what's saved; the rest is kept" do
    public = public(%{"photo_source" => @immich})

    params = %{
      "type" => "immich",
      "f" => %{"photo_source" => %{"url" => " https://new.example.com ", "api_key" => ""}},
      "shown" => shown([{"photo_source", "url"}, {"photo_source", "api_key"}])
    }

    draft = Form.draft(:photo_source, params, public)
    assert draft[{"photo_source", "url"}] == "https://new.example.com"
    # an empty secret keeps the saved one
    assert draft[{"photo_source", "api_key"}] == nil
    # the albums weren't shown: kept
    assert draft[{"photo_source", "album_ids"}] == ["a1"]

    params = put_in(params, ["f", "photo_source", "api_key"], "new-key")
    params = %{params | "shown" => params["shown"] ++ shown([{"photo_source", "album_ids"}])}
    draft = Form.draft(:photo_source, params, public)
    assert draft[{"photo_source", "api_key"}] == %Secret{value: "new-key"}
    # shown and nothing ticked: none
    assert draft[{"photo_source", "album_ids"}] == []
    assert Form.typed_secret?(draft)
  end

  test "toggles, numbers and seconds" do
    params = %{
      "f" => %{
        "home_assistant" => %{"url" => "http://ha.local:8123"},
        "slideshow" => %{"interval_ms" => "1.5", "fade_ms" => "x"},
        "cache" => %{"window" => "30"}
      },
      "shown" =>
        shown([
          {"home_assistant", "ssl_verify"},
          {"slideshow", "interval_ms"},
          {"slideshow", "fade_ms"},
          {"cache", "window"},
          {"cache", "include_live_photos"}
        ])
    }

    draft = Form.draft(:home_assistant, params, public(%{}))
    # an unticked checkbox posts nothing: off
    assert draft[{"home_assistant", "ssl_verify"}] == false
    # not shown: left as it was (nothing saved)
    assert draft[{"home_assistant", "url"}] == nil

    draft = Form.draft(:display, params, public(%{}))
    assert draft[{"slideshow", "interval_ms"}] == 1_500
    # kept as text, for validation to reject
    assert draft[{"slideshow", "fade_ms"}] == "x"
    assert draft[{"cache", "window"}] == 30
    assert draft[{"cache", "include_live_photos"}] == false
  end

  test "params that aren't the expected shape are ignored" do
    draft =
      Form.draft(:display, %{"f" => "nope", "shown" => "slideshow/interval_ms"}, public(%{}))

    assert draft[{"slideshow", "interval_ms"}] == nil
  end

  test "inputs: secrets never carry a value, seconds as a number" do
    public = public(%{"photo_source" => @immich})
    draft = PictureRail.Setup.draft(:photo_source, public)
    inputs = Form.inputs(:photo_source, draft, public, %{}, %{})
    key = Enum.find(inputs, &(&1.id == {"photo_source", "api_key"}))
    assert key.value == nil
    assert key.set?

    display = Form.inputs(:display, PictureRail.Setup.draft(:display, public), public, %{}, %{})
    assert hd(display).value == "6"
    assert Form.seconds(1_250) == "1.25"
  end
end
