defmodule PictureRail.Immich.SourceTest do
  use ExUnit.Case, async: true

  alias PictureRail.Immich.Source
  alias PictureRail.Setup.Field

  @fixtures Path.expand("../../fixtures/immich", __DIR__)
  @config %{"url" => "https://photos.example.com", "api_key" => "secret-key"}

  defp fixture(name), do: @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()

  # Answers like an Immich server; `fail` maps a path to a status.
  defp serve(fail \\ %{}) do
    Req.Test.stub(Source, fn conn ->
      assert Plug.Conn.get_req_header(conn, "x-api-key") == ["secret-key"]

      case {Map.get(fail, conn.request_path), conn.request_path} do
        {nil, "/api/server/ping"} ->
          Req.Test.json(conn, %{"res" => "pong"})

        {nil, "/api/server/version"} ->
          Req.Test.json(conn, fixture("version.json"))

        {nil, "/api/albums"} ->
          Req.Test.json(conn, fixture("albums.json"))

        {:transport, _} ->
          Req.Test.transport_error(conn, :econnrefused)

        {status, _} ->
          conn
          |> Plug.Conn.put_status(status)
          |> Req.Test.json(%{"message" => "Missing required permission: album.read"})
      end
    end)
  end

  test "its fields validate a section: url trimmed, albums default to none" do
    assert Field.validate(Source.fields(), "photo_source", %{
             "url" => "https://photos.example.com/",
             "api_key" => "k"
           }) ==
             {:ok,
              %{
                "url" => "https://photos.example.com",
                "api_key" => "k",
                "album_ids" => [],
                "album_names" => []
              }}

    assert Field.secret_keys(Source.fields()) == ["api_key"]
    assert [%Field{key: "album_names", ui?: false}] = Enum.reject(Source.fields(), & &1.ui?)
  end

  test "the album choices: sorted by name, with their photo counts" do
    serve()

    assert Source.choices("album_ids", @config) ==
             {:ok,
              [
                {"a1b2c3d4-0000-4000-8000-000000000001", "Frame (63 photos)"},
                {"a1b2c3d4-0000-4000-8000-000000000005", "Other (11 photos)"}
              ]}

    assert {:error, _} = Source.choices("url", @config)
  end

  test "album choices and the check say what went wrong" do
    serve(%{"/api/albums" => 401})
    assert Source.choices("album_ids", @config) == {:error, "API key rejected"}
    assert Source.check(@config) == {:error, "API key rejected"}

    serve(%{"/api/albums" => 403})
    assert Source.check(@config) == {:error, "Missing required permission: album.read"}

    serve(%{"/api/server/ping" => :transport})
    assert Source.check(@config) == {:error, "Can't reach the server"}

    serve(%{"/api/server/version" => 404})
    assert Source.check(@config) == {:error, "The server answered 404"}
  end

  test "the check passes against a working server" do
    serve()
    assert Source.check(@config) == :ok
  end

  test "its own statuses in words" do
    assert Source.status_message(:invalid_key) == "Immich API key rejected"
    assert Source.status_message({:missing_permission, "Missing x"}) == "Missing x"
    assert Source.status_message(:no_albums) == "No albums found"
    assert Source.status_message(:online) == nil
  end
end
