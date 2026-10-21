defmodule PictureRail.Web.Router do
  @moduledoc """
  The settings web page, served on the LAN (`PictureRail.Web`): for
  pasting the long things (an API key, a token) from a phone or laptop
  instead of typing them on the frame.

    * `GET /` - the sections, or the pairing form when not paired
    * `GET /pair?code=` (the frame's QR code links here): the pairing form
      with the code filled in; only `POST /pair` checks it, so a link
      preview can't use the code up
    * `GET /settings/:section`, `POST /settings/:section` (`action`
      `save`, or `test` for the photo source)
    * `POST /logout`

  Everything but pairing needs a session from `PictureRail.Web.Pairing`
  (a signed cookie, 12 hours). Posts need the CSRF token, pairing too, so
  another site can't post guesses from a browser on the LAN: a post
  without it gets a 403. Requests for any host but the frame's own name or
  an IP address are refused (421), so a site can't reach the page by
  pointing its own name at the frame (DNS rebinding).
  Saves go through `PictureRail.Settings.Watcher.update/2`, as the
  frame's do; secrets are never sent back. Wi-Fi isn't here: changing it
  from the network you're on would cut the page off.

  Redirects are paths only, and nothing uses `conn.host` (a client can
  choose it: EEF-CVE-2026-105660 in Bandit 1.12.5): the host check reads
  the raw `host` header.

  Options (for tests): `pairing:` and `watcher:` servers.
  """
  use Plug.Router, copy_opts_to_assign: :web

  alias PictureRail.{PhotoSource, Settings, Setup}
  alias PictureRail.Settings.Watcher
  alias PictureRail.Web.{Form, Page, Pairing}

  @session_s 12 * 3600
  @csrf Plug.CSRFProtection.init(with: :exception)

  plug(:check_host)
  plug(:put_secret_key_base)

  plug(Plug.Session,
    store: :cookie,
    key: "_picture_rail",
    signing_salt: "picture_rail web session",
    http_only: true,
    same_site: "Strict",
    max_age: @session_s
  )

  plug(:fetch_session)
  plug(Plug.Parsers, parsers: [:urlencoded], length: 100_000)
  plug(:check_csrf)
  plug(:put_headers)
  plug(:match)
  plug(:dispatch)

  get "/" do
    if paired?(conn),
      do: html(conn, 200, Page.index(csrf())),
      else: html(conn, 200, Page.pair(csrf(), nil))
  end

  get "/pair" do
    code = if is_binary(conn.params["code"]), do: conn.params["code"]
    html(conn, 200, Page.pair(csrf(), nil, code))
  end

  post "/pair" do
    case conn.params["code"] do
      code when is_binary(code) -> pair(conn, code)
      _ -> html(conn, 200, Page.pair(csrf(), :wrong))
    end
  end

  post "/logout" do
    conn |> configure_session(drop: true) |> redirect("/")
  end

  get "/settings/:slug" do
    with_section(conn, slug, fn section ->
      message = if conn.params["saved"] == "1", do: {:ok, "Saved"}
      settings = Watcher.current(server(conn, :watcher))
      draft = Setup.draft(section, Settings.public(settings))
      render_section(conn, 200, section, draft, settings, %{}, message)
    end)
  end

  post "/settings/:slug" do
    with_section(conn, slug, fn section ->
      watcher = server(conn, :watcher)
      settings = Watcher.current(watcher)
      draft = Form.draft(section, conn.body_params, Settings.public(settings))

      case conn.body_params["action"] do
        "test" when section == :photo_source -> test(conn, draft, settings)
        _save -> save(conn, section, draft, settings, watcher)
      end
    end)
  end

  match _ do
    html(conn, 404, Page.message("Not found", "There's no page here."))
  end

  # -- Pairing --

  defp pair(conn, code) do
    case Pairing.verify(code, server(conn, :pairing)) do
      :ok ->
        conn
        |> configure_session(renew: true)
        |> put_session("paired_at", System.os_time(:second))
        |> redirect("/")

      {:error, reason} ->
        html(conn, 200, Page.pair(csrf(), reason))
    end
  end

  defp paired?(conn) do
    case get_session(conn, "paired_at") do
      at when is_integer(at) -> (System.os_time(:second) - at) in 0..@session_s
      _ -> false
    end
  end

  # -- Sections --

  defp with_section(conn, slug, fun) do
    case {paired?(conn), Form.section(slug)} do
      {false, _} -> redirect(conn, "/")
      {true, {:ok, section}} -> fun.(section)
      {true, :error} -> html(conn, 404, Page.message("Not found", "There's no such section."))
    end
  end

  defp save(conn, section, draft, settings, watcher) do
    original = Setup.draft(section, Settings.public(settings))

    case Watcher.update(Setup.values(section, draft, original), watcher) do
      :ok ->
        redirect(conn, "/settings/#{Form.slug(section)}?saved=1")

      {:error, messages} ->
        {errors, rest} = Setup.field_errors(section, draft, messages)
        text = if rest == [], do: "Check the fields marked", else: Enum.join(rest, "; ")
        message = {:error, retype(text, draft)}
        render_section(conn, 422, section, draft, settings, errors, message)
    end
  end

  defp test(conn, draft, settings) do
    message =
      case Setup.source(draft) do
        nil ->
          {:error, "Unknown photo source"}

        module ->
          result =
            with {:ok, config} <-
                   Setup.source_config(draft, Settings.values(settings, "photo_source")),
                 do: module.check(config)

          case result do
            :ok -> {:ok, retype("Connection works", draft)}
            {:error, text} -> {:error, retype(text, draft)}
          end
      end

    render_section(conn, 200, :photo_source, draft, settings, %{}, message)
  end

  # A typed secret isn't sent back, so it has to be pasted again to save.
  defp retype(text, draft) do
    if Form.typed_secret?(draft),
      do: text <> ". Paste the key again before saving: it isn't kept until it's saved.",
      else: text
  end

  defp render_section(conn, status, section, draft, settings, errors, message) do
    public = Settings.public(settings)

    assigns = %{
      section: section,
      inputs: Form.inputs(section, draft, public, errors, choices(section, draft, settings)),
      types: for(m <- PhotoSource.sources(), do: {m.type(), m.label()}),
      type: draft[Setup.type_id()],
      message: message
    }

    html(conn, status, Page.section(csrf(), assigns))
  end

  # Choices (albums) come from the saved source: they need its saved
  # credentials, which a form only has when they're pasted again.
  defp choices(:photo_source, draft, settings) do
    saved = Settings.values(settings, "photo_source")
    module = Setup.source(draft)

    for {name, %Setup.Field{type: {:choices, _}} = f} <- Setup.fields(:photo_source, draft),
        into: %{} do
      result =
        if module && saved && saved["type"] == module.type(),
          do: module.choices(f.key, saved),
          else: {:error, "Save the connection first, then choose here."}

      {{name, f.key}, result}
    end
  end

  defp choices(_section, _draft, _settings), do: %{}

  # -- Plumbing --

  # The frame by name (`<hostname>.local`) or by address; no Host header
  # (HTTP/1.0) is let through, as a browser always sends one.
  defp check_host(conn, _opts) do
    case get_req_header(conn, "host") do
      [] ->
        conn

      [host | _] ->
        if allowed_host?(host),
          do: conn,
          else:
            conn
            |> html(421, Page.message("Wrong address", "Open the frame's own address."))
            |> halt()
    end
  end

  @doc false
  @spec allowed_host?(String.t()) :: boolean()
  def allowed_host?(host) do
    name =
      case host |> String.trim() |> String.downcase() do
        "[" <> rest -> rest |> String.split("]") |> hd()
        other -> other |> String.split(":") |> hd()
      end

    {:ok, hostname} = :inet.gethostname()
    hostname = String.downcase(to_string(hostname))

    name in [hostname, hostname <> ".local", "localhost"] or
      match?({:ok, _}, :inet.parse_strict_address(String.to_charlist(name)))
  end

  defp check_csrf(conn, _opts) do
    Plug.CSRFProtection.call(conn, @csrf)
  rescue
    Plug.CSRFProtection.InvalidCSRFTokenError ->
      text = "This page was open too long, or came from somewhere else. Go back and try again."
      conn |> html(403, Page.message("Try again", text)) |> halt()
  end

  defp server(conn, key), do: Keyword.get(conn.assigns.web, key, default(key))
  defp default(:pairing), do: Pairing
  defp default(:watcher), do: Watcher

  defp put_secret_key_base(conn, _opts),
    do: %{conn | secret_key_base: Pairing.secret_key_base(server(conn, :pairing))}

  defp put_headers(conn, _opts) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-frame-options", "DENY")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header(
      "content-security-policy",
      "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'"
    )
  end

  defp csrf, do: Plug.CSRFProtection.get_csrf_token()

  defp html(conn, status, body) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(status, body)
  end

  defp redirect(conn, path) do
    conn
    |> put_resp_header("location", path)
    |> send_resp(303, "")
  end
end
