defmodule PictureRail.View.Status do
  @moduledoc """
  What to say on screen while there's no photo to show.
  """

  alias PictureRail.PhotoSource

  @doc "A short status line from the `:settings` and `:photos` controllers."
  @spec message(map() | nil, map() | nil) :: String.t()
  def message(settings, photos)

  def message(%{status: status}, _immich) when status in [:missing, :template],
    do: "Set up picture_rail.json"

  def message(%{status: {:error, _}}, _immich), do: "picture_rail.json has errors"
  def message(%{configured: %{photo_source: false}}, _immich), do: "Photos aren't set up"

  def message(settings, %{status: status} = photos) do
    source = source(settings)

    case status do
      :offline -> "#{if source, do: source.label(), else: "Photos"} offline"
      :online when photos.photos == 0 -> "No photos to show"
      generic when generic in [:unconfigured, :connecting, :online] -> "Loading photos"
      own -> (source && PhotoSource.status_message(source, own)) || "Loading photos"
    end
  end

  def message(_settings, _photos), do: "Loading photos"

  defp source(%{photo_source_type: type}) when is_binary(type) do
    case PhotoSource.module_for(type) do
      {:ok, module} -> module
      :error -> nil
    end
  end

  defp source(_settings), do: nil
end
