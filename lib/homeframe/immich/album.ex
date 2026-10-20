defmodule HomeFrame.Immich.Album do
  @moduledoc """
  An Immich album, with the fields that tell whether its contents changed
  (`asset_count`, `updated_at`, `last_modified_asset_timestamp`).
  """
  @enforce_keys [:id, :name]
  defstruct [:id, :name, :asset_count, :updated_at, :last_modified_asset_timestamp]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          asset_count: non_neg_integer() | nil,
          updated_at: String.t() | nil,
          last_modified_asset_timestamp: String.t() | nil
        }

  @doc "From an AlbumResponseDto map."
  @spec from_api(map()) :: t() | nil
  def from_api(%{"id" => id, "albumName" => name} = album) when is_binary(id) do
    %__MODULE__{
      id: id,
      name: name,
      asset_count: album["assetCount"],
      updated_at: album["updatedAt"],
      last_modified_asset_timestamp: album["lastModifiedAssetTimestamp"]
    }
  end

  def from_api(_album), do: nil

  @doc "The fields that change when an album's contents change."
  @spec version(t()) :: term()
  def version(%__MODULE__{} = album),
    do: {album.asset_count, album.updated_at, album.last_modified_asset_timestamp}
end
