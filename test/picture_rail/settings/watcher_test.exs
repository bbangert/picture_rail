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

  test "first boot writes a private template and treats it as not configured", %{tmp_dir: dir} do
    path = Path.join(dir, "picture_rail.json")
    watcher = start(path)

    assert_receive {:notified, settings, :template}
    assert settings.immich == nil
    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
    assert {_settings, :template} = Watcher.state(watcher)
  end

  test "an edited file is picked up and a world-readable one is made private", %{tmp_dir: dir} do
    path = Path.join(dir, "picture_rail.json")
    write(path, %{})
    File.chmod!(path, 0o644)
    watcher = start(path)
    assert_receive {:notified, _, :ok}
    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600

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
end
