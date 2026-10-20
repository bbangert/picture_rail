defmodule PictureRail.HA.Index do
  @moduledoc """
  Home Assistant's registries joined into the shape the panel walks:
  floors -> areas -> entities, devices, and the devices without an area.
  Pure; `PictureRail.HA.Model` builds it and stores it as ETS rows.

  An entity's area is its own `area_id`, else its device's, else the
  device's parent's (`via_device_id`), as in HA's frontend. Left out:
  entities with `hidden_by` or `disabled_by` set, entities of a disabled
  device, and entities with no state (not loaded). Entities with an
  `entity_category` stay in: HA's summaries count some (diagnostic
  batteries, tamper sensors); `PictureRail.HA.Overview` filters the rest.

  HA's own dashboard doesn't sort (it keeps registry order, which hassock's
  registry cache doesn't keep), so floors go by level then name, and areas
  and devices by name.
  """

  alias Hassock.{Area, Device, EntityEntry, Floor}

  defmodule Entity do
    @moduledoc "A shown entity: where it lives and what its registry entry says."
    @enforce_keys [:id, :domain]
    defstruct [:id, :domain, :area_id, :device_id, :entry]

    @type t :: %__MODULE__{
            id: String.t(),
            domain: String.t(),
            area_id: String.t() | nil,
            device_id: String.t() | nil,
            entry: EntityEntry.t() | nil
          }
  end

  defstruct floors: [],
            floorless_area_ids: [],
            areas: %{},
            area_entities: %{},
            devices: %{},
            entities: %{},
            no_area_device_ids: []

  @type t :: %__MODULE__{
          floors: [%{floor: Floor.t(), area_ids: [String.t()]}],
          floorless_area_ids: [String.t()],
          areas: %{String.t() => Area.t()},
          area_entities: %{String.t() => [String.t()]},
          devices: %{String.t() => Device.t()},
          entities: %{String.t() => Entity.t()},
          no_area_device_ids: [String.t()]
        }

  @type registries :: %{
          floor: [Floor.t()],
          area: [Area.t()],
          device: [Device.t()],
          entity: [EntityEntry.t()]
        }

  @doc """
  Join the registries. `state_ids` are the entity ids that have a state;
  entities with a state but no registry entry are kept, with no area or
  device.
  """
  @spec build(registries(), [String.t()] | MapSet.t()) :: t()
  def build(registries, state_ids) do
    state_ids = MapSet.new(state_ids)
    devices = Map.new(registries.device, &{&1.id, &1})
    areas = Map.new(registries.area, &{&1.area_id, &1})

    registered =
      for entry <- registries.entity,
          MapSet.member?(state_ids, entry.entity_id),
          shown?(entry, devices),
          into: %{},
          do: {entry.entity_id, entity(entry, devices, areas)}

    in_registry = MapSet.new(registries.entity, & &1.entity_id)

    unregistered =
      for id <- state_ids,
          not MapSet.member?(in_registry, id),
          into: %{},
          do: {id, %Entity{id: id, domain: domain(id)}}

    entities = Map.merge(unregistered, registered)

    area_entities =
      entities
      |> Map.values()
      |> Enum.filter(& &1.area_id)
      |> Enum.group_by(& &1.area_id, & &1.id)
      |> Map.new(fn {area_id, ids} -> {area_id, Enum.sort(ids)} end)

    {floors, floorless} = floors(registries.floor, registries.area)

    %__MODULE__{
      floors: floors,
      floorless_area_ids: floorless,
      areas: areas,
      area_entities: area_entities,
      devices: devices,
      entities: entities,
      no_area_device_ids: no_area_devices(entities, devices)
    }
  end

  @doc ~s[The domain of an entity id: `"light.kitchen"` -> `"light"`.]
  @spec domain(String.t()) :: String.t()
  def domain(entity_id), do: entity_id |> String.split(".", parts: 2) |> hd()

  defp shown?(%EntityEntry{} = entry, devices) do
    entry.hidden_by == nil and entry.disabled_by == nil and
      not device_disabled?(devices[entry.device_id])
  end

  defp device_disabled?(%Device{disabled_by: by}), do: by != nil
  defp device_disabled?(nil), do: false

  defp entity(entry, devices, areas) do
    device = devices[entry.device_id]
    area_id = entry.area_id || device_area_id(device, devices)

    %Entity{
      id: entry.entity_id,
      domain: domain(entry.entity_id),
      # an area id that's no longer in the registry counts as none
      area_id: if(Map.has_key?(areas, area_id), do: area_id),
      device_id: device && device.id,
      entry: entry
    }
  end

  defp device_area_id(nil, _devices), do: nil
  defp device_area_id(%Device{area_id: id}, _devices) when is_binary(id), do: id

  defp device_area_id(%Device{via_device_id: parent}, devices),
    do: get_in(devices, [parent, Access.key(:area_id)])

  # Floors by level (lowest first, no level last), then name; areas by
  # name. Areas whose floor is unknown count as floorless.
  defp floors(floors, areas) do
    by_floor = Enum.group_by(areas, & &1.floor_id)
    floor_ids = MapSet.new(floors, & &1.floor_id)

    sorted =
      floors
      |> Enum.sort_by(&{&1.level == nil, &1.level, String.downcase(&1.name)})
      |> Enum.map(&%{floor: &1, area_ids: area_ids(Map.get(by_floor, &1.floor_id, []))})

    floorless = areas |> Enum.reject(&MapSet.member?(floor_ids, &1.floor_id)) |> area_ids()
    {sorted, floorless}
  end

  defp area_ids(areas),
    do: areas |> Enum.sort_by(&String.downcase(&1.name)) |> Enum.map(& &1.area_id)

  defp no_area_devices(entities, devices) do
    entities
    |> Map.values()
    |> Enum.filter(&(&1.area_id == nil and &1.device_id != nil))
    |> Enum.map(& &1.device_id)
    |> Enum.uniq()
    |> Enum.sort_by(&device_sort_name(devices[&1]))
  end

  @doc "A device's shown name: the user's name, else the integration's."
  @spec device_name(Device.t() | nil) :: String.t() | nil
  def device_name(nil), do: nil
  def device_name(%Device{name_by_user: name}) when is_binary(name) and name != "", do: name
  def device_name(%Device{name: name}), do: name

  defp device_sort_name(device), do: String.downcase(device_name(device) || "")
end
