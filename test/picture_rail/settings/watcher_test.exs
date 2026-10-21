defmodule PictureRail.Settings.WatcherTest do
  use ExUnit.Case, async: true

  alias PictureRail.Settings.Watcher

  @moduletag :tmp_dir

  defp start(path, opts \\ []) do
    test = self()
    notify = fn settings, status -> send(test, {:notified, settings, status}) end
    name = :"watcher_#{System.unique_integer([:positive])}"
    opts = Keyword.merge([path: path, name: name, notify: notify, poll_ms: 20], opts)
    start_supervised!({Watcher, opts})
    name
  end

  defp write(path, map), do: File.write!(path, Jason.encode!(map))

  defp mode(path), do: File.stat!(path).mode |> Bitwise.band(0o777)

  @template """
  {
    "immich": {
      "url": "https://photos.example.com",
      "api_key": "",
      "album_ids": []
    },
    "home_assistant": {
      "url": "http://homeassistant.local:8123",
      "token": ""
    }
  }
  """

  test "no file means nothing set up, and none is written", %{tmp_dir: dir} do
    path = Path.join(dir, "picture_rail.json")
    watcher = start(path)

    assert_receive {:notified, settings, :missing}
    assert settings.photo_source == nil
    refute File.exists?(path)
    assert {_settings, :missing} = Watcher.state(watcher)
  end

  test "the template earlier versions wrote still means not set up", %{tmp_dir: dir} do
    path = Path.join(dir, "picture_rail.json")
    File.write!(path, @template)
    start(path)
    assert_receive {:notified, settings, :template}
    assert settings.home_assistant == nil
  end

  test "an edited file is picked up and a world-readable one is made private", %{tmp_dir: dir} do
    path = Path.join(dir, "picture_rail.json")
    write(path, %{})
    File.chmod!(path, 0o644)
    watcher = start(path)
    assert_receive {:notified, _, :ok}
    assert mode(path) == 0o600

    write(path, %{"slideshow" => %{"interval_ms" => 12_345}})
    assert_receive {:notified, settings, :ok}, 2_000
    assert settings.slideshow.interval_ms == 12_345
    assert Watcher.current(watcher).slideshow.interval_ms == 12_345
  end

  test "an invalid edit keeps the previous settings", %{tmp_dir: dir} do
    path = Path.join(dir, "picture_rail.json")
    write(path, %{"cache" => %{"window" => 10}})
    watcher = start(path, poll_ms: 60_000)
    assert_receive {:notified, _, :ok}

    write(path, %{"cache" => %{"window" => "lots"}})
    assert {:error, ["cache.window must be a positive integer"]} = Watcher.reload(watcher)
    assert_receive {:notified, settings, {:error, _}}
    assert settings.cache.window == 10
    assert Watcher.current(watcher).cache.window == 10
  end

  describe "update/2" do
    @immich %{
      "type" => "immich",
      "url" => "http://immich",
      "api_key" => "secret-key",
      "album_ids" => ["a1"]
    }

    test "creates the file, private, pretty-printed, and loads it", %{tmp_dir: dir} do
      path = Path.join([dir, "data", "picture_rail.json"])
      watcher = start(path)
      assert_receive {:notified, _, :missing}

      assert :ok = Watcher.update(%{"photo_source" => @immich}, watcher)
      assert_receive {:notified, settings, :ok}
      assert settings.photo_source.config["api_key"] == "secret-key"
      assert Watcher.current(watcher).photo_source.config["album_ids"] == ["a1"]
      assert mode(path) == 0o600
      assert File.read!(path) =~ ~s(\n  "photo_source": {\n)
      refute File.exists?(path <> ".tmp")
    end

    test "merges: other sections, unknown keys and omitted secrets stay", %{tmp_dir: dir} do
      path = Path.join(dir, "picture_rail.json")

      write(path, %{
        "photo_source" => Map.put(@immich, "extra", 1),
        "home_assistant" => %{"url" => "http://ha", "token" => "secret-token"},
        "future" => %{"x" => true}
      })

      watcher = start(path)
      assert_receive {:notified, _, :ok}

      assert :ok =
               Watcher.update(
                 %{
                   "photo_source" => %{"api_key" => "", "album_ids" => ["a2"]},
                   "home_assistant" => %{"url" => "http://ha/", "token" => nil},
                   "slideshow" => %{"interval_ms" => 9_000}
                 },
                 watcher
               )

      json = path |> File.read!() |> Jason.decode!()

      assert json["photo_source"] == %{
               "type" => "immich",
               "url" => "http://immich",
               "api_key" => "secret-key",
               "album_ids" => ["a2"],
               "extra" => 1
             }

      assert json["home_assistant"] == %{"url" => "http://ha/", "token" => "secret-token"}
      assert json["slideshow"] == %{"interval_ms" => 9_000}
      assert json["future"] == %{"x" => true}
      assert Watcher.current(watcher).slideshow.interval_ms == 9_000
    end

    test "a kept secret goes only to the server it was given for", %{tmp_dir: dir} do
      path = Path.join(dir, "picture_rail.json")

      saved = %{
        "photo_source" => @immich,
        "home_assistant" => %{"url" => "https://ha:8123", "token" => "secret-token"}
      }

      write(path, saved)
      watcher = start(path)
      assert_receive {:notified, _, :ok}

      # another host, port or scheme, or the certificate check turned off
      for {name, values, key} <- [
            {"photo_source", %{"url" => "http://attacker", "api_key" => ""}, "api_key"},
            {"home_assistant", %{"url" => "https://ha:8124"}, "token"},
            {"home_assistant", %{"url" => "http://ha:8123", "token" => nil}, "token"},
            {"home_assistant", %{"ssl_verify" => false}, "token"}
          ] do
        assert {:error, [message]} = Watcher.update(%{name => values}, watcher)
        assert message == "#{name}.#{key} must be entered again for a new server"
      end

      assert path |> File.read!() |> Jason.decode!() == saved

      # the same server (path and case aside), or the secret given again
      assert :ok = Watcher.update(%{"home_assistant" => %{"url" => "https://HA:8123/x"}}, watcher)

      assert :ok =
               Watcher.update(
                 %{"photo_source" => %{"url" => "http://new", "api_key" => "new-key"}},
                 watcher
               )

      json = path |> File.read!() |> Jason.decode!()
      assert json["home_assistant"]["token"] == "secret-token"
      assert json["photo_source"]["api_key"] == "new-key"
    end

    test "a nil section is removed, a nil key goes back to its default", %{tmp_dir: dir} do
      path = Path.join(dir, "picture_rail.json")

      write(path, %{
        "home_assistant" => %{"url" => "http://ha", "token" => "t"},
        "slideshow" => %{"interval_ms" => 9_000, "fade_ms" => 500}
      })

      watcher = start(path)

      assert :ok =
               Watcher.update(
                 %{"home_assistant" => nil, "slideshow" => %{"fade_ms" => nil}},
                 watcher
               )

      assert Watcher.current(watcher).home_assistant == nil
      assert Watcher.current(watcher).slideshow == %{interval_ms: 9_000, fade_ms: 1_500}
    end

    test "invalid results are refused and the file is left as it was", %{tmp_dir: dir} do
      path = Path.join(dir, "picture_rail.json")
      write(path, %{"cache" => %{"window" => 10}})
      before = File.read!(path)
      watcher = start(path)
      assert_receive {:notified, _, :ok}

      assert {:error, ["slideshow.fade_ms must be shorter than slideshow.interval_ms"]} =
               Watcher.update(
                 %{"slideshow" => %{"interval_ms" => 1_000, "fade_ms" => 1_000}},
                 watcher
               )

      assert {:error, ["photo_source.api_key is required"]} =
               Watcher.update(
                 %{"photo_source" => %{"type" => "immich", "url" => "http://i"}},
                 watcher
               )

      assert File.read!(path) == before
      refute_receive {:notified, _, _}
    end

    test "a file that isn't JSON is never overwritten", %{tmp_dir: dir} do
      path = Path.join(dir, "picture_rail.json")
      File.write!(path, "{oops")
      watcher = start(path)

      assert {:error, ["not valid JSON: " <> _]} =
               Watcher.update(%{"cache" => %{"window" => 5}}, watcher)

      assert File.read!(path) == "{oops"
    end

    test "a legacy immich section becomes photo_source", %{tmp_dir: dir} do
      path = Path.join(dir, "picture_rail.json")
      write(path, %{"immich" => Map.delete(@immich, "type")})
      watcher = start(path)

      assert :ok = Watcher.update(%{"cache" => %{"window" => 5}}, watcher)
      json = path |> File.read!() |> Jason.decode!()
      refute Map.has_key?(json, "immich")
      assert json["photo_source"] == @immich
      assert Watcher.current(watcher).photo_source.config["api_key"] == "secret-key"
    end

    test "the template is replaced, not merged", %{tmp_dir: dir} do
      path = Path.join(dir, "picture_rail.json")
      File.write!(path, @template)
      watcher = start(path)

      assert :ok = Watcher.update(%{"cache" => %{"window" => 5}}, watcher)
      assert path |> File.read!() |> Jason.decode!() == %{"cache" => %{"window" => 5}}
    end

    test "another kind of source replaces the old one's settings", %{tmp_dir: dir} do
      path = Path.join(dir, "picture_rail.json")
      write(path, %{"photo_source" => Map.put(@immich, "type", "retired")})
      watcher = start(path)
      assert_receive {:notified, _, {:error, _}}

      assert {:error, ["photo_source.url is required", "photo_source.api_key is required"]} =
               Watcher.update(%{"photo_source" => %{"type" => "immich"}}, watcher)
    end

    test "a leftover temporary file doesn't get in the way", %{tmp_dir: dir} do
      path = Path.join(dir, "picture_rail.json")
      File.write!(path <> ".tmp", "junk")
      File.chmod!(path <> ".tmp", 0o644)
      watcher = start(path)

      assert :ok = Watcher.update(%{"cache" => %{"window" => 5}}, watcher)
      assert mode(path) == 0o600
      refute File.exists?(path <> ".tmp")
    end
  end
end
