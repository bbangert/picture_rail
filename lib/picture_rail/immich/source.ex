defmodule PictureRail.Immich.Source do
  @moduledoc """
  Immich as a photo source (`PictureRail.PhotoSource`): photos from the
  chosen albums on an Immich server.
  """

  @behaviour PictureRail.PhotoSource

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
      # Albums picked by name, for files edited by hand before album_ids.
      %Field{
        key: "album_names",
        label: "Album names",
        type: {:choices, :multi},
        default: [],
        ui?: false
      }
    ]
  end

  @impl PictureRail.PhotoSource
  def validate(config), do: {:ok, config}

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
