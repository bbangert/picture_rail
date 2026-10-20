defmodule PictureRail.HA.ModelTest do
  use ExUnit.Case, async: true

  alias Hassock.EntityState
  alias PictureRail.HA.Model
  alias PictureRail.{HAFixture, Settings}

  @ha %Settings.HomeAssistant{url: "http://ha.example:8123", token: "secret-token"}

  setup do
    test = self()
    table = :"ha_model_#{System.unique_integer([:positive])}"
    settings = start_supervised!({Agent, fn -> %Settings{home_assistant: @ha} end})

    opts = [
      name: nil,
      table: table,
      app: nil,
      rebuild_ms: 10,
      states_flush_ms: 10,
      restart_ms: 20,
      settings: fn -> Agent.get(settings, & &1) end,
      notify: &send(test, {:notify, &1}),
      registries: fn _opts -> HAFixture.registries() end,
      state_ids: fn _opts -> Map.keys(HAFixture.states()) end,
      start_hassock: fn ha, _opts ->
        pid = spawn(fn -> Process.sleep(:infinity) end)
        send(test, {:started, ha, pid})
        {:ok, pid}
      end
    ]

    model = start_supervised!({Model, opts})
    %{model: model, table: table}
  end

  test "starts hassock for the configured server, and builds once both caches are ready",
       %{model: model, table: table} do
    assert_receive {:started, @ha, _pid}
    assert_receive {:notify, {:status, :connecting}}
    assert Model.status(table) == :connecting

    send(model, {:hassock_registry, self(), :ready})
    refute_receive {:notify, {:model, _}}, 50

    send(model, {:hassock_cache, self(), :ready})
    assert_receive {:notify, {:status, :connected}}
    assert_receive {:notify, {:model, 1}}

    assert [%{floor: %{floor_id: "ground"}} | _] = Model.floors(table)
    assert %{area: %{name: "Kitchen"}} = Model.area("kitchen", table)
    assert Model.revision(table) == 1
  end

  test "state changes are passed on; only added or removed entities rebuild",
       %{model: model} do
    send(model, {:hassock_registry, self(), :ready})
    send(model, {:hassock_cache, self(), :ready})
    assert_receive {:notify, {:model, 1}}

    changed = %EntityState{entity_id: "light.ceiling", state: "off"}

    send(
      model,
      {:hassock_cache, self(),
       {:changes, %{added: [], changed: [{"light.ceiling", changed}], removed: []}}}
    )

    assert_receive {:notify, {:states, ["light.ceiling"]}}
    refute_receive {:notify, {:model, _}}, 50

    send(
      model,
      {:hassock_cache, self(), {:changes, %{added: [], changed: [], removed: ["sun.sun"]}}}
    )

    send(model, {:hassock_registry, self(), {:changed, :area}})
    # a burst costs one rebuild
    assert_receive {:notify, {:model, 2}}
    refute_receive {:notify, {:model, 3}}, 50
  end

  test "state changes reach the controller as one batch", %{model: model} do
    es = %EntityState{entity_id: "x", state: "on"}

    for id <- ["light.b", "light.a", "light.b"] do
      send(
        model,
        {:hassock_cache, self(), {:changes, %{added: [], changed: [{id, es}], removed: []}}}
      )
    end

    assert_receive {:notify, {:states, ["light.a", "light.b"]}}
    refute_receive {:notify, {:states, _}}, 50
  end

  test "readiness goes with the cache that reported it", %{model: model} do
    registries = spawn(fn -> Process.sleep(:infinity) end)
    states = spawn(fn -> Process.sleep(:infinity) end)
    send(model, {:hassock_registry, registries, :ready})
    send(model, {:hassock_cache, states, :ready})
    assert_receive {:notify, {:model, 1}}

    # hassock replaced its registry cache: no rebuild against the new,
    # still empty one until it reports ready itself
    ref = Process.monitor(registries)
    Process.exit(registries, :kill)
    assert_receive {:DOWN, ^ref, :process, _, :killed}

    send(
      model,
      {:hassock_cache, states, {:changes, %{added: [{"x.y", nil}], changed: [], removed: []}}}
    )

    refute_receive {:notify, {:model, _}}, 50

    send(model, {:hassock_registry, spawn(fn -> Process.sleep(:infinity) end), :ready})
    assert_receive {:notify, {:model, 2}}
  end

  test "disconnects and a refused token are reported", %{model: model, table: table} do
    send(model, {:hassock_cache, self(), :disconnected})
    assert_receive {:notify, {:status, :disconnected}}

    send(model, {:hassock_cache, self(), {:auth_failed, "invalid"}})
    assert_receive {:notify, {:status, {:auth_failed, "invalid"}}}
    assert Model.status(table) == {:auth_failed, "invalid"}
  end

  test "a stopped hassock is restarted", %{model: _model} do
    assert_receive {:started, @ha, pid}
    Process.exit(pid, :kill)

    assert_receive {:notify, {:status, :disconnected}}
    assert_receive {:started, @ha, _pid}, 500
    assert_receive {:notify, {:status, :connecting}}
  end

  test "the token stays out of the config's inspect" do
    config = Model.config(@ha)
    assert config.ssl_options == nil
    refute inspect(config) =~ "secret-token"

    assert Model.config(%{@ha | ssl_verify: false}).ssl_options == [verify: :verify_none]
  end
end
