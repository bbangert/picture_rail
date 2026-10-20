defmodule PictureRail.FirmwareGuardTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias PictureRail.FirmwareGuard

  # Viewport stand-ins are driven by the guard's own polls, not by sleeps:
  # `polls(fun)` calls `fun` with the poll's number (1, 2, ...).
  defp polls(fun) do
    counter = :counters.new(1, [])

    fn ->
      :counters.add(counter, 1, 1)
      fun.(:counters.get(counter, 1))
    end
  end

  # The guard only compares pids, so a finished process will do.
  defp fresh_pid, do: spawn(fn -> :ok end)

  defp now, do: System.monotonic_time(:millisecond)

  defp start_guard(opts) do
    test = self()

    opts =
      Keyword.merge(
        [
          name: nil,
          valid?: fn -> false end,
          validate: fn ->
            send(test, {:validated, now()})
            :ok
          end,
          reboot: fn -> send(test, :rebooted) end,
          view?: true,
          steady_ms: 200,
          deadline_ms: 2_000,
          poll_ms: 10
        ],
        opts
      )

    start_supervised({FirmwareGuard, opts})
  end

  # It may already have stopped by the time the monitor is set up.
  defp assert_stopped(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, reason} when reason in [:normal, :noproc], 1_000
  end

  test "already-validated firmware is left alone" do
    assert {:ok, :undefined} = start_guard(valid?: fn -> true end)
    refute_receive {:validated, _}, 50
  end

  test "without a viewport at boot, it validates straight away" do
    {:ok, pid} = start_guard(view?: false, viewport: fn -> nil end)
    assert_receive {:validated, _}
    assert_stopped(pid)
  end

  test "it validates once the same viewport has been up for steady_ms" do
    viewport = fresh_pid()
    started = now()
    {:ok, pid} = start_guard(viewport: fn -> viewport end)

    assert_receive {:validated, at}, 1_000
    assert at - started >= 200
    assert_stopped(pid)
    refute_received :rebooted
  end

  test "a replaced viewport starts the wait again" do
    test = self()
    stable = fresh_pid()

    # a new viewport on each of the first 15 polls, then the same one
    viewport =
      polls(fn
        n when n <= 15 ->
          send(test, {:replaced, now()})
          fresh_pid()

        _ ->
          stable
      end)

    {:ok, _} = start_guard(viewport: viewport)

    assert_receive {:validated, at}, 1_500
    assert at - last_replacement(nil) >= 200
  end

  defp last_replacement(last) do
    receive do
      {:replaced, at} -> last_replacement(at)
    after
      0 -> last
    end
  end

  test "a viewport replaced on every poll leads to a reboot at the deadline" do
    {:ok, pid} = start_guard(viewport: polls(fn _ -> fresh_pid() end), deadline_ms: 400)

    assert_receive :rebooted, 1_500
    assert_stopped(pid)
    refute_received {:validated, _}
  end

  test "a viewport that goes away (its supervisor gave up) leads to a reboot" do
    viewport = polls(fn n -> if n <= 5, do: fresh_pid() end)
    {:ok, pid} = start_guard(viewport: viewport, deadline_ms: 400)

    assert_receive :rebooted, 1_500
    assert_stopped(pid)
    refute_received {:validated, _}
  end

  test "a viewport lookup that exits (its supervisor stopping) doesn't stop the guard" do
    lookup = fn -> exit({:shutdown, {GenServer, :call, [:view_sup, :which_children]}}) end

    log =
      capture_log(fn ->
        {:ok, pid} = start_guard(viewport: lookup, deadline_ms: 200)
        assert_receive :rebooted, 1_500
        assert_stopped(pid)
      end)

    # logged once, not on every poll
    assert length(Regex.scan(~r/viewport lookup failed/, log)) == 1
  end

  test "a failed validation is retried" do
    test = self()
    viewport = fresh_pid()

    validate =
      polls(fn
        1 ->
          send(test, :validate_failed)
          {:error, :busy}

        _ ->
          send(test, {:validated, now()})
          :ok
      end)

    capture_log(fn ->
      {:ok, pid} = start_guard(viewport: fn -> viewport end, validate: validate, steady_ms: 50)

      assert_receive :validate_failed, 1_000
      assert_receive {:validated, _}, 1_000
      assert_stopped(pid)
    end)

    refute_received :rebooted
  end

  test "firmware validated some other way before the deadline isn't rebooted" do
    # unvalidated when the guard starts, validated by hand after that
    valid? = polls(fn n -> n > 1 end)
    {:ok, pid} = start_guard(valid?: valid?, viewport: fn -> nil end, deadline_ms: 200)

    assert_stopped(pid)
    refute_received :rebooted
    refute_received {:validated, _}
  end
end
