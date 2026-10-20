defmodule PictureRail.Immich.Api do
  @moduledoc """
  The Immich calls the photo cache makes, as a behaviour so tests can stand
  in a fake server. `PictureRail.Immich.Client` is the real one; `conn` is
  whatever `connect/1` returns.
  """

  alias PictureRail.Immich.{Album, Asset, Client}
  alias PictureRail.Settings

  @type conn :: term()
  @type version :: {integer(), integer(), integer()}

  @callback connect(Settings.Immich.t()) :: conn()
  @callback ping(conn()) :: :ok | {:error, Client.error()}
  @callback version(conn()) :: {:ok, version()} | {:error, Client.error()}
  @callback list_albums(conn()) :: {:ok, [Album.t()]} | {:error, Client.error()}
  @callback list_album_images(conn(), [String.t()], version()) ::
              {:ok, [Asset.t()]} | {:error, Client.error()}
  @callback download_preview(conn(), String.t(), Path.t()) :: :ok | {:error, Client.error()}
  @callback download_clip(conn(), String.t(), Path.t()) :: :ok | {:error, Client.error()}
end
