defmodule PictureRail.HA.EnergyTest do
  use ExUnit.Case, async: true

  alias PictureRail.HA.Energy

  # The current (2025+) flat grid format, two solar sources, gas and water.
  @prefs %{
    "energy_sources" => [
      %{
        "type" => "grid",
        "stat_energy_from" => "sensor.grid_in",
        "stat_energy_to" => "sensor.grid_out",
        "stat_cost" => "sensor.grid_cost",
        "stat_rate" => "sensor.grid_power"
      },
      %{"type" => "solar", "stat_energy_from" => "sensor.solar_a"},
      %{"type" => "solar", "stat_energy_from" => "sensor.solar_b"},
      %{"type" => "gas", "stat_energy_from" => "sensor.gas", "stat_cost" => "sensor.gas_cost"},
      %{"type" => "water", "stat_energy_from" => "sensor.water"}
    ]
  }

  @yesterday 1_000_000
  @today @yesterday + 86_400_000

  defp day(changes) do
    Map.new(changes, fn {id, change} ->
      {id, [%{"start" => @yesterday, "change" => 99.0}, %{"start" => @today, "change" => change}]}
    end)
  end

  defp hour(id, changes) do
    {id,
     Enum.with_index(changes, fn change, i ->
       %{"start" => @today + i * 3_600_000, "change" => change}
     end)}
  end

  test "sources and ids from the flat grid format" do
    assert Energy.sources(@prefs) == %{
             grid_in: ["sensor.grid_in"],
             grid_out: ["sensor.grid_out"],
             grid_cost: ["sensor.grid_cost"],
             solar: ["sensor.solar_a", "sensor.solar_b"],
             gas: ["sensor.gas"],
             gas_cost: ["sensor.gas_cost"],
             water: ["sensor.water"]
           }

    assert Energy.power_entity(@prefs) == "sensor.grid_power"
  end

  test "the older flow_from/flow_to grid format" do
    prefs = %{
      "energy_sources" => [
        %{
          "type" => "grid",
          "flow_from" => [
            %{"stat_energy_from" => "sensor.in_peak"},
            %{"stat_energy_from" => "sensor.in_off"}
          ],
          "flow_to" => [%{"stat_energy_to" => "sensor.out"}]
        }
      ]
    }

    assert %{grid_in: ["sensor.in_peak", "sensor.in_off"], grid_out: ["sensor.out"]} =
             Energy.sources(prefs)
  end

  test "today's totals, home use, ratios and flows" do
    day =
      day(%{
        "sensor.grid_in" => 10.0,
        "sensor.grid_out" => 4.0,
        "sensor.grid_cost" => 2.5,
        "sensor.solar_a" => 6.0,
        "sensor.solar_b" => 2.0,
        "sensor.gas" => 3.0,
        "sensor.water" => 150.0
      })

    summary = Energy.summarize(@prefs, day, %{}, %{"sensor.water" => "gal"})

    assert summary.day_start == @today
    assert summary.totals.solar == 8.0
    # home = 10 + 8 - 4
    assert summary.totals.home == 14.0
    assert summary.units == %{water: "gal"}
    assert_in_delta summary.self_sufficiency, 4 / 14, 1.0e-9
    assert_in_delta summary.solar_self_use, 4 / 8, 1.0e-9

    assert %{solar_to_grid: 4.0, solar_to_home: 4.0, grid_to_home: 10.0, grid_to_battery: +0.0} =
             summary.flows
  end

  test "a battery is charged from solar first, and feeds the home" do
    flows =
      Energy.flows(%{grid_in: 5.0, grid_out: 1.0, solar: 6.0, battery_in: 7.0, battery_out: 3.0})

    # solar: 1 to the grid, the remaining 5 into the battery; 2 more from the grid
    assert flows == %{
             solar_to_grid: 1.0,
             solar_to_battery: 5.0,
             solar_to_home: 0.0,
             grid_to_battery: 2.0,
             grid_to_home: 3.0,
             battery_to_grid: 0.0,
             battery_to_home: 3.0
           }
  end

  test "hourly use per hour of today" do
    hours =
      Map.new([
        hour("sensor.grid_in", [1.0, 0.5]),
        hour("sensor.grid_out", [0.0, 0.3]),
        hour("sensor.solar_a", [0.0, 0.8])
      ])

    assert [%{grid_in: 1.0, home: 1.0}, %{solar: 0.8, home: home}] =
             Energy.summarize(@prefs, day(%{"sensor.grid_in" => 1.5}), hours).hourly

    assert_in_delta home, 0.5 + 0.8 - 0.3, 1.0e-9
  end

  test "no sources: no home figure, no ratios" do
    summary = Energy.summarize(%{"energy_sources" => []}, %{}, %{})
    assert summary.totals == %{}
    assert summary.self_sufficiency == nil
    assert summary.day_start == nil
  end
end
