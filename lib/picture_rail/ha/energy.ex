defmodule PictureRail.HA.Energy do
  @moduledoc """
  Today's energy, from Home Assistant's energy preferences
  (`energy/get_prefs`) and long-term statistics
  (`recorder/statistics_during_period`), the way its Energy dashboard adds
  them up. Pure; `PictureRail.HA.EnergyPoller` fetches the inputs.

  Sources: `grid` (energy from and to the grid, cost, export
  compensation), `solar`, `battery` (energy out of and into the battery),
  `gas` and `water` (with cost). Both the current flat grid format
  (`stat_energy_from`/`stat_energy_to` on the source) and the older
  `flow_from`/`flow_to` lists are read.

  Home use is `grid in + solar + battery out - grid out - battery in`.
  Self-sufficiency is the share of home use not taken from the grid;
  solar self-use is the share of solar not sent to the grid.
  """

  @energy_kinds [:grid_in, :grid_out, :solar, :battery_out, :battery_in]
  @kinds @energy_kinds ++ [:gas, :water, :grid_cost, :compensation, :gas_cost, :water_cost]

  @type kind ::
          :grid_in
          | :grid_out
          | :solar
          | :battery_out
          | :battery_in
          | :gas
          | :water
          | :grid_cost
          | :compensation
          | :gas_cost
          | :water_cost

  @type hour :: %{
          start: integer(),
          grid_in: float(),
          grid_out: float(),
          solar: float(),
          home: float()
        }
  @type t :: %{
          day_start: integer() | nil,
          totals: %{optional(kind() | :home) => float()},
          units: %{optional(:gas | :water) => String.t()},
          hourly: [hour()],
          self_sufficiency: float() | nil,
          solar_self_use: float() | nil,
          power_entity: String.t() | nil,
          flows: %{atom() => float()}
        }

  @doc "Statistic ids per kind, from the energy preferences."
  @spec sources(map()) :: %{kind() => [String.t()]}
  def sources(prefs) do
    pairs =
      Enum.flat_map(prefs["energy_sources"] || [], fn source ->
        flows = [source | (source["flow_from"] || []) ++ (source["flow_to"] || [])]
        Enum.flat_map(flows, &source_ids(source["type"], &1))
      end)

    pairs
    |> Enum.reject(fn {_kind, id} -> not is_binary(id) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {kind, ids} -> {kind, Enum.uniq(ids)} end)
  end

  defp source_ids("grid", flow) do
    [
      {:grid_in, flow["stat_energy_from"]},
      {:grid_out, flow["stat_energy_to"]},
      {:grid_cost, flow["stat_cost"]},
      {:compensation, flow["stat_compensation"]}
    ]
  end

  defp source_ids("solar", flow), do: [{:solar, flow["stat_energy_from"]}]

  defp source_ids("battery", flow),
    do: [{:battery_out, flow["stat_energy_from"]}, {:battery_in, flow["stat_energy_to"]}]

  defp source_ids("gas", flow),
    do: [{:gas, flow["stat_energy_from"]}, {:gas_cost, flow["stat_cost"]}]

  defp source_ids("water", flow),
    do: [{:water, flow["stat_energy_from"]}, {:water_cost, flow["stat_cost"]}]

  defp source_ids(_type, _flow), do: []

  @doc "The grid's power sensor (`stat_rate`), if one is set."
  @spec power_entity(map()) :: String.t() | nil
  def power_entity(prefs) do
    Enum.find_value(prefs["energy_sources"] || [], fn
      %{"type" => "grid", "stat_rate" => id} when is_binary(id) -> id
      _ -> nil
    end)
  end

  @doc "Every statistic id the summary needs."
  @spec statistic_ids(map()) :: [String.t()]
  def statistic_ids(prefs),
    do: prefs |> sources() |> Map.values() |> List.flatten() |> Enum.uniq()

  @doc """
  The day to show: the newest `period: "day"` bucket start in `day_stats`
  (Home Assistant aligns day buckets to its local midnight), or `nil`.
  """
  @spec day_start(map()) :: integer() | nil
  def day_start(day_stats) do
    day_stats
    |> Map.values()
    |> List.flatten()
    |> Enum.map(& &1["start"])
    |> Enum.max(fn -> nil end)
  end

  @doc """
  Sum up today. `day_stats` and `hour_stats` are `statistics_during_period`
  results (`types: ["change"]`, energy in kWh); `units` maps statistic ids
  to their unit (for gas and water).
  """
  @spec summarize(map(), map(), map(), %{String.t() => String.t()}) :: t()
  def summarize(prefs, day_stats, hour_stats, units \\ %{}) do
    sources = sources(prefs)
    start = day_start(day_stats)

    totals =
      for kind <- @kinds, Map.has_key?(sources, kind), into: %{} do
        {kind, sources[kind] |> Enum.map(&day_change(day_stats[&1], start)) |> Enum.sum()}
      end

    totals = if any_energy?(sources), do: Map.put(totals, :home, home(totals)), else: totals

    %{
      day_start: start,
      totals: totals,
      units: unit_names(sources, units),
      hourly: hourly(sources, hour_stats),
      self_sufficiency: ratio(totals[:home], totals[:home], Map.get(totals, :grid_in, 0.0)),
      solar_self_use: ratio(totals[:solar], totals[:solar], Map.get(totals, :grid_out, 0.0)),
      power_entity: power_entity(prefs),
      flows: flows(totals)
    }
  end

  @doc """
  How today's energy moved between the systems, as Home Assistant's energy
  distribution card splits it: what went to the grid came from solar first,
  then the battery; what charged the battery came from solar first, then the
  grid; the rest of each source went to the home.
  """
  @spec flows(map()) :: %{atom() => float()}
  def flows(totals) do
    get = &Map.get(totals, &1, 0.0)
    solar_to_grid = Kernel.min(get.(:grid_out), get.(:solar))
    solar_left = get.(:solar) - solar_to_grid
    solar_to_battery = Kernel.min(get.(:battery_in), solar_left)
    grid_to_battery = Kernel.max(0.0, get.(:battery_in) - solar_to_battery)
    battery_to_grid = Kernel.max(0.0, get.(:grid_out) - solar_to_grid)

    %{
      solar_to_home: Kernel.max(0.0, solar_left - solar_to_battery),
      solar_to_grid: solar_to_grid,
      solar_to_battery: solar_to_battery,
      grid_to_home: Kernel.max(0.0, get.(:grid_in) - grid_to_battery),
      grid_to_battery: grid_to_battery,
      battery_to_home: Kernel.max(0.0, get.(:battery_out) - battery_to_grid),
      battery_to_grid: battery_to_grid
    }
  end

  defp any_energy?(sources), do: Enum.any?(@energy_kinds, &Map.has_key?(sources, &1))

  defp day_change(nil, _start), do: 0.0

  defp day_change(rows, start) do
    case Enum.find(rows, &(&1["start"] == start)) do
      %{"change" => change} when is_number(change) -> change * 1.0
      _ -> 0.0
    end
  end

  defp home(totals) do
    get = &Map.get(totals, &1, 0.0)

    Kernel.max(
      0.0,
      get.(:grid_in) + get.(:solar) + get.(:battery_out) - get.(:grid_out) - get.(:battery_in)
    )
  end

  # (whole - part) / whole, clamped to 0..1; nil without a whole.
  defp ratio(nil, _whole, _part), do: nil
  defp ratio(_, whole, _part) when whole <= 0, do: nil
  defp ratio(_, whole, part), do: ((whole - part) / whole) |> Kernel.max(0.0) |> Kernel.min(1.0)

  defp unit_names(sources, units) do
    for kind <- [:gas, :water],
        [id | _] <- [Map.get(sources, kind, [])],
        unit = units[id],
        into: %{},
        do: {kind, unit}
  end

  # Energy per hour of the day, kWh, oldest first.
  defp hourly(sources, hour_stats) do
    per_kind =
      Map.new([:grid_in, :grid_out, :solar, :battery_out, :battery_in], fn kind ->
        rows = Enum.flat_map(Map.get(sources, kind, []), &Map.get(hour_stats, &1, []))
        {kind, Enum.group_by(rows, & &1["start"], &((&1["change"] || 0) * 1.0))}
      end)

    starts =
      per_kind |> Map.values() |> Enum.flat_map(&Map.keys/1) |> Enum.uniq() |> Enum.sort()

    for start <- starts do
      get = fn kind -> per_kind[kind] |> Map.get(start, []) |> Enum.sum() end
      totals = Map.new([:grid_in, :grid_out, :solar, :battery_out, :battery_in], &{&1, get.(&1)})

      %{
        start: start,
        grid_in: totals.grid_in,
        grid_out: totals.grid_out,
        solar: totals.solar,
        home: home(totals)
      }
    end
  end
end
