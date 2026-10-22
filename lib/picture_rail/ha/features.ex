defmodule PictureRail.HA.Features do
  @moduledoc """
  An entity's `supported_features` bitmask, by name: which controls its
  detail view can offer. The bits are Home Assistant's, per domain
  (`ClimateEntityFeature`, `MediaPlayerEntityFeature`, ...); only those
  the panel uses are named.
  """
  import Bitwise

  alias PictureRail.HA.Index

  @bits %{
    "climate" => [
      target_temperature: 1,
      target_range: 2,
      target_humidity: 4,
      fan_mode: 8,
      preset_mode: 16,
      swing_mode: 32,
      turn_off: 128,
      turn_on: 256
    ],
    "cover" => [open: 1, close: 2, set_position: 4, stop: 8],
    "light" => [effect: 4],
    "lock" => [open: 1],
    "media_player" => [
      pause: 1,
      volume_set: 4,
      volume_mute: 8,
      previous_track: 16,
      next_track: 32,
      turn_on: 128,
      turn_off: 256,
      volume_step: 1024,
      select_source: 2048,
      stop: 4096,
      play: 16_384,
      shuffle_set: 32_768,
      select_sound_mode: 65_536,
      repeat_set: 262_144,
      grouping: 524_288
    ]
  }

  @doc "Whether the entity supports `feature` (false for one its domain doesn't name)."
  @spec has?(Hassock.EntityState.t() | nil, atom()) :: boolean()
  def has?(nil, _feature), do: false

  def has?(%{entity_id: id, attributes: attrs}, feature) do
    case @bits |> Map.get(Index.domain(id), []) |> Keyword.get(feature) do
      nil -> false
      bit -> (mask(attrs) &&& bit) != 0
    end
  end

  @doc "Every named feature the entity supports."
  @spec list(Hassock.EntityState.t() | nil) :: [atom()]
  def list(nil), do: []

  def list(%{entity_id: id} = es) do
    for {feature, _bit} <- Map.get(@bits, Index.domain(id), []), has?(es, feature), do: feature
  end

  defp mask(%{"supported_features" => mask}) when is_integer(mask), do: mask
  defp mask(_attrs), do: 0
end
