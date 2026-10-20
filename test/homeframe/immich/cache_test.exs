defmodule HomeFrame.Immich.CacheTest do
  use ExUnit.Case, async: true

  alias HomeFrame.Immich.{Album, Asset, Cache}
  alias HomeFrame.Settings

  @moduletag :tmp_dir

  # A fake Immich server: the conn is an Agent holding the albums and
  # photos, failures to inject, and a log of calls.
  defmodule Fake do
    @behaviour HomeFrame.Immich.Api

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
        if s.fail, do: {{:error, s.fail}, s}, else: {fun.(s), s}
      end)
    end

    @impl true
    def connect(_settings), do: raise("tests pass :conn")
    @impl true
    def ping(agent), do: call(agent, :ping, fn _ -> :ok end)
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
      immich: %Settings.Immich{url: "http://immich", api_key: "k", album_ids: ["a1"]},
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

  defp wait_ready(cache, n),
    do: wait(fn -> Cache.stats(cache).ready >= n and not Cache.stats(cache).downloading? end)

  defp wait(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("timed out")
      true -> Process.sleep(10) && wait(fun, tries - 1)
    end
  end

  defp jpgs(dir), do: dir |> Path.join("*.jpg") |> Path.wildcard() |> length()

  test "fills the window and refills it as photos are shown", %{tmp_dir: dir} do
    agent = Fake.start(Enum.map(1..6, &asset/1))
    {_pid, cache} = start_cache(agent, dir)

    wait_ready(cache, 3)
    assert %{status: :online, photos: 6, ready: 3, window: 3} = Cache.stats(cache)
    assert jpgs(dir) == 3

    {:ok, first} = Cache.next(cache)
    assert File.exists?(first.path)
    wait_ready(cache, 3)
    assert jpgs(dir) == 4

    # Showing the next one deletes the first and fetches another.
    {:ok, second} = Cache.next(cache)
    assert second.asset != first.asset
    wait_ready(cache, 3)
    refute File.exists?(first.path)
    assert jpgs(dir) == 4
  end

  test "next never waits: :none until a photo is downloaded", %{tmp_dir: dir} do
    agent = Fake.start([asset(1)], fail: :offline)
    {_pid, cache} = start_cache(agent, dir)
    assert Cache.next(cache) == :none
  end

  test "offline, the photos on disk keep cycling", %{tmp_dir: dir} do
    agent = Fake.start(Enum.map(1..3, &asset/1))
    {pid, cache} = start_cache(agent, dir)
    wait_ready(cache, 3)

    Fake.set(agent, &%{&1 | fail: :offline})
    send(pid, :poll_albums)
    wait(fn -> Cache.stats(cache).status == :offline end)

    shown = for _ <- 1..7, do: elem(Cache.next(cache), 1).asset.id
    assert Enum.uniq(shown) |> length() == 3
    assert Enum.take(shown, 3) == Enum.slice(shown, 3, 3)
    assert jpgs(dir) == 3
  end

  test "an album that fits in the window cycles without re-downloading", %{tmp_dir: dir} do
    agent = Fake.start(Enum.map(1..2, &asset/1))
    {_pid, cache} = start_cache(agent, dir, window: 5)
    wait_ready(cache, 2)

    for _ <- 1..6, do: {:ok, _} = Cache.next(cache)
    assert Fake.calls(agent, :download) == 2
  end

  test "the manifest brings the window back after a restart without network", %{tmp_dir: dir} do
    agent = Fake.start(Enum.map(1..4, &asset/1))
    {pid, cache} = start_cache(agent, dir)
    wait_ready(cache, 3)
    stop_supervised!(cache)
    refute Process.alive?(pid)

    # One photo got corrupted, and a stray file appeared.
    [broken | _] = dir |> Path.join("*.jpg") |> Path.wildcard()
    File.write!(broken, "not a jpeg")
    File.write!(Path.join(dir, "stray.part"), "x")

    offline = Fake.start([], fail: :offline)
    {_pid, cache} = start_cache(offline, dir)
    assert %{status: :offline, ready: 2} = Cache.stats(cache)
    refute File.exists?(broken)
    refute File.exists?(Path.join(dir, "stray.part"))
    assert {:ok, %{path: path}} = Cache.next(cache)
    assert File.exists?(path)
  end

  test "albums are re-listed only when they change; removed photos go", %{tmp_dir: dir} do
    agent = Fake.start(Enum.map(1..3, &asset/1))
    {_pid, cache} = start_cache(agent, dir, album_poll_ms: 20)
    wait_ready(cache, 3)
    wait(fn -> Fake.calls(agent, :list_albums) >= 3 end)
    assert Fake.calls(agent, :list_images) == 1

    Fake.set(agent, fn s ->
      %{s | assets: [asset(1), asset(2)], album: %{s.album | asset_count: 2, updated_at: "t1"}}
    end)

    wait(fn -> Fake.calls(agent, :list_images) == 2 and Cache.stats(cache).photos == 2 end)
    wait(fn -> jpgs(dir) == 2 end)
  end

  test "a preview in an unsupported format is skipped", %{tmp_dir: dir} do
    agent =
      Fake.start(Enum.map(1..3, &asset/1),
        formats: %{"p2" => {:error, {:unsupported_format, "image/webp"}}}
      )

    {_pid, cache} = start_cache(agent, dir)
    wait_ready(cache, 2)
    assert Cache.stats(cache).ready == 2
    ids = for _ <- 1..2, do: elem(Cache.next(cache), 1).asset.id
    refute "p2" in ids
  end

  test "a revoked key is reported", %{tmp_dir: dir} do
    agent = Fake.start([asset(1)], fail: :invalid_key)
    {_pid, cache} = start_cache(agent, dir)
    assert_receive {:stats, %{status: :invalid_key}}
    assert Cache.stats(cache).status == :invalid_key
  end
end
