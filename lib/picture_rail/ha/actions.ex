defmodule PictureRail.HA.Actions do
  @moduledoc """
  What the panel's controls do in Home Assistant: a pill's tap (toggle or
  run), which entities have a detail view, and the service call for a
  slider's value. Requests are maps the `:ha` controller calls and holds
  optimistically: `%{domain:, service:, entity_id:, data:, optimistic:,
  optimistic_attrs:}` (the last three optional).
  """

  alias PictureRail.HA.{Index, Overview}

  @toggle ~w(light switch fan input_boolean)
  @run %{
    "scene" => "turn_on",
    "script" => "turn_on",
    "button" => "press",
    "input_button" => "press"
  }
  @details ~w(light climate cover media_player)

  @doc "What tapping an entity's pill does: toggle or run it, or `nil` (nothing)."
  @spec tap(String.t(), Hassock.EntityState.t() | nil) :: map() | nil
  def tap(entity_id, es) do
    domain = Index.domain(entity_id)

    cond do
      not Overview.available?(es) ->
        nil

      domain in @toggle ->
        on? = es.state == "on"

        %{
          domain: domain,
          service: if(on?, do: "turn_off", else: "turn_on"),
          entity_id: entity_id,
          optimistic: if(on?, do: "off", else: "on")
        }

      Map.has_key?(@run, domain) ->
        %{domain: domain, service: @run[domain], entity_id: entity_id}

      true ->
        nil
    end
  end

  @doc "Whether an entity has a detail view (a chevron on its pill)."
  @spec detail?(String.t()) :: boolean()
  def detail?(entity_id), do: Index.domain(entity_id) in @details

  @doc "The service call for a slider of `kind` set to `value`."
  @spec slider(String.t(), :brightness | :color_temp | :position | :volume, number()) :: map()
  def slider(id, :brightness, v) do
    %{
      domain: "light",
      service: "turn_on",
      entity_id: id,
      data: %{brightness_pct: round(v)},
      optimistic: "on",
      optimistic_attrs: %{"brightness" => round(v * 255 / 100)}
    }
  end

  def slider(id, :color_temp, v),
    do: %{
      domain: "light",
      service: "turn_on",
      entity_id: id,
      data: %{color_temp_kelvin: round(v)},
      optimistic_attrs: %{"color_temp_kelvin" => round(v)}
    }

  def slider(id, :position, v),
    do: %{
      domain: "cover",
      service: "set_cover_position",
      entity_id: id,
      data: %{position: round(v)},
      optimistic_attrs: %{"current_position" => round(v)}
    }

  def slider(id, :volume, v),
    do: %{
      domain: "media_player",
      service: "volume_set",
      entity_id: id,
      data: %{volume_level: v / 100},
      optimistic_attrs: %{"volume_level" => v / 100}
    }
end
