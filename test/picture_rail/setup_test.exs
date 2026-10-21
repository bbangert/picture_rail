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
    assert display[{"panel", "long_press_ms"}] == 500
    # not shown: not in the draft either
    refute Map.has_key?(display, {"live_photo", "pause_ms"})
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
               "album_ids" => ["a1"],
               # albums by name (hand-edited files) give way to the ones shown
               "album_names" => nil
             }
           }

    typed = Map.put(draft, {"photo_source", "api_key"}, %Secret{value: "new"})
    assert Setup.values(:photo_source, typed)["photo_source"]["api_key"] == "new"

    emptied = Map.put(draft, {"photo_source", "api_key"}, %Secret{value: ""})
    refute Map.has_key?(Setup.values(:photo_source, emptied)["photo_source"], "api_key")

    display = Setup.values(:display, Setup.draft(:display, public(%{})))
    assert Map.keys(display) == ~w(cache live_photo panel slideshow)
    # not shown (nothing plays Live Photos yet): left as it is
    assert display["live_photo"] == %{}
  end

  test "the config to try a draft with fills in the stored secret, for the same server" do
    draft = Setup.draft(:photo_source, public(@immich))
    stored = Map.put(@immich["photo_source"], "album_ids", ["old"])
    assert {:ok, config} = Setup.source_config(draft, stored)
    assert config["api_key"] == "secret-key"
    assert config["album_ids"] == ["a1"]

    # another server: the key has to be typed again
    moved = Map.put(draft, {"photo_source", "url"}, "http://attacker")

    assert Setup.source_config(moved, stored) ==
             {:error, "API key must be entered again for a new server"}

    retyped = Map.put(moved, {"photo_source", "api_key"}, %Secret{value: "typed"})

    assert {:ok, %{"api_key" => "typed", "url" => "http://attacker"}} =
             Setup.source_config(retyped, stored)

    for stored <- [%{"type" => "other", "api_key" => "k"}, nil] do
      assert {:ok, config} = Setup.source_config(draft, stored)
      refute Map.has_key?(config, "api_key")
    end
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

  describe "Wi-Fi" do
    test "a listed network asks for a password only when it has one" do
      secured = Setup.wifi_draft(%{ssid: "Home", security: :wpa2})
      assert [{"wifi", %{key: "password", type: :secret}}] = Setup.fields(:wifi, secured)
      assert Setup.fields(:wifi, Setup.wifi_draft(%{ssid: "Cafe", security: :open})) == []
      assert Setup.fields(:wifi, Setup.draft(:wifi, %{})) == []

      other = Setup.wifi_draft(nil)

      assert ["ssid", "secured", "password"] =
               Enum.map(Setup.fields(:wifi, other), &elem(&1, 1).key)

      open = Map.put(other, Setup.wifi_id("secured"), false)
      assert ["ssid", "secured"] = Enum.map(Setup.fields(:wifi, open), &elem(&1, 1).key)
    end

    test "what to join, or what's missing" do
      draft = Setup.wifi_draft(%{ssid: "Home", security: :wpa2})

      assert Setup.wifi_join(draft) == {:error, %{{"wifi", "password"} => "is required"}}

      typed = Map.put(draft, Setup.wifi_id("password"), %Secret{value: "goodpassword"})
      assert Setup.wifi_join(typed) == {:ok, {"Home", "goodpassword", false}}

      assert Setup.wifi_join(Setup.wifi_draft(%{ssid: "Cafe", security: :open})) ==
               {:ok, {"Cafe", nil, false}}

      hidden =
        Setup.wifi_draft(nil)
        |> Map.put(Setup.wifi_id("ssid"), "  Secret ")
        |> Map.put(Setup.wifi_id("secured"), false)

      # spaces are part of the name
      assert Setup.wifi_join(hidden) == {:ok, {"  Secret ", nil, true}}

      assert Setup.wifi_join(Setup.wifi_draft(%{ssid: " Home ", security: :open})) ==
               {:ok, {" Home ", nil, false}}

      for ssid <- [nil, "   "] do
        blank = Map.put(Setup.wifi_draft(nil), Setup.wifi_id("ssid"), ssid)
        assert {:error, %{{"wifi", "ssid"} => "is required"}} = Setup.wifi_join(blank)
      end
    end
  end
end
