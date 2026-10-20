defmodule HomeFrame.View.SupervisorTest do
  use ExUnit.Case, async: true

  test "the viewport has its own restart budget and a bounded shutdown" do
    {:ok, {flags, [view]}} = HomeFrame.View.Supervisor.init(spike: true)
    assert %{strategy: :one_for_one, intensity: 3, period: 30} = flags
    assert %{id: HomeFrame.View, shutdown: 5_000} = view
  end

  test "the root won't restart it once it gives up" do
    assert %{restart: :temporary, type: :supervisor} = HomeFrame.View.Supervisor.root_child()
  end
end
