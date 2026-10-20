defmodule PictureRail.HA.SupervisorTest do
  use ExUnit.Case, async: true

  alias PictureRail.Settings

  @ha %Settings.HomeAssistant{url: "http://ha.example:8123", token: "t"}

  # A private HA tree. Its "hassock" is an Agent registered under the
  # connection's fixed name, as the real one is.
  setup do
    test = self()
    n = System.unique_integer([:positive])
    conn = :"conn_#{n}"
    conn_sup = :"conn_sup_#{n}"

    start_hassock = fn _ha, opts ->
      spec = %{
        id: :hassock,
        start: {Agent, :start_link, [fn -> nil end, [name: opts.connection_name]]},
        restart: :temporary
      }

      result = DynamicSupervisor.start_child(opts.conn_sup, spec)
      send(test, {:hassock_started, result})
      result
    end

    sup =
      start_supervised!(
        {PictureRail.HA.Supervisor,
         name: :"ha_sup_#{n}",
         conn_sup: conn_sup,
         energy: false,
         model: [
           name: :"model_#{n}",
           table: :"ha_table_#{n}",
           app: nil,
           restart_ms: 20,
           connection_name: conn,
           settings: fn -> %Settings{home_assistant: @ha} end,
           notify: fn _ -> :ok end,
           start_hassock: start_hassock
         ]}
      )

    %{sup: sup, model: :"model_#{n}", conn: conn}
  end

  test "a new model gets a fresh connection, not the old one's leftover names", ctx do
    assert_receive {:hassock_started, {:ok, first}}

    ref = Process.monitor(Process.whereis(ctx.model))
    Process.exit(Process.whereis(ctx.model), :kill)
    assert_receive {:DOWN, ^ref, :process, _, :killed}

    # the old connection went with its model, so the new one starts cleanly
    assert_receive {:hassock_started, {:ok, second}}, 1_000
    refute second == first
    refute Process.alive?(first)
    assert Process.whereis(ctx.conn) == second
  end
end
