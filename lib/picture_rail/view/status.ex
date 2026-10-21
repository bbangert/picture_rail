defmodule PictureRail.View.Status do
  @moduledoc """
  What to say on screen while there's no photo to show.
  """

  @doc "A short status line from the `:settings` and `:immich` controllers."
  @spec message(map() | nil, map() | nil) :: String.t()
  def message(settings, immich)

  def message(%{status: status}, _immich) when status in [:missing, :template],
    do: "Set up picture_rail.json"

  def message(%{status: {:error, _}}, _immich), do: "picture_rail.json has errors"
  def message(%{configured: %{photo_source: false}}, _immich), do: "Photos aren't set up"
  def message(_settings, %{status: :invalid_key}), do: "Immich API key rejected"
  def message(_settings, %{status: {:missing_permission, detail}}), do: detail
  def message(_settings, %{status: :no_albums}), do: "No albums found"
  def message(_settings, %{status: :offline}), do: "Immich offline"
  def message(_settings, %{status: :online, photos: 0}), do: "The albums are empty"
  def message(_settings, _immich), do: "Loading photos"
end
