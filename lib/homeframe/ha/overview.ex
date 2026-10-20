defmodule HomeFrame.HA.Overview do
  @moduledoc """
  The panel's views, grouped the way Home Assistant's default "Overview"
  dashboard (the `home` strategy) groups them:

    * `overview/1` - summaries (light, climate, security, media,
      maintenance, persons; each only when it has entities), floors with
      their areas, areas without a floor, and whether "Devices" has content
    * `area_view/2` - temperature and humidity, then Light, Climate,
      Security, Media, Scenes, the remaining entities grouped by device (an
      "unassigned" group last), and Automations
    * `media_view/1` - media players by area
    * `devices_view/1` - entities of devices without an area, by device

  The filters follow the frontend's `HOME_SUMMARIES_FILTERS` and the
  light/climate/security/maintenance view strategies (`device_class` comes
  from the state). Everything here reads the model's ETS table and the
  entity states, through a source (`source/0`), so tests can pass their own.
  """

  alias HomeFrame.HA.{Index, Model}

  @type source :: %{
          table: atom() | :ets.tid(),
          state: (String.t() -> Hassock.EntityState.t() | nil)
        }
  @type summary_kind :: :light | :climate | :security | :media_players | :maintenance | :persons
  @type summary :: %{kind: summary_kind(), entity_ids: [String.t()], active: non_neg_integer()}
  @type section ::
          %{kind: summary_kind() | :scenes | :automations, entity_ids: [String.t()]}
          | %{
              kind: :device,
              device_id: String.t() | nil,
              name: String.t() | nil,
              battery: String.t() | nil,
              entity_ids: [String.t()]
            }

  @summaries [:light, :climate, :security, :media_players, :maintenance, :persons]

  # {domains (nil = any), device classes (nil = any; "none" = no class),
  #  categories (nil = any; "none" = no entity_category)}
  @filters %{
    light: [{["light"], nil, ["none"]}],
    climate: [
      {["climate", "humidifier", "fan", "water_heater"], nil, ["none"]},
      {["cover"], ~w(awning blind curtain shade shutter window none), ["none"]},
      {["binary_sensor"], ["window"], ["none"]}
    ],
    security: [
      {["camera", "alarm_control_panel", "lock"], nil, ["none"]},
      {["cover"], ~w(door garage gate window), ["none"]},
      {["binary_sensor"],
       ~w(lock door window garage_door opening carbon_monoxide gas glass_break moisture safety smoke tamper),
       ["none"]},
      {["binary_sensor"], ["tamper"], ["diagnostic"]}
    ],
    media_players: [{["media_player"], nil, ["none"]}],
    maintenance: [{["sensor", "binary_sensor"], ["battery"], nil}],
    persons: [{["person"], nil, nil}],
    scenes: [{["scene"], nil, ["none"]}],
    automations: [{["automation"], nil, ["none"]}]
  }

  # Left out of "Devices" (helpers/other-devices-filters.ts).
  @other_hidden_platforms ~w(automation script hassio backup mobile_app zone person)
  @other_hidden_domains ~w(ai_task automation configurator device_tracker event geo_location
                           notify persistent_notification script sun tag todo zone
                           conversation stt tts wake_word assist_satellite)

  @low_battery 20

  @doc "The live model and states."
  @spec source() :: source()
  def source, do: %{table: :homeframe_ha, state: &Model.state/1}

  @doc "The overview: summaries, floors with areas, floorless areas, devices."
  @spec overview(source()) :: %{
          summaries: [summary()],
          floors: [%{floor: Hassock.Floor.t(), areas: [area_card()]}],
          other_areas: [area_card()],
          devices?: boolean()
        }
  def overview(src \\ source()) do
    floors =
      for %{floor: floor, area_ids: ids} <- Model.floors(src.table),
          areas = area_cards(src, ids),
          areas != [],
          do: %{floor: floor, areas: areas}

    %{
      summaries: summaries(src, Model.entity_ids(src.table)),
      floors: floors,
      other_areas: area_cards(src, Model.floorless_area_ids(src.table)),
      devices?: devices_view(src) != []
    }
  end

  @type area_card :: %{area: Hassock.Area.t(), temperature: Hassock.EntityState.t() | nil}

  defp area_cards(src, ids) do
    for id <- ids, %{area: area} <- [Model.area(id, src.table)] do
      %{area: area, temperature: entity_state(src, area.temperature_entity_id)}
    end
  end

  @doc "Summaries over `entity_ids`, in HA's order, leaving out empty ones."
  @spec summaries(source(), [String.t()]) :: [summary()]
  def summaries(src, entity_ids) do
    for kind <- @summaries,
        ids = matching(src, entity_ids, kind),
        ids != [],
        do: %{kind: kind, entity_ids: ids, active: Enum.count(ids, &active?(src, kind, &1))}
  end

  @doc "One area's view, or `nil` if the area is gone."
  @spec area_view(source(), String.t()) ::
          %{
            area: Hassock.Area.t(),
            temperature: Hassock.EntityState.t() | nil,
            humidity: Hassock.EntityState.t() | nil,
            sections: [section()]
          }
          | nil
  def area_view(src \\ source(), area_id) do
    case Model.area(area_id, src.table) do
      nil -> nil
      %{area: area, entity_ids: ids} -> build_area_view(src, area, ids)
    end
  end

  defp build_area_view(src, area, ids) do
    grouped = Map.new(@summaries -- [:maintenance], &{&1, matching(src, ids, &1)})
    scenes = matching(src, ids, :scenes)
    automations = matching(src, ids, :automations)

    # Maintenance isn't taken out: batteries stay with their devices.
    taken = MapSet.new(List.flatten([Map.values(grouped), scenes, automations]))
    rest = Enum.reject(ids, &MapSet.member?(taken, &1))

    sections =
      Enum.map(
        [:light, :climate, :security, :media_players],
        &%{kind: &1, entity_ids: grouped[&1]}
      ) ++
        [%{kind: :scenes, entity_ids: scenes}] ++
        device_sections(src, rest, :unassigned_last) ++
        [%{kind: :automations, entity_ids: automations}]

    %{
      area: area,
      temperature: entity_state(src, area.temperature_entity_id),
      humidity: entity_state(src, area.humidity_entity_id),
      sections: Enum.reject(sections, &(&1.entity_ids == []))
    }
  end

  @doc "Media players grouped by area (floor order), players without an area last."
  @spec media_view(source()) :: [%{area: Hassock.Area.t() | nil, entity_ids: [String.t()]}]
  def media_view(src \\ source()) do
    players = matching(src, Model.entity_ids(src.table), :media_players)
    by_area = Enum.group_by(players, &Model.entity(&1, src.table).area_id)

    area_ids =
      Enum.flat_map(Model.floors(src.table), & &1.area_ids) ++
        Model.floorless_area_ids(src.table)

    for(
      id <- area_ids,
      ids = Map.get(by_area, id, []),
      ids != [],
      do: %{area: Model.area(id, src.table).area, entity_ids: ids}
    ) ++
      case Map.get(by_area, nil, []) do
        [] -> []
        ids -> [%{area: nil, entity_ids: ids}]
      end
  end

  @doc "Devices without an area and their entities (HA's \"other devices\")."
  @spec devices_view(source()) :: [section()]
  def devices_view(src \\ source()) do
    ids =
      Enum.filter(Model.entity_ids(src.table), fn id ->
        entity = Model.entity(id, src.table)

        entity.area_id == nil and entity.device_id != nil and entity.entry != nil and
          entity.entry.platform not in @other_hidden_platforms and
          entity.domain not in @other_hidden_domains
      end)

    device_sections(src, ids, :drop_unassigned)
  end

  # Remaining entities by device, by device name. Per device: the first
  # battery sensor as a badge, entities without a category as the list; a
  # device left with no entities is skipped.
  defp device_sections(src, ids, unassigned) do
    groups = Enum.group_by(ids, &Model.entity(&1, src.table).device_id)

    devices =
      groups
      |> Map.delete(nil)
      |> Enum.map(fn {device_id, ids} ->
        device = Model.device(device_id, src.table)
        device_section(src, device_id, Index.device_name(device), ids)
      end)
      |> Enum.sort_by(&String.downcase(&1.name || ""))

    unassigned_group =
      if unassigned == :unassigned_last and Map.has_key?(groups, nil),
        do: [device_section(src, nil, nil, groups[nil])],
        else: []

    Enum.reject(devices ++ unassigned_group, &(&1.entity_ids == []))
  end

  defp device_section(src, device_id, name, ids) do
    {batteries, others} = Enum.split_with(ids, &battery_sensor?(src, &1))

    %{
      kind: :device,
      device_id: device_id,
      name: name,
      battery: List.first(batteries),
      entity_ids: others |> Enum.filter(&(category(src, &1) == "none")) |> sort_by_name(src)
    }
  end

  defp battery_sensor?(src, id),
    do: Index.domain(id) == "sensor" and device_class(src, id) == "battery"

  # -- Filters --

  defp matching(src, ids, kind) do
    filters = Map.fetch!(@filters, kind)
    ids |> Enum.filter(&Enum.any?(filters, fn f -> matches?(src, &1, f) end)) |> sort_by_name(src)
  end

  defp matches?(src, id, {domains, classes, categories}) do
    (domains == nil or Index.domain(id) in domains) and
      (classes == nil or device_class(src, id) in classes) and
      (categories == nil or category(src, id) in categories)
  end

  defp device_class(src, id) do
    case entity_state(src, id) do
      %{attributes: %{"device_class" => class}} when is_binary(class) -> class
      _ -> "none"
    end
  end

  defp category(src, id) do
    case Model.entity(id, src.table) do
      %{entry: %{entity_category: category}} when is_binary(category) -> category
      _ -> "none"
    end
  end

  # What a summary pill counts: lights on, climate devices running,
  # security things open or unlocked, media playing, batteries low, people
  # home.
  defp active?(src, kind, id) do
    case entity_state(src, id) do
      nil -> false
      %{state: state} = es -> active_state?(kind, Index.domain(id), state, es)
    end
  end

  defp active_state?(:light, _domain, state, _es), do: state == "on"

  defp active_state?(:climate, _domain, state, _es),
    do: state not in ~w(off closed unavailable unknown idle)

  defp active_state?(:security, "lock", state, _es), do: state in ~w(unlocked open opening jammed)
  defp active_state?(:security, "cover", state, _es), do: state in ~w(open opening)
  defp active_state?(:security, "binary_sensor", state, _es), do: state == "on"

  defp active_state?(:security, "alarm_control_panel", state, _es),
    do: state in ~w(triggered pending arming)

  defp active_state?(:security, _domain, _state, _es), do: false
  defp active_state?(:media_players, _domain, state, _es), do: state == "playing"
  defp active_state?(:maintenance, "binary_sensor", state, _es), do: state == "on"

  defp active_state?(:maintenance, _domain, state, _es) do
    case Float.parse(state) do
      {level, _} -> level <= @low_battery
      :error -> false
    end
  end

  defp active_state?(:persons, _domain, state, _es), do: state == "home"

  # -- Names --

  @doc """
  An entity's name. `:full` is what HA shows on its own (the state's
  `friendly_name`); `:own` is the entity's part without the device (for a
  list under the device's heading), falling back to the device's name.
  """
  @spec name(source(), String.t(), :full | :own) :: String.t()
  def name(src, entity_id, form \\ :full)

  def name(src, entity_id, :full) do
    case entity_state(src, entity_id) do
      %{attributes: %{"friendly_name" => name}} when is_binary(name) and name != "" -> name
      _ -> name(src, entity_id, :own)
    end
  end

  def name(src, entity_id, :own) do
    entity = Model.entity(entity_id, src.table)
    entry = entity && entity.entry

    (entry && (entry.name || entry.original_name)) ||
      (entity && Index.device_name(Model.device(entity.device_id, src.table))) ||
      friendly_name(src, entity_id) || entity_id
  end

  defp friendly_name(src, entity_id) do
    case entity_state(src, entity_id) do
      %{attributes: %{"friendly_name" => name}} when is_binary(name) -> name
      _ -> nil
    end
  end

  defp sort_by_name(ids, src), do: Enum.sort_by(ids, &String.downcase(name(src, &1)))

  @doc "Whether an entity is usable: it has a state that isn't unavailable or unknown."
  @spec available?(Hassock.EntityState.t() | nil) :: boolean()
  def available?(%{state: state}), do: state not in ["unavailable", "unknown"]
  def available?(nil), do: false

  defp entity_state(_src, nil), do: nil
  defp entity_state(src, id), do: src.state.(id)
end
