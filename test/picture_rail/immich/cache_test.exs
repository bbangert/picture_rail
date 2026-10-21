defmodule PictureRail.Immich.CacheTest do
  use ExUnit.Case, async: true

  alias PictureRail.Immich.{Album, Asset, Cache}
  alias PictureRail.Settings

  @moduletag :tmp_dir

  # A fake Immich server: the conn is an Agent holding the albums and
  # photos, failures to inject, and a log of calls.
  defmodule Fake do
    @behaviour PictureRail.Immich.Api

    def start(assets, opts \\ []) do
      {:ok, agent} =
        Agent.start_link(fn ->
          %{
            assets: assets,
            album: %Album{id: "a1", name: "Frame", asset_count: length(assets), updated_at: "t0"},
            fail: Keyword.get(opts, :fail),
            formats: Keyword.get(opts, :formats, %{}),
            calls: []
          }
        end)

      agent
    end

    def set(agent, fun), do: Agent.update(agent, fun)
    def calls(agent, name), do: agent |> Agent.get(& &1.calls) |> Enum.count(&(&1 == name))

    defp call(agent, name, fun) do
      Agent.get_and_update(agent, fn s ->
        s = %{s | calls: [name | s.calls]}
        if pid = Map.get(s, :notify), do: send(pid, {:fake_call, name})
        if s.fail, do: {{:error, s.fail}, s}, else: {fun.(s), s}
      end)
    end

    # A gate stands in for a server that doesn't answer: `wait/1` blocks
    # until the test calls `release/1` (before or after), and the test is
    # told `:gate_waiting` when a caller is held.
    def gate do
      test = self()
      spawn_link(fn -> gate_loop(test, []) end)
    end

    def release(gate), do: send(gate, :release)

    defp gate_loop(test, waiting) do
      receive do
        {:wait, pid} ->
          send(test, :gate_waiting)
          gate_loop(test, [pid | waiting])

        :release ->
          Enum.each(waiting, &send(&1, :go))
          gate_open()
      end
    end

    defp gate_open do
      receive do
        {:wait, pid} ->
          send(pid, :go)
          gate_open()
      end
    end

    defp wait(gate) do
      send(gate, {:wait, self()})
      receive(do: (:go -> :ok))
    end

    @impl true
    def connect(_settings), do: raise("tests pass :conn")
    @impl true
    def ping(agent) do
      if Agent.get(agent, &Map.get(&1, :raise)), do: raise("boom")

      # A gate: an agent that answers only once the test sends it :release,
      # standing in for a server that doesn't answer.
      case Agent.get(agent, &Map.get(&1, :gate)) do
        nil -> :ok
        gate -> wait(gate)
      end

      call(agent, :ping, fn _ -> :ok end)
    end

    @impl true
    def version(agent), do: call(agent, :version, fn _ -> {:ok, {3, 3, 1}} end)
    @impl true
    def list_albums(agent), do: call(agent, :list_albums, &{:ok, [&1.album]})
    @impl true
    def list_album_images(agent, ["a1"], _v), do: call(agent, :list_images, &{:ok, &1.assets})

    @impl true
    def download_preview(agent, id, path) do
      result = call(agent, :download, fn s -> Map.get(s.formats, id, :ok) end)
      if result == :ok, do: File.write!(path, <<0xFF, 0xD8, 0xFF, "photo ", id::binary>>)
      result
    end

    @impl true
    def download_clip(_agent, _id, path), do: File.write!(path, "clip")
  end

  defp asset(n), do: %Asset{id: "p#{n}", checksum: Base.encode64("sum#{n}"), width: 4, height: 3}

  defp settings(window) do
    %Settings{
      photo_source: %Settings.PhotoSource{
        module: PictureRail.Immich.Source,
        config: %{
          "url" => "http://immich",
          "api_key" => "k",
          "album_ids" => ["a1"],
          "album_names" => []
        }
      },
      cache: %{window: window, include_live_photos: true}
    }
  end

  defp start_cache(agent, dir, opts \\ []) do
    test = self()
    window = Keyword.get(opts, :window, 3)

    opts =
      [
        name: :"cache_#{System.unique_integer([:positive])}",
        api: Fake,
        conn: agent,
        dir: dir,
        settings: fn -> settings(window) end,
        notify: &send(test, {:stats, &1}),
        app: nil,
        backoff_initial_ms: 20,
        backoff_max_ms: 40,
        album_poll_ms: Keyword.get(opts, :album_poll_ms, 60_000)
      ]

    pid = start_supervised!({Cache, opts}, id: opts[:name])
    {pid, opts[:name]}
  end

  # The cache reports every change of its stats (`notify`): wait for one
  # that matches.
  defp await_stats(fun, timeout \\ 2_000) do
    receive do
      {:stats, stats} -> if fun.(stats), do: stats, else: await_stats(fun, timeout)
    after
      timeout -> flunk("no matching stats")
    end
  end

  defp wait_ready(n), do: await_stats(&(&1.ready >= n and not &1.downloading?))

  defp jpgs(dir), do: dir |> Path.join("*.jpg") |> Path.wildcard() |> length()

  test "fills the window and refills it as photos are shown", %{tmp_dir: dir} do
    agent = Fake.start(Enum.map(1..6, &asset/1))
    {_pid, cache} = start_cache(agent, dir)

    wait_ready(3)
    assert %{status: :online, photos: 6, ready: 3, window: 3} = Cache.stats(cache)
    assert jpgs(dir) == 3

    {:ok, first} = Cache.next(cache)
    assert File.exists?(first.path)
    wait_ready(3)
    assert jpgs(dir) == 4

    # Showing the next one deletes the first and fetches another.
    {:ok, second} = Cache.next(cache)
    assert second.asset != first.asset
    wait_ready(3)
    refute File.exists?(first.path)
    assert jpgs(dir) == 4
  end

  test "next and stats answer while Immich hangs", %{tmp_dir: dir} do
    gate = Fake.gate()
    agent = Fake.start([asset(1)])
    Fake.set(agent, &Map.put(&1, :gate, gate))
    {_pid, cache} = start_cache(agent, dir)

    # the connect is stuck in ping; the cache still answers at once
    {micros, :none} = :timer.tc(fn -> Cache.next(cache) end)
    assert micros < 100_000
    assert %{status: :connecting} = Cache.stats(cache)

    Fake.release(gate)
    assert_receive {:stats, %{ready: 1, downloading?: false}}, 1_000
  end

  test "a request started before a settings change is dropped", %{tmp_dir: dir} do
    gate = Fake.gate()
    agent = Fake.start([asset(1)])
    test = self()
    Fake.set(agent, &Map.merge(&1, %{gate: gate, notify: test}))
    {pid, _cache} = start_cache(agent, dir)

    # The first connect hangs. The settings change (a new generation), and
    # the second connect starts without waiting for the first.
    assert_receive :gate_waiting
    Fake.set(agent, &Map.put(&1, :gate, nil))
    :sys.replace_state(pid, &%{&1 | immich: nil})
    send(pid, %Solve.Message{type: :update, payload: %{}})
    assert_receive {:stats, %{status: :online, ready: 1, downloading?: false}}, 1_000
    assert_received {:fake_call, :list_images}

    # The album changes; then the stale connect finishes and sees it. Applied,
    # it would re-list the album; dropped, nothing happens.
    Fake.set(agent, &%{&1 | album: %{&1.album | updated_at: "t9"}})
    Fake.release(gate)
    assert_receive {:fake_call, :list_albums}, 1_000
    refute_receive {:fake_call, :list_images}, 200
  end

  test "offline, the photos on disk keep cycling", %{tmp_dir: dir} do
    agent = Fake.start(Enum.map(1..3, &asset/1))
    {pid, cache} = start_cache(agent, dir)
    wait_ready(3)

    Fake.set(agent, &%{&1 | fail: :offline})
    send(pid, :poll_albums)
    await_stats(&(&1.status == :offline))

    shown = for _ <- 1..7, do: elem(Cache.next(cache), 1).asset.id
    assert Enum.uniq(shown) |> length() == 3
    assert Enum.take(shown, 3) == Enum.slice(shown, 3, 3)
    assert jpgs(dir) == 3
  end

  test "an album that fits in the window cycles without re-downloading", %{tmp_dir: dir} do
    agent = Fake.start(Enum.map(1..2, &asset/1))
    {_pid, cache} = start_cache(agent, dir, window: 5)
    wait_ready(2)

    for _ <- 1..6, do: {:ok, _} = Cache.next(cache)
    assert Fake.calls(agent, :download) == 2
  end

  test "the manifest brings the window back after a restart without network", %{tmp_dir: dir} do
    agent = Fake.start(Enum.map(1..4, &asset/1))
    {pid, cache} = start_cache(agent, dir)
    wait_ready(3)
    stop_supervised!(cache)
    refute Process.alive?(pid)

    # One photo got corrupted, and a stray file appeared.
    [broken | _] = dir |> Path.join("*.jpg") |> Path.wildcard()
    File.write!(broken, "not a jpeg")
    File.write!(Path.join(dir, "stray.part"), "x")

    offline = Fake.start([], fail: :offline)
    {_pid, cache} = start_cache(offline, dir)
    # the window is back before Immich has answered
    assert %{ready: 2} = Cache.stats(cache)
    assert_receive {:stats, %{status: :offline}}, 1_000
    refute File.exists?(broken)
    refute File.exists?(Path.join(dir, "stray.part"))
    assert {:ok, %{path: path}} = Cache.next(cache)
    assert File.exists?(path)
  end

  test "albums are re-listed only when they change; removed photos go", %{tmp_dir: dir} do
    agent = Fake.start(Enum.map(1..3, &asset/1))
    test = self()
    Fake.set(agent, &Map.put(&1, :notify, test))
    {_pid, _cache} = start_cache(agent, dir, album_poll_ms: 20)
    wait_ready(3)
    for _ <- 1..3, do: assert_receive({:fake_call, :list_albums}, 1_000)
    assert Fake.calls(agent, :list_images) == 1

    Fake.set(agent, fn s ->
      %{s | assets: [asset(1), asset(2)], album: %{s.album | asset_count: 2, updated_at: "t1"}}
    end)

    await_stats(&(&1.photos == 2))
    assert Fake.calls(agent, :list_images) == 2
    assert jpgs(dir) == 2
  end

  test "a photo removed from the album while on screen doesn't come round again",
       %{tmp_dir: dir} do
    # the album fits in the window, so shown photos are re-queued
    agent = Fake.start(Enum.map(1..2, &asset/1))
    {pid, cache} = start_cache(agent, dir, window: 5)
    wait_ready(2)

    {:ok, shown} = Cache.next(cache)
    gone = shown.asset.id

    # it leaves the album while on screen; the re-list can't drop it yet
    Fake.set(agent, fn s ->
      %{s | assets: Enum.reject(s.assets, &(&1.id == gone)), album: %{s.album | updated_at: "t1"}}
    end)

    send(pid, :poll_albums)
    await_stats(&(&1.photos == 1))

    ids = for _ <- 1..4, do: elem(Cache.next(cache), 1).asset.id
    refute gone in ids
    refute File.exists?(shown.path)
  end

  test "a preview in an unsupported format is skipped", %{tmp_dir: dir} do
    agent =
      Fake.start(Enum.map(1..3, &asset/1),
        formats: %{"p2" => {:error, {:unsupported_format, "image/webp"}}}
      )

    {_pid, cache} = start_cache(agent, dir)
    wait_ready(2)
    assert Cache.stats(cache).ready == 2
    ids = for _ <- 1..2, do: elem(Cache.next(cache), 1).asset.id
    refute "p2" in ids
  end

  test "a download that times out doesn't make the cache go offline", %{tmp_dir: dir} do
    agent = Fake.start(Enum.map(1..3, &asset/1), formats: %{"p2" => {:error, :offline}})
    {_pid, cache} = start_cache(agent, dir)

    await_stats(&(&1.ready >= 2))
    assert Cache.stats(cache).status == :online
    refute_received {:stats, %{status: :offline}}
  end

  test "an exception from the Immich side counts as offline, not a crash", %{tmp_dir: dir} do
    agent = Fake.start([asset(1)])
    Fake.set(agent, &Map.put(&1, :raise, true))
    {pid, _cache} = start_cache(agent, dir)

    assert_receive {:stats, %{status: :offline}}, 1_000
    assert Process.alive?(pid)
    Fake.set(agent, &Map.put(&1, :raise, false))
    await_stats(&(&1.ready == 1))
  end

  test "a revoked key is reported", %{tmp_dir: dir} do
    agent = Fake.start([asset(1)], fail: :invalid_key)
    {_pid, cache} = start_cache(agent, dir)
    assert_receive {:stats, %{status: :invalid_key}}
    assert Cache.stats(cache).status == :invalid_key
  end
end
