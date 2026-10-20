defmodule HomeFrame.HAFixture do
  @moduledoc """
  A small Home Assistant home (test/fixtures/ha/home.json, registry and
  state JSON in HA's own format) loaded into a model table, for tests of
  the index, the overview and the `:ha` controller.
  """

  alias Hassock.{EntityState, Registries}
  alias HomeFrame.HA.{Index, Model}

  @path Path.expand("../fixtures/ha/home.json", __DIR__)

  @doc "The registries, decoded the way hassock decodes them."
  def registries do
    json = json()

    %{
      floor: Enum.map(json["floors"], &Registries.decode(:floor, &1)),
      area: Enum.map(json["areas"], &Registries.decode(:area, &1)),
      device: Enum.map(json["devices"], &Registries.decode(:device, &1)),
      entity: Enum.map(json["entities"], &Registries.decode(:entity, &1))
    }
  end

  @doc "Entity states by id."
  def states do
    Map.new(json()["states"], fn s ->
      {s["entity_id"],
       %EntityState{entity_id: s["entity_id"], state: s["state"], attributes: s["attributes"]}}
    end)
  end

  @doc "The fixture's index."
  def index, do: Index.build(registries(), Map.keys(states()))

  @doc """
  A fresh model table holding the fixture, and a source reading it with
  `states` (default: the fixture's) for the entity states.
  """
  def source(states \\ states()) do
    table = :ets.new(:"ha_fixture_#{System.unique_integer([:positive])}", [:named_table, :public])
    Model.store(table, index(), 1)
    %{table: table, state: &Map.get(states, &1)}
  end

  defp json, do: @path |> File.read!() |> Jason.decode!()
end
