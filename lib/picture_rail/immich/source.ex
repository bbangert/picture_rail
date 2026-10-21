defmodule PictureRail.Immich.Source do
  @moduledoc """
  Immich as a photo source (`PictureRail.PhotoSource`): photos from the
  chosen albums on an Immich server, kept by `PictureRail.Immich.Cache`.

  `choices/2` and `check/1` talk to the server with the settings they're
  given (the Setup page's, possibly unsaved), through
  `PictureRail.Immich.Client`; extra Req options for them can be set with
  `config :picture_rail, PictureRail.Immich.Source, req_options: [...]`
  (tests stub the server this way).
  """

  @behaviour PictureRail.PhotoSource

  alias PictureRail.Immich.{Album, Cache, Client}
  alias PictureRail.Settings
  alias PictureRail.Setup.Field

  @impl PictureRail.PhotoSource
  def type, do: "immich"

  @impl PictureRail.PhotoSource
  def label, do: "Immich"

  @impl PictureRail.PhotoSource
  def fields do
    [
      %Field{
        key: "url",
        label: "Server URL",
        type: :url,
        required?: true,
        help: "e.g. https://photos.example.com"
      },
      %Field{
        key: "api_key",
        label: "API key",
        type: :secret,
        required?: true,
        help: "From Account Settings > API Keys, with album.read, asset.read and asset.view"
      },
      %Field{key: "album_ids", label: "Albums", type: {:choices, :multi}, default: []},
      # Albums picked by name, for files edited by hand before album_ids;
      # saving albums on the Setup page or web page replaces them.
      %Field{
        key: "album_names",
        label: "Album names",
        type: {:choices, :multi},
        default: [],
        ui?: false,
        superseded_by: "album_ids"
      }
    ]
  end

  @impl PictureRail.PhotoSource
  def validate(config), do: {:ok, config}

  @impl PictureRail.PhotoSource
  def choices("album_ids", config) do
    case config |> client() |> Client.list_albums() do
      {:ok, albums} when is_list(albums) ->
        {:ok,
         albums
         |> Enum.sort_by(&String.downcase(&1.name))
         |> Enum.map(&{&1.id, album_label(&1)})}

      other ->
        {:error, describe(other)}
    end
  end

  def choices(key, _config), do: {:error, "no choices for #{key}"}

  defp album_label(%Album{name: name, asset_count: 1}), do: "#{name} (1 photo)"

  defp album_label(%Album{name: name, asset_count: n}) when is_integer(n),
    do: "#{name} (#{n} photos)"

  defp album_label(%Album{name: name}), do: name

  @doc """
  Reaches the server, checks it's a version the frame can talk to, and
  that the key may list albums (a key without `album.read`, or a wrong
  one, fails here rather than in the slideshow).
  """
  @impl PictureRail.PhotoSource
  def check(config) do
    client = client(config)

    with :ok <- Client.ping(client),
         {:ok, _version} <- Client.version(client),
         {:ok, _albums} <- Client.list_albums(client) do
      :ok
    else
      other -> {:error, describe(other)}
    end
  end

  defp client(config) do
    options =
      :picture_rail |> Application.get_env(__MODULE__, []) |> Keyword.get(:req_options, [])

    Client.new(%Settings.Immich{url: url(config["url"]), api_key: config["api_key"]}, options)
  end

  # As validation stores it: Test and loading albums get the unsaved one.
  defp url(url) when is_binary(url), do: url |> String.trim() |> String.trim_trailing("/")
  defp url(url), do: url

  defp describe({:error, :offline}), do: "Can't reach the server"
  defp describe({:error, :invalid_key}), do: "API key rejected"
  defp describe({:error, {:missing_permission, message}}), do: message
  defp describe({:error, {:http_error, status}}), do: "The server answered #{status}"
  defp describe(_other), do: "Unexpected answer from the server"

  # The cache and the tasks it downloads in, as one subtree that lives and
  # dies together (`:one_for_all`): stopping the source stops the cache,
  # then its tasks, before a replacement can start and tidy the same
  # directory, and a crashed cache takes its downloads with it for the
  # same reason. The tasks come first: the cache can start some in init.
  @impl PictureRail.PhotoSource
  def child_spec(opts) do
    name = Keyword.fetch!(opts, :name)
    tasks = tasks_name(name)
    children = [{Task.Supervisor, name: tasks}, {Cache, name: name, task_sup: tasks}]

    %{
      id: Cache,
      type: :supervisor,
      start: {Supervisor, :start_link, [children, [strategy: :one_for_all]]}
    }
  end

  # Next to the cache's name: in its registry, or beside its atom.
  defp tasks_name({:via, Registry, {registry, _key, _value}}),
    do: {:via, Registry, {registry, {__MODULE__, :tasks}}}

  defp tasks_name(name) when is_atom(name), do: Module.concat(name, Tasks)

  @impl PictureRail.PhotoSource
  def next(server) do
    case Cache.next(server) do
      {:ok, %{asset: asset, path: path, clip: clip}} ->
        {:ok, %{id: asset.id, path: path, width: asset.width, height: asset.height, clip: clip}}

      :none ->
        :none
    end
  end

  @impl PictureRail.PhotoSource
  defdelegate stats(server), to: Cache

  @impl PictureRail.PhotoSource
  def status_message(:invalid_key), do: "Immich API key rejected"
  def status_message({:missing_permission, detail}), do: detail
  def status_message(:no_albums), do: "No albums found"
  def status_message(_status), do: nil

  @doc """
  The Immich settings the client and cache use, from the settings' photo
  source; `nil` when the photo source isn't Immich (or isn't set up).
  """
  @spec immich(Settings.t()) :: Settings.Immich.t() | nil
  def immich(%Settings{photo_source: %Settings.PhotoSource{module: __MODULE__, config: config}}) do
    %Settings.Immich{
      url: config["url"],
      api_key: config["api_key"],
      album_ids: config["album_ids"],
      album_names: config["album_names"]
    }
  end

  def immich(%Settings{}), do: nil
end
