defmodule PictureRail.HA.Actions do
  @moduledoc """
  What the panel's controls do in Home Assistant: a pill's tap (toggle or
  run), which entities have a detail view, and the service calls behind
  the detail views' controls. Requests are maps the `:ha` controller calls
  and holds optimistically (`PictureRail.HA.Pending`): `%{domain:,
  service:, entity_id:, data:, optimistic:, optimistic_attrs:,
  supersedes:}` (the last four optional); `supersedes` lists attributes
  the call makes obsolete, so values still pending for them end.
  """

  alias PictureRail.HA.{Index, Overview}

  @toggle ~w(light switch fan input_boolean siren remote)
  @run %{
    "scene" => "turn_on",
    "script" => "turn_on",
    "button" => "press",
    "input_button" => "press"
  }
  @details ~w(light climate cover media_player lock select input_select)

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

  @typedoc "A slider's kind: what it sets."
  @type slider :: :brightness | :color_temp | :hue | :saturation | :position | :volume

  @doc """
  The service call for a slider of `kind` set to `value`. `es` is the
  entity as shown (pending values applied): a colour slider sends hue and
  saturation together, so it keeps the other one.
  """
  @spec slider(String.t(), slider(), number(), Hassock.EntityState.t() | nil) :: map()
  def slider(id, kind, v, es \\ nil)

  def slider(id, :brightness, v, _es) do
    %{
      domain: "light",
      service: "turn_on",
      entity_id: id,
      data: %{brightness_pct: round(v)},
      optimistic: "on",
      optimistic_attrs: %{"brightness" => round(v * 255 / 100)}
    }
  end

  def slider(id, :color_temp, v, _es),
    do: %{
      domain: "light",
      service: "turn_on",
      entity_id: id,
      data: %{color_temp_kelvin: round(v)},
      optimistic: "on",
      optimistic_attrs: %{"color_temp_kelvin" => round(v)},
      supersedes: ["hs_color"]
    }

  def slider(id, :hue, v, es), do: color(id, [round(v), Enum.at(hs(es), 1)])
  def slider(id, :saturation, v, es), do: color(id, [Enum.at(hs(es), 0), round(v)])

  def slider(id, :position, v, _es),
    do: %{
      domain: "cover",
      service: "set_cover_position",
      entity_id: id,
      data: %{position: round(v)},
      optimistic_attrs: %{"current_position" => round(v)}
    }

  def slider(id, :volume, v, _es),
    do: %{
      domain: "media_player",
      service: "volume_set",
      entity_id: id,
      data: %{volume_level: v / 100},
      optimistic_attrs: %{"volume_level" => v / 100}
    }

  # -- Lights --

  @doc "A light's colour as `[hue, saturation]` (0-360, 0-100); full red when it has none."
  @spec hs(Hassock.EntityState.t() | nil) :: [number()]
  def hs(%{attributes: %{"hs_color" => [h, s]}}) when is_number(h) and is_number(s), do: [h, s]
  def hs(_es), do: [0, 100]

  @doc "Turn a light on in a colour (`[hue, saturation]`)."
  @spec color(String.t(), [number()]) :: map()
  def color(id, [h, s]),
    do: %{
      domain: "light",
      service: "turn_on",
      entity_id: id,
      data: %{hs_color: [h, s]},
      optimistic: "on",
      optimistic_attrs: %{"hs_color" => [h, s]},
      supersedes: ["color_temp_kelvin"]
    }

  # -- Climate --

  @setpoints ~w(temperature target_temp_low target_temp_high)

  @doc """
  How far a thermostat's −/+ moves: its `target_temp_step`, else what Home
  Assistant's frontend uses, 1 for °F and 0.5 for °C. The panel doesn't
  know HA's unit system, so the range tells the unit: a climate entity's
  `max_temp` is above 50 only in °F.
  """
  @spec climate_step(map()) :: number()
  def climate_step(%{"target_temp_step" => step}) when is_number(step) and step > 0, do: step
  def climate_step(%{"max_temp" => max}) when is_number(max) and max > 50, do: 1
  def climate_step(_attrs), do: 0.5

  @doc """
  Whether a thermostat is set by a low and a high (heat/cool, auto)
  rather than one target.
  """
  @spec range?(Hassock.EntityState.t()) :: boolean()
  def range?(%{attributes: attrs}) do
    not is_number(attrs["temperature"]) and is_number(attrs["target_temp_low"]) and
      is_number(attrs["target_temp_high"])
  end

  @doc """
  The call for one press of a thermostat's − (`-1`) or + (`1`): its
  target (`:temperature`), or the low or high end of its range (`:low`,
  `:high`; both are sent, at least a step apart). `nil` at a limit.
  """
  @spec climate_target(Hassock.EntityState.t(), :temperature | :low | :high, -1 | 1) ::
          map() | nil
  def climate_target(%{entity_id: id, attributes: attrs}, which, dir) do
    step = climate_step(attrs)
    min = attrs["min_temp"] || 7
    max = attrs["max_temp"] || 35
    low = attrs["target_temp_low"]
    high = attrs["target_temp_high"]

    case which do
      :temperature ->
        moved(attrs["temperature"], dir, step, {min, max}, &set_temperature(id, &1))

      :low when is_number(high) ->
        moved(low, dir, step, {min, high - step}, &set_range(id, &1, high))

      :high when is_number(low) ->
        moved(high, dir, step, {low + step, max}, &set_range(id, low, &1))

      _ ->
        nil
    end
  end

  defp moved(value, dir, step, {min, max}, request) when is_number(value) and min <= max do
    new = value |> Kernel.+(dir * step) |> snap(step) |> Kernel.max(min) |> Kernel.min(max)
    if (new - value) * dir > 0, do: request.(new)
  end

  defp moved(_value, _dir, _step, _limits, _request), do: nil

  # on the step's grid, so half steps don't drift; whole numbers as integers
  defp snap(value, step) do
    snapped = Float.round(round(value / step) * step * 1.0, 2)
    if snapped == trunc(snapped), do: trunc(snapped), else: snapped
  end

  defp set_temperature(id, t),
    do: %{
      domain: "climate",
      service: "set_temperature",
      entity_id: id,
      data: %{temperature: t},
      optimistic_attrs: %{"temperature" => t},
      supersedes: @setpoints
    }

  defp set_range(id, low, high),
    do: %{
      domain: "climate",
      service: "set_temperature",
      entity_id: id,
      data: %{target_temp_low: low, target_temp_high: high},
      optimistic_attrs: %{"target_temp_low" => low, "target_temp_high" => high},
      supersedes: @setpoints
    }

  # -- Picking one of a list --

  @typedoc "A list an entity offers to pick from."
  @type option ::
          :hvac_mode
          | :fan_mode
          | :preset_mode
          | :swing_mode
          | :effect
          | :source
          | :sound_mode
          | :option

  @doc "The call that picks `value` from one of an entity's lists."
  @spec option(String.t(), option(), String.t()) :: map()
  def option(id, :hvac_mode, mode),
    do: %{
      domain: "climate",
      service: "set_hvac_mode",
      entity_id: id,
      data: %{hvac_mode: mode},
      optimistic: mode,
      # a mode has its own setpoints: one target, or a range
      supersedes: @setpoints
    }

  def option(id, kind, value) when kind in [:fan_mode, :preset_mode, :swing_mode] do
    key = Atom.to_string(kind)

    %{
      domain: "climate",
      service: "set_" <> key,
      entity_id: id,
      data: %{kind => value},
      optimistic_attrs: %{key => value}
    }
  end

  def option(id, :effect, effect),
    do: %{
      domain: "light",
      service: "turn_on",
      entity_id: id,
      data: %{effect: effect},
      optimistic: "on",
      optimistic_attrs: %{"effect" => effect}
    }

  def option(id, :source, source),
    do: %{
      domain: "media_player",
      service: "select_source",
      entity_id: id,
      data: %{source: source},
      optimistic_attrs: %{"source" => source}
    }

  def option(id, :sound_mode, mode),
    do: %{
      domain: "media_player",
      service: "select_sound_mode",
      entity_id: id,
      data: %{sound_mode: mode},
      optimistic_attrs: %{"sound_mode" => mode}
    }

  def option(id, :option, option),
    do: %{
      domain: Index.domain(id),
      service: "select_option",
      entity_id: id,
      data: %{option: option},
      optimistic: option
    }

  @doc """
  An entity's list for `kind` and its current pick (from its state for
  modes and selects, else an attribute); `[]` when it has none.
  """
  @spec options(Hassock.EntityState.t(), option()) :: {[String.t()], String.t() | nil}
  def options(%{state: state, attributes: attrs}, kind) do
    {list, current} = option_attrs(kind)
    list = if is_list(attrs[list]), do: Enum.filter(attrs[list], &is_binary/1), else: []
    {list, if(current == :state, do: state, else: attrs[current])}
  end

  defp option_attrs(:hvac_mode), do: {"hvac_modes", :state}
  defp option_attrs(:fan_mode), do: {"fan_modes", "fan_mode"}
  defp option_attrs(:preset_mode), do: {"preset_modes", "preset_mode"}
  defp option_attrs(:swing_mode), do: {"swing_modes", "swing_mode"}
  defp option_attrs(:effect), do: {"effect_list", "effect"}
  defp option_attrs(:source), do: {"source_list", "source"}
  defp option_attrs(:sound_mode), do: {"sound_mode_list", "sound_mode"}
  defp option_attrs(:option), do: {"options", :state}

  # -- Media players --

  @doc "A media player service with no data (`media_play_pause`, `volume_up`, ...)."
  @spec media(String.t(), String.t()) :: map()
  def media(id, service), do: %{domain: "media_player", service: service, entity_id: id}

  @doc """
  Turn a media player on or off. Not optimistic: one that's on reports
  `idle`, `playing` or `paused`, one that's off `off` or `standby`, so no
  one state could stand in for it.
  """
  @spec power(String.t(), boolean()) :: map()
  def power(id, true), do: media(id, "turn_on")
  def power(id, false), do: media(id, "turn_off")

  @doc "Mute a media player if it isn't muted, unmute it if it is."
  @spec toggle_mute(Hassock.EntityState.t()) :: map()
  def toggle_mute(%{entity_id: id, attributes: attrs}) do
    muted? = attrs["is_volume_muted"] != true

    id
    |> media("volume_mute")
    |> Map.merge(%{
      data: %{is_volume_muted: muted?},
      optimistic_attrs: %{"is_volume_muted" => muted?}
    })
  end

  @doc "Turn a media player's shuffle on or off."
  @spec toggle_shuffle(Hassock.EntityState.t()) :: map()
  def toggle_shuffle(%{entity_id: id, attributes: attrs}) do
    shuffle? = attrs["shuffle"] != true

    id
    |> media("shuffle_set")
    |> Map.merge(%{data: %{shuffle: shuffle?}, optimistic_attrs: %{"shuffle" => shuffle?}})
  end

  @doc "A media player's next repeat mode: off, all, one, off."
  @spec cycle_repeat(Hassock.EntityState.t()) :: map()
  def cycle_repeat(%{entity_id: id, attributes: attrs}) do
    next =
      case attrs["repeat"] do
        "all" -> "one"
        "one" -> "off"
        # off, or not reported (shown as off)
        _ -> "all"
      end

    id
    |> media("repeat_set")
    |> Map.merge(%{data: %{repeat: next}, optimistic_attrs: %{"repeat" => next}})
  end

  # -- Locks --

  @doc "Lock, unlock or open (unlatch) a lock."
  @spec lock(String.t(), :lock | :unlock | :open) :: map()
  def lock(id, :lock), do: %{domain: "lock", service: "lock", entity_id: id, optimistic: "locked"}

  def lock(id, :unlock),
    do: %{domain: "lock", service: "unlock", entity_id: id, optimistic: "unlocked"}

  def lock(id, :open), do: %{domain: "lock", service: "open", entity_id: id}
end
