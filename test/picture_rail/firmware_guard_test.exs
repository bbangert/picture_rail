defmodule PictureRail.FirmwareGuardTest do
  use ExUnit.Case, async: true

  alias PictureRail.FirmwareGuard

  # A viewport stand-in whose pid the test can swap.
  defp viewport(pid) do
    {:ok, agent} = Agent.start_link(fn -> pid end)
    {agent, fn -> Agent.get(agent, & &1) end}
  end

  defp viewport_process, do: spawn_link(fn -> Process.sleep(:infinity) end)

  defp start_guard(opts) do
    test = self()

    opts =
      Keyword.merge(
        [
          name: nil,
          valid?: fn -> false end,
          validate: fn -> send(test, :validated) && :ok end,
          reboot: fn -> send(test, :rebooted) end,
          view?: true,
          steady_ms: 200,
          deadline_ms: 1_000,
          poll_ms: 10
        ],
        opts
      )

    start_supervised({FirmwareGuard, opts})
  end

  test "already-validated firmware is left alone" do
    assert {:ok, :undefined} = start_guard(valid?: fn -> true end)
    refute_receive :validated, 50
  end

  test "without a viewport at boot, it validates straight away" do
    {:ok, pid} = start_guard(view?: false, viewport: fn -> nil end)
    ref = Process.monitor(pid)
    assert_receive :validated
    # done, and gone (it may have stopped before the monitor was set up)
    assert_receive {:DOWN, ^ref, :process, ^pid, reason} when reason in [:normal, :noproc]
  end

  test "it validates once the same viewport has been up for steady_ms" do
    {_agent, get} = viewport(viewport_process())
    started = System.monotonic_time(:millisecond)
    {:ok, _} = start_guard(viewport: get)

    assert_receive :validated, 1_000
    assert System.monotonic_time(:millisecond) - started >= 200
    refute_received :rebooted
  end

  test "a replaced viewport starts the wait again" do
    {agent, get} = viewport(viewport_process())
    {:ok, _} = start_guard(viewport: get, steady_ms: 300)

    Process.sleep(200)
    replaced = System.monotonic_time(:millisecond)
    Agent.update(agent, fn _ -> viewport_process() end)

    assert_receive :validated, 1_000
    assert System.monotonic_time(:millisecond) - replaced >= 300
  end

  test "a viewport that never settles leads to a reboot, not a validation" do
    {agent, get} = viewport(viewport_process())
    {:ok, pid} = start_guard(viewport: get, deadline_ms: 400)
    ref = Process.monitor(pid)

    # a new viewport every 50 ms, then none (its supervisor gave up)
    for _ <- 1..4 do
      Process.sleep(50)
      Agent.update(agent, fn _ -> viewport_process() end)
    end

    Agent.update(agent, fn _ -> nil end)

    assert_receive :rebooted, 1_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    refute_received :validated
  end

  test "a viewport lookup that exits (its supervisor stopping) doesn't stop the guard" do
    {:ok, pid} =
      start_guard(
        viewport: fn -> exit({:shutdown, {GenServer, :call, [:view_sup, :which_children]}}) end,
        deadline_ms: 200
      )

    ref = Process.monitor(pid)
    assert_receive :rebooted, 1_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end
end
