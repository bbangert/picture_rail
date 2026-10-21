defmodule PictureRail.Web.RouterTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias PictureRail.Settings.Watcher
  alias PictureRail.Web.{Pairing, Router}

  @moduletag :tmp_dir

  @immich %{
    "type" => "immich",
    "url" => "https://photos.example.com",
    "api_key" => "secret-key",
    "album_ids" => ["a1"]
  }

  setup %{tmp_dir: dir} do
    id = System.unique_integer([:positive])
    pairing = :"pairing_#{id}"
    watcher = :"watcher_#{id}"
    path = Path.join(dir, "picture_rail.json")

    start_supervised!(
      {Pairing,
       name: pairing, secret_file: Path.join(dir, "web_secret"), notify: fn _ -> :ok end},
      id: pairing
    )

    start_supervised!({Watcher, path: path, name: watcher, notify: fn _, _ -> :ok end},
      id: watcher
    )

    %{pairing: pairing, watcher: watcher, path: path}
  end

  # A request, carrying the cookies `from` a previous one.
  defp request(ctx, method, path, params \\ nil, from \\ nil) do
    conn = conn(method, path, params)
    conn = if from, do: recycle_cookies(conn, from), else: conn
    Router.call(conn, Router.init(pairing: ctx.pairing, watcher: ctx.watcher))
  end

  defp csrf(conn) do
    [_, token] = Regex.run(~r/name="_csrf_token" value="([^"]+)"/, conn.resp_body)
    token
  end

  defp paired(ctx) do
    page = request(ctx, :get, "/")
    code = Pairing.code(ctx.pairing)
    conn = request(ctx, :post, "/pair", %{"_csrf_token" => csrf(page), "code" => code}, page)
    assert redirected_to(conn) == "/"
    conn
  end

  defp redirected_to(conn) do
    assert conn.status == 303
    conn |> Plug.Conn.get_resp_header("location") |> hd()
  end

  defp save(ctx, from, slug, params) do
    page = request(ctx, :get, "/settings/#{slug}", nil, from)
    params = Map.merge(%{"_csrf_token" => csrf(page), "action" => "save"}, params)
    request(ctx, :post, "/settings/#{slug}", params, page)
  end

  defp saved(ctx), do: ctx.path |> File.read!() |> Jason.decode!()

  defp albums_server(albums) do
    Req.Test.stub(PictureRail.Immich.Source, fn conn ->
      case conn.request_path do
        "/api/server/ping" -> Req.Test.json(conn, %{"res" => "pong"})
        "/api/server/version" -> Req.Test.json(conn, %{"major" => 2, "minor" => 1, "patch" => 0})
        "/api/albums" -> Req.Test.json(conn, albums)
      end
    end)
  end

  test "unpaired: the pairing form, and the settings send you to it", ctx do
    conn = request(ctx, :get, "/")
    assert conn.status == 200
    assert conn.resp_body =~ "Pair this device"
    assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store"]

    assert redirected_to(request(ctx, :get, "/settings/home_assistant")) == "/"
  end

  test "a wrong code is refused", ctx do
    page = request(ctx, :get, "/")
    code = Pairing.code(ctx.pairing)
    wrong = if code == "00000000", do: "00000001", else: "00000000"
    conn = request(ctx, :post, "/pair", %{"_csrf_token" => csrf(page), "code" => wrong}, page)
    assert conn.resp_body =~ "That code isn't right"
    assert redirected_to(request(ctx, :get, "/settings/display", nil, conn)) == "/"
  end

  test "the QR link fills the code in; Pair pairs, once", ctx do
    code = Pairing.code(ctx.pairing)
    form = request(ctx, :get, "/pair?code=#{code}")
    assert form.status == 200
    assert form.resp_body =~ ~s{value="#{code}"}
    # opening the link (a link preview, say) doesn't use the code up
    assert Pairing.code(ctx.pairing) == code
    assert redirected_to(request(ctx, :get, "/settings/display", nil, form)) == "/"

    params = %{"_csrf_token" => csrf(form), "code" => code}
    conn = request(ctx, :post, "/pair", params, form)
    assert redirected_to(conn) == "/"

    index = request(ctx, :get, "/", nil, conn)
    assert index.resp_body =~ "/settings/photo_source"
    assert index.resp_body =~ "Wi-Fi is set on the frame"

    # (one time in 10^8 the new code is the same)
    if Pairing.code(ctx.pairing) != code do
      again = request(ctx, :post, "/pair", params, form)
      assert again.resp_body =~ "That code isn't right"
    end
  end

  test "pairing needs the CSRF token: another site can't post guesses", ctx do
    code = Pairing.code(ctx.pairing)
    conn = request(ctx, :post, "/pair", %{"code" => code})
    assert conn.status == 403
    # not even counted as a try
    assert Pairing.code(ctx.pairing) == code
    assert :sys.get_state(ctx.pairing).failures == 0
  end

  test "only the frame's own name or an address", ctx do
    {:ok, hostname} = :inet.gethostname()

    for host <- ["#{hostname}.local", "#{hostname}.local:4080", "192.168.1.40", "[::1]:4080"] do
      assert Router.allowed_host?(host), host
    end

    for host <- ["rebind.example.com", "rebind.example.com:80", "#{hostname}.local.evil", ""] do
      refute Router.allowed_host?(host), host
    end

    # as Bandit passes it on (Plug.Test only sets conn.host, which isn't read)
    conn = conn(:get, "/")

    conn =
      %{conn | req_headers: [{"host", "rebind.example.com"} | conn.req_headers]}
      |> Router.call(Router.init(pairing: ctx.pairing, watcher: ctx.watcher))

    assert conn.status == 421
    refute conn.resp_body =~ "_csrf_token"
  end

  test "forgetting paired devices ends the session", ctx do
    conn = paired(ctx)
    assert request(ctx, :get, "/settings/display", nil, conn).status == 200
    Pairing.forget(ctx.pairing)
    assert redirected_to(request(ctx, :get, "/settings/display", nil, conn)) == "/"
  end

  test "log out ends the session", ctx do
    conn = paired(ctx)
    index = request(ctx, :get, "/", nil, conn)
    out = request(ctx, :post, "/logout", %{"_csrf_token" => csrf(index)}, index)
    assert redirected_to(out) == "/"
    assert redirected_to(request(ctx, :get, "/settings/display", nil, out)) == "/"
  end

  test "a post without the CSRF token saves nothing", ctx do
    conn = paired(ctx)

    params = %{
      "action" => "save",
      "f" => %{"slideshow" => %{"interval_ms" => "12"}},
      "shown" => ["slideshow/interval_ms"]
    }

    assert request(ctx, :post, "/settings/display", params, conn).status == 403
    refute File.exists?(ctx.path)
    # still paired: the session wasn't touched
    assert request(ctx, :get, "/settings/display", nil, conn).status == 200
  end

  test "saving Home Assistant: the token is stored and never sent back", ctx do
    conn = paired(ctx)
    token = "eyJhbGciOiJIUzI1NiJ9.long-lived-token"

    params = %{
      "f" => %{"home_assistant" => %{"url" => "http://ha.local:8123/", "token" => token}},
      "shown" => ["home_assistant/url", "home_assistant/token", "home_assistant/ssl_verify"]
    }

    result = save(ctx, conn, "home_assistant", params)
    assert redirected_to(result) == "/settings/home_assistant?saved=1"

    assert saved(ctx)["home_assistant"] == %{
             "url" => "http://ha.local:8123/",
             "token" => token,
             "ssl_verify" => false
           }

    page = request(ctx, :get, "/settings/home_assistant?saved=1", nil, result)
    assert page.resp_body =~ "Saved"
    # back to the sections, without saving
    assert page.resp_body =~ ~s{<a class="pill back" href="/">Back</a>}
    assert page.resp_body =~ "Set. Leave empty to keep it"
    refute page.resp_body =~ token

    # an error: the page comes back with it, still without the token
    params = %{
      "f" => %{"home_assistant" => %{"url" => "ftp://ha.local", "token" => "another-#{token}"}},
      "shown" => ["home_assistant/url", "home_assistant/token"]
    }

    bad = save(ctx, page, "home_assistant", params)
    assert bad.status == 422
    assert bad.resp_body =~ "must start with http:// or https://"
    assert bad.resp_body =~ "Paste the key again"
    refute bad.resp_body =~ token
    assert saved(ctx)["home_assistant"]["token"] == token
  end

  test "display settings in seconds", ctx do
    conn = paired(ctx)

    params = %{
      "f" => %{"slideshow" => %{"interval_ms" => "12", "fade_ms" => "0.75"}},
      "shown" => ["slideshow/interval_ms", "slideshow/fade_ms"]
    }

    assert redirected_to(save(ctx, conn, "display", params)) =~ "saved=1"
    assert saved(ctx)["slideshow"] == %{"interval_ms" => 12_000, "fade_ms" => 750}
  end

  test "albums from the saved source, escaped; unloaded albums are kept", ctx do
    :ok = Watcher.update(%{"photo_source" => @immich}, ctx.watcher)
    conn = paired(ctx)

    albums_server([
      %{"id" => "a1", "albumName" => "Frame", "assetCount" => 2},
      %{"id" => "a2", "albumName" => "<script>x</script>", "assetCount" => 1}
    ])

    page = request(ctx, :get, "/settings/photo_source", nil, conn)
    assert page.resp_body =~ ~s{value="a1" checked}
    assert page.resp_body =~ "&lt;script&gt;x&lt;/script&gt; (1 photo)"
    refute page.resp_body =~ "<script>"
    refute page.resp_body =~ "secret-key"

    params = %{
      "_csrf_token" => csrf(page),
      "action" => "save",
      "type" => "immich",
      "f" => %{"photo_source" => %{"url" => @immich["url"], "album_ids" => ["a2"]}},
      "shown" => ["photo_source/url", "photo_source/api_key", "photo_source/album_ids"]
    }

    result = request(ctx, :post, "/settings/photo_source", params, page)
    assert redirected_to(result) =~ "saved=1"
    assert saved(ctx)["photo_source"]["album_ids"] == ["a2"]
    assert saved(ctx)["photo_source"]["api_key"] == "secret-key"

    # the albums couldn't be shown: a save leaves them alone
    Req.Test.stub(PictureRail.Immich.Source, &Req.Test.transport_error(&1, :econnrefused))
    page = request(ctx, :get, "/settings/photo_source", nil, result)
    assert page.resp_body =~ "Can&#39;t reach the server"
    refute page.resp_body =~ "photo_source/album_ids"

    params = %{params | "_csrf_token" => csrf(page), "shown" => ["photo_source/url"]}
    assert redirected_to(request(ctx, :post, "/settings/photo_source", params, page)) =~ "saved"
    assert saved(ctx)["photo_source"]["album_ids"] == ["a2"]
  end

  test "Test checks the source with the form's values", ctx do
    conn = paired(ctx)
    albums_server([])
    page = request(ctx, :get, "/settings/photo_source", nil, conn)
    assert page.resp_body =~ "Save the connection first"

    params = %{
      "_csrf_token" => csrf(page),
      "action" => "test",
      "type" => "immich",
      "f" => %{"photo_source" => %{"url" => @immich["url"], "api_key" => "secret-key"}},
      "shown" => ["photo_source/url", "photo_source/api_key"]
    }

    result = request(ctx, :post, "/settings/photo_source", params, page)
    assert result.status == 200
    assert result.resp_body =~ "Connection works"
    refute result.resp_body =~ "secret-key"
    refute File.exists?(ctx.path)
  end

  test "Test against another server needs the key again; it isn't sent there", ctx do
    :ok = Watcher.update(%{"photo_source" => @immich}, ctx.watcher)
    conn = paired(ctx)
    test = self()

    Req.Test.stub(PictureRail.Immich.Source, fn conn ->
      send(test, {:request, conn.host, Plug.Conn.get_req_header(conn, "x-api-key")})
      Req.Test.json(conn, [])
    end)

    page = request(ctx, :get, "/settings/photo_source", nil, conn)
    assert_receive {:request, "photos.example.com", ["secret-key"]}

    params = %{
      "_csrf_token" => csrf(page),
      "type" => "immich",
      "f" => %{"photo_source" => %{"url" => "http://attacker.example", "api_key" => ""}},
      "shown" => ["photo_source/url", "photo_source/api_key"]
    }

    tested =
      request(ctx, :post, "/settings/photo_source", Map.put(params, "action", "test"), page)

    assert tested.resp_body =~ "API key must be entered again for a new server"
    refute_received {:request, "attacker.example", _}

    saved = request(ctx, :post, "/settings/photo_source", Map.put(params, "action", "save"), page)
    assert saved.status == 422
    assert saved.resp_body =~ "must be entered again for a new server"
    assert saved(ctx)["photo_source"]["url"] == @immich["url"]
    refute_received {:request, "attacker.example", _}
  end

  test "unknown pages", ctx do
    conn = paired(ctx)
    assert request(ctx, :get, "/settings/wifi", nil, conn).status == 404
    assert request(ctx, :get, "/nope").status == 404
  end
end
