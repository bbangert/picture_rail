defmodule PictureRail.Immich.Asset do
  @moduledoc """
  One Immich photo: what the cache needs to download and show it.

  `id` + `checksum` identify a version of the photo (an edit changes the
  checksum). `live_photo_video_id` is the motion clip of a Live Photo.
  """
  @enforce_keys [:id, :checksum]
  defstruct [:id, :checksum, :width, :height, :local_date_time, :live_photo_video_id, :mime]

  @type t :: %__MODULE__{
          id: String.t(),
          checksum: String.t(),
          width: pos_integer() | nil,
          height: pos_integer() | nil,
          local_date_time: String.t() | nil,
          live_photo_video_id: String.t() | nil,
          mime: String.t() | nil
        }

  @doc "From an AssetResponseDto map; `nil` for anything that isn't a showable photo."
  @spec from_api(map()) :: t() | nil
  def from_api(%{"id" => id, "checksum" => checksum, "type" => "IMAGE"} = asset)
      when is_binary(id) and is_binary(checksum) do
    if asset["isTrashed"] == true do
      nil
    else
      %__MODULE__{
        id: id,
        checksum: checksum,
        width: asset["width"],
        height: asset["height"],
        local_date_time: asset["localDateTime"],
        live_photo_video_id: asset["livePhotoVideoId"],
        mime: asset["originalMimeType"]
      }
    end
  end

  def from_api(_asset), do: nil
end
