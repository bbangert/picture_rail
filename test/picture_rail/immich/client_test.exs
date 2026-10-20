defmodule PictureRail.Immich.ClientTest do
  use ExUnit.Case, async: true

  alias PictureRail.Immich.{Album, Asset, Client}
  alias PictureRail.Settings

  @moduletag :tmp_dir
  @fixtures Path.expand("../../fixtures/immich", __DIR__)

  defp fixture(name), do: @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()

  setup do
    name = :"immich_#{System.unique_integer([:positive])}"
    settings = %Settings.Immich{url: "https://photos.example.com", api_key: "secret-key"}
    %{stub: name, client: Client.new(settings, plug: {Req.Test, name})}
  end

  defp stub(name, fun), do: Req.Test.stub(name, fun)

  defp json_body(conn) do
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    Jason.decode!(body)
  end

  defp item(id, extra \\ %{}),
    do:
      Map.merge(
        %{"id" => id, "checksum" => "c-#{id}", "type" => "IMAGE", "width" => 4, "height" => 3},
        extra
      )

  test "the API key is sent and kept out of inspect", %{stub: stub, client: client} do
    stub(stub, fn conn ->
      assert Plug.Conn.get_req_header(conn, "x-api-key") == ["secret-key"]
      assert conn.request_path == "/api/server/ping"
      Req.Test.json(conn, %{"res" => "pong"})
    end)

    assert Client.ping(client) == :ok
    refute inspect(client) =~ "secret"
  end

  test "version and albums from recorded responses", %{stub: stub, client: client} do
    stub(stub, fn
      %{request_path: "/api/server/version"} = conn ->
        Req.Test.json(conn, fixture("version.json"))

      %{request_path: "/api/albums"} = conn ->
        Req.Test.json(conn, fixture("albums.json"))
    end)

    assert Client.version(client) == {:ok, {3, 3, 1}}

    assert {:ok, [%Album{name: "Frame", asset_count: 63} = album, %Album{name: "Other"}]} =
             Client.list_albums(client)

    assert Album.version(album) == {63, "2026-10-14T19:27:32.982Z", "2026-10-14T06:45:19.955Z"}
  end

  test "a recorded search page decodes to assets", %{stub: stub, client: client} do
    stub(stub, fn conn -> Req.Test.json(conn, fixture("search_page.json")) end)

    assert {:ok,
            [%Asset{id: "e5f6a7b8-" <> _, width: 2371, height: 1581, mime: "image/jpeg"} | _] =
              assets} =
             Client.list_album_images(client, ["album"], {3, 3, 1})

    assert length(assets) == 3
  end

  test "cursor paging (Immich 3.2+), keeping only photos once each", %{stub: stub, client: client} do
    test = self()

    stub(stub, fn conn ->
      body = json_body(conn)
      send(test, {:body, body})

      case body["cursor"] do
        nil ->
          Req.Test.json(conn, %{
            "assets" => %{
              "items" => [item("1"), item("2", %{"isTrashed" => true})],
              "nextCursor" => "next"
            }
          })

        "next" ->
          Req.Test.json(conn, %{
            "assets" => %{
              "items" => [item("3"), item("1"), item("4", %{"type" => "VIDEO"})],
              "nextCursor" => nil
            }
          })
      end
    end)

    assert {:ok, assets} = Client.list_album_images(client, ["a", "b"], {3, 3, 1})
    assert Enum.map(assets, & &1.id) == ["1", "3"]

    assert_receive {:body,
                    %{
                      "filter" => %{
                        "albumIds" => %{"any" => ["a", "b"]},
                        "type" => %{"eq" => "IMAGE"}
                      },
                      "size" => 1000
                    } = first}

    refute Map.has_key?(first, "cursor")
    assert_receive {:body, %{"cursor" => "next"}}
  end

  test "numbered pages before Immich 3.2", %{stub: stub, client: client} do
    stub(stub, fn conn ->
      case json_body(conn) do
        %{"albumIds" => ["a"], "type" => "IMAGE", "page" => 1} ->
          Req.Test.json(conn, %{"assets" => %{"items" => [item("1")], "nextPage" => "2"}})

        %{"page" => 2} ->
          Req.Test.json(conn, %{"assets" => %{"items" => [item("2")], "nextPage" => nil}})
      end
    end)

    assert {:ok, [%Asset{id: "1"}, %Asset{id: "2"}]} =
             Client.list_album_images(client, ["a"], {3, 1, 0})
  end

  test "a JPEG preview is saved", %{stub: stub, client: client, tmp_dir: dir} do
    stub(stub, fn conn ->
      assert conn.request_path == "/api/assets/abc/thumbnail"
      assert conn.query_string == "size=preview"

      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, <<0xFF, 0xD8, 0xFF, "jpeg">>)
    end)

    path = Path.join(dir, "abc.jpg")
    assert Client.download_preview(client, "abc", path) == :ok
    assert File.read!(path) == <<0xFF, 0xD8, 0xFF, "jpeg">>
  end

  test "a WebP preview is refused and not kept", %{stub: stub, client: client, tmp_dir: dir} do
    stub(stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("image/webp")
      |> Plug.Conn.send_resp(200, "RIFFwebp")
    end)

    path = Path.join(dir, "abc.jpg")

    assert {:error, {:unsupported_format, "image/webp"}} =
             Client.download_preview(client, "abc", path)

    refute File.exists?(path)
  end

  test "errors are mapped to what the frame acts on", %{stub: stub, client: client, tmp_dir: dir} do
    respond = fn status, body ->
      stub(stub, fn conn -> conn |> Plug.Conn.put_status(status) |> Req.Test.json(body) end)
    end

    respond.(401, %{"message" => "Invalid API key"})
    assert Client.list_albums(client) == {:error, :invalid_key}

    respond.(403, %{"message" => "Missing required permission: album.read"})

    assert Client.list_albums(client) ==
             {:error, {:missing_permission, "Missing required permission: album.read"}}

    respond.(502, %{})
    assert Client.list_albums(client) == {:error, :offline}

    respond.(404, %{"message" => "Asset media not found"})
    path = Path.join(dir, "gone.jpg")
    assert Client.download_preview(client, "gone", path) == {:error, {:http_error, 404}}
    refute File.exists?(path)

    stub(stub, &Req.Test.transport_error(&1, :econnrefused))
    assert Client.ping(client) == {:error, :offline}
  end

  # Without a plug: the real Finch path (Req.Test stubs skip it), so Req
  # option errors show up here.
  test "an unreachable server through the real HTTP stack is :offline" do
    {:ok, listen} = :gen_tcp.listen(0, ip: :loopback)
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)

    client = Client.new(%Settings.Immich{url: "http://127.0.0.1:#{port}", api_key: "k"})
    assert Client.ping(client) == {:error, :offline}

    assert Client.download_preview(
             client,
             "x",
             Path.join(System.tmp_dir!(), "hf-unreachable.jpg")
           ) == {:error, :offline}
  end
end
