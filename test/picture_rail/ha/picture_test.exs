defmodule PictureRail.HA.PictureTest do
  use ExUnit.Case, async: true

  alias Hassock.EntityState
  alias PictureRail.HA.Picture

  @base "http://ha.local:8123"

  defp es(picture),
    do: %EntityState{
      entity_id: "camera.door",
      state: "idle",
      attributes: %{"entity_picture" => picture}
    }

  test "HA's paths are on its own server; other servers' URLs stay as they are" do
    url = Picture.url(es("/api/camera_proxy/camera.door?token=abc"), @base)
    assert url == "http://ha.local:8123/api/camera_proxy/camera.door?token=abc"
    assert Picture.own_server?(url, @base)

    art = Picture.url(es("http://192.168.2.186:11000/images/art.png"), @base)
    assert art == "http://192.168.2.186:11000/images/art.png"
    refute Picture.own_server?(art, @base)

    # same host, another port or scheme: not HA's
    refute Picture.own_server?("http://ha.local:8080/x", @base)
    refute Picture.own_server?("https://ha.local:8123/x", @base)
  end

  test "no picture: nil" do
    assert Picture.url(es(nil), @base) == nil
    assert Picture.url(es(""), @base) == nil
    assert Picture.url(nil, @base) == nil
  end

  test "only files in its own directory are removed" do
    outside = Path.join(System.tmp_dir!(), "picture-test-#{System.unique_integer([:positive])}")
    File.write!(outside, "x")
    assert Picture.discard(outside) == :ok
    assert File.exists?(outside)
    File.rm!(outside)

    File.mkdir_p!(Picture.dir())
    inside = Path.join(Picture.dir(), "camera.door-test.jpg")
    File.write!(inside, "x")
    assert Picture.discard(inside) == :ok
    refute File.exists?(inside)
    assert Picture.discard(nil) == :ok
  end
end
