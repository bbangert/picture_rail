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

  test "an image is its URL and when it changed; anything else its URL" do
    image = %EntityState{entity_id: "image.porch", state: "2026-10-21T19:08:34", attributes: %{}}
    assert Picture.version(image, "u") == "u#2026-10-21T19:08:34"

    refute Picture.version(%{image | state: "2026-10-21T19:09:00"}, "u") ==
             Picture.version(image, "u")

    assert Picture.version(es("x"), "u") == "u"
  end

  test "no picture: nil" do
    assert Picture.url(es(nil), @base) == nil
    assert Picture.url(es(""), @base) == nil
    assert Picture.url(nil, @base) == nil
  end

  describe "downloads" do
    @ha %PictureRail.Settings.HomeAssistant{url: "http://ha.local:8123", token: "secret-token"}

    setup do
      %{stub: :"picture_#{System.unique_integer([:positive])}"}
    end

    # the files a download for `name` left in the directory
    defp files(name),
      do: Picture.dir() |> File.ls!() |> Enum.filter(&String.starts_with?(&1, name <> "-"))

    defp download(stub, url, name),
      do: Picture.download(url, @ha, name, plug: {Req.Test, stub})

    test "HA's own server gets the token; the picture lands in a new file", %{stub: stub} do
      Req.Test.stub(stub, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer secret-token"]
        assert conn.request_path == "/api/camera_proxy/camera.door"

        conn
        |> Plug.Conn.put_resp_content_type("image/png")
        |> Plug.Conn.send_resp(200, "PNGDATA")
      end)

      assert {:ok, path} =
               download(
                 stub,
                 "http://ha.local:8123/api/camera_proxy/camera.door?token=t",
                 "test.own"
               )

      assert Path.extname(path) == ".png"
      assert File.read!(path) == "PNGDATA"
      assert files("test.own") == [Path.basename(path)]
      Picture.discard(path)
    end

    test "another server never gets it", %{stub: stub} do
      Req.Test.stub(stub, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == []
        Plug.Conn.send_resp(conn, 200, "JPEG")
      end)

      assert {:ok, path} = download(stub, "http://192.168.2.186:11000/art.jpg", "test.other")
      assert Path.extname(path) == ".jpg"
      Picture.discard(path)
    end

    test "a request with the token doesn't follow a redirect", %{stub: stub} do
      Req.Test.stub(stub, fn conn ->
        assert conn.host == "ha.local"

        conn
        |> Plug.Conn.put_resp_header("location", "http://elsewhere.example/steal")
        |> Plug.Conn.send_resp(302, "")
      end)

      assert {:error, {:status, 302}} =
               download(stub, "http://ha.local:8123/api/image_proxy/image.porch", "test.redirect")

      assert files("test.redirect") == []
    end

    test "a failed download leaves no file", %{stub: stub} do
      Req.Test.stub(stub, &Plug.Conn.send_resp(&1, 500, "oops"))
      assert {:error, {:status, 500}} = download(stub, "http://ha.local:8123/x", "test.status")
      assert files("test.status") == []

      Req.Test.stub(stub, &Req.Test.transport_error(&1, :econnrefused))

      assert {:error, %Req.TransportError{}} =
               download(stub, "http://ha.local:8123/x", "test.transport")

      assert files("test.transport") == []
    end
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
