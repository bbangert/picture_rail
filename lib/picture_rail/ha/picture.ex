defmodule PictureRail.HA.Picture do
  @moduledoc """
  An entity's picture, downloaded for the panel: a camera's snapshot, an
  image entity's image, a media player's artwork.

  Home Assistant gives each as `entity_picture`: a path on its own server
  (`/api/camera_proxy/...`, `/api/media_player_proxy/...`, with a
  short-lived token), or a URL on another (a player's own artwork server).
  Only Home Assistant's own server is sent the access token.

  Emerge draws images from files, so each download goes to a new file in
  `dir/0` (an asset path the viewport allows), and the old one is removed
  when the new one replaces it.
  """

  alias PictureRail.HA.{Index, Model}
  alias PictureRail.{Paths, Settings}

  @doc "Where downloaded pictures go."
  @spec dir() :: Path.t()
  def dir, do: Path.join([Paths.data_dir(), "cache", "ha"])

  @doc """
  Download `entity_id`'s picture, unless it's still at `last_url` (a
  camera's snapshot always is downloaded: the same URL gives a new one).
  """
  @spec fetch(String.t(), String.t() | nil) ::
          {:ok, Path.t(), String.t()} | :unchanged | {:error, term()}
  def fetch(entity_id, last_url) do
    with %Settings.HomeAssistant{} = ha <- Settings.current().home_assistant,
         url when is_binary(url) <- url(Model.state(entity_id), ha.url) do
      fetch(entity_id, url, last_url, ha)
    else
      nil -> {:error, :no_picture}
    end
  end

  defp fetch(entity_id, url, last_url, ha) do
    if url == last_url and Index.domain(entity_id) != "camera" do
      :unchanged
    else
      with {:ok, path} <- download(url, ha, entity_id), do: {:ok, path, url}
    end
  end

  @doc "The URL of an entity's picture (HA's paths against `base`), or `nil`."
  @spec url(Hassock.EntityState.t() | nil, String.t()) :: String.t() | nil
  def url(%{attributes: %{"entity_picture" => picture}}, base)
      when is_binary(picture) and picture != "",
      do: base |> URI.merge(picture) |> URI.to_string()

  def url(_es, _base), do: nil

  @doc "Whether `url` is on Home Assistant's own server (`base`): it may have the token."
  @spec own_server?(String.t(), String.t()) :: boolean()
  def own_server?(url, base) do
    a = URI.parse(url)
    b = URI.parse(base)
    {a.scheme, a.host, a.port} == {b.scheme, b.host, b.port}
  end

  @doc "Remove a picture downloaded earlier (only from `dir/0`)."
  @spec discard(Path.t() | nil) :: :ok
  def discard(nil), do: :ok

  def discard(path) do
    if Path.dirname(path) == dir(), do: File.rm(path)
    :ok
  end

  @doc "Remove every downloaded picture (at start: none is on screen)."
  @spec clear() :: :ok
  def clear do
    File.rm_rf(dir())
    :ok
  end

  defp download(url, ha, entity_id) do
    File.mkdir_p!(dir())
    name = Path.join(dir(), "#{entity_id}-#{System.unique_integer([:positive])}")
    tmp = name <> ".part"
    headers = if own_server?(url, ha.url), do: [authorization: "Bearer " <> ha.token], else: []

    result =
      Req.get(url,
        headers: headers,
        into: File.stream!(tmp),
        decode_body: false,
        receive_timeout: 10_000,
        retry: false,
        connect_options: [timeout: 10_000] ++ ssl(url, ha)
      )

    case result do
      {:ok, %Req.Response{status: 200} = resp} ->
        path = name <> extension(resp)
        File.rename!(tmp, path)
        {:ok, path}

      {:ok, %Req.Response{status: status}} ->
        File.rm(tmp)
        {:error, {:status, status}}

      {:error, reason} ->
        File.rm(tmp)
        {:error, reason}
    end
  end

  # HA's own HTTPS server, when it's set not to verify (a self-signed cert)
  defp ssl("https:" <> _ = url, %Settings.HomeAssistant{ssl_verify: false} = ha) do
    if own_server?(url, ha.url), do: [transport_opts: [verify: :verify_none]], else: []
  end

  defp ssl(_url, _ha), do: []

  # Emerge goes by the file's extension
  defp extension(resp) do
    case Req.Response.get_header(resp, "content-type") do
      ["image/png" <> _ | _] -> ".png"
      ["image/webp" <> _ | _] -> ".webp"
      ["image/gif" <> _ | _] -> ".gif"
      _ -> ".jpg"
    end
  end
end
