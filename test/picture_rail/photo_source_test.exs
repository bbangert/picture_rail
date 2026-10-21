defmodule PictureRail.PhotoSourceTest do
  use ExUnit.Case, async: true

  alias PictureRail.PhotoSource
  alias PictureRail.Settings

  # A source whose process hands out one photo and reports its config.
  defmodule FakeSource do
    @behaviour PhotoSource
    use Agent

    @impl PhotoSource
    def type, do: "fake"
    @impl PhotoSource
    def label, do: "Fake"
    @impl PhotoSource
    def fields, do: []
    @impl PhotoSource
    def validate(config), do: {:ok, config}
    @impl PhotoSource
    def choices(_key, _config), do: {:ok, []}
    @impl PhotoSource
    def check(_config), do: :ok

    @impl PhotoSource
    def child_spec(opts),
      do: %{
        id: __MODULE__,
        start: {Agent, :start_link, [fn -> opts[:config] end, [name: opts[:name]]]}
      }

    @impl PhotoSource
    def next(server),
      do:
        {:ok, %{id: Agent.get(server, & &1["photo"]), path: "/p", width: 1, height: 1, clip: nil}}

    @impl PhotoSource
    def stats(_server),
      do: %{status: :online, photos: 1, ready: 1, window: 1, downloading?: false}
  end

  # Another type, so swapping can be seen.
  defmodule OtherSource do
    @behaviour PhotoSource

    defdelegate fields(), to: FakeSource
    defdelegate validate(config), to: FakeSource
    defdelegate choices(key, config), to: FakeSource
    defdelegate check(config), to: FakeSource
    defdelegate child_spec(opts), to: FakeSource
    defdelegate next(server), to: FakeSource
    defdelegate stats(server), to: FakeSource

    def type, do: "other"
    def label, do: "Other"
  end

  defp source(module, photo),
    do: %Settings{
      photo_source: %Settings.PhotoSource{module: module, config: %{"photo" => photo}}
    }

  setup do
    {:ok, settings} = Agent.start_link(fn -> Settings.defaults() end)
    name = :"photo_sources_#{System.unique_integer([:positive])}"
    registry = Module.concat(name, Registry)

    start_supervised!(
      {PhotoSource.Supervisor,
       name: name, registry: registry, app: nil, settings: fn -> Agent.get(settings, & &1) end}
    )

    set = fn value ->
      Agent.update(settings, fn _ -> value end)
      PhotoSource.Supervisor.refresh(name)
    end

    %{set: set, registry: registry, sup: name, manager: Module.concat(name, PhotoSource.Manager)}
  end

  test "nothing configured: no photo, unconfigured stats", %{registry: registry} do
    assert PhotoSource.active(registry) == nil
    assert PhotoSource.next(registry) == :none
    assert PhotoSource.stats(registry) == PhotoSource.unconfigured_stats()
  end

  test "starts the configured source and dispatches to it", %{set: set, registry: registry} do
    set.(source(FakeSource, "a"))
    assert {pid, FakeSource} = PhotoSource.active(registry)
    assert {:ok, %{id: "a"}} = PhotoSource.next(registry)
    assert %{status: :online} = PhotoSource.stats(registry)

    # the same type stays running (it follows its settings itself)
    set.(source(FakeSource, "b"))
    assert {^pid, FakeSource} = PhotoSource.active(registry)
  end

  test "swaps the source when the type changes, stops it when removed", %{
    set: set,
    registry: registry
  } do
    set.(source(FakeSource, "a"))
    {pid, FakeSource} = PhotoSource.active(registry)
    ref = Process.monitor(pid)

    set.(source(OtherSource, "b"))
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    assert {_pid, OtherSource} = PhotoSource.active(registry)
    assert {:ok, %{id: "b"}} = PhotoSource.next(registry)

    set.(Settings.defaults())
    assert PhotoSource.active(registry) == nil
    assert PhotoSource.next(registry) == :none
  end

  test "a restarted manager takes over the running source", %{
    set: set,
    registry: registry,
    sup: sup,
    manager: manager
  } do
    set.(source(FakeSource, "a"))
    {pid, FakeSource} = PhotoSource.active(registry)

    manager_pid = Process.whereis(manager)
    ref = Process.monitor(manager_pid)
    Process.exit(manager_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^manager_pid, :killed}
    # the supervisor has handled the exit, and started a new one
    assert {_, new_pid, _, _} =
             List.keyfind(Supervisor.which_children(sup), PhotoSource.Manager, 0)

    assert is_pid(new_pid) and new_pid != manager_pid

    # the same source, kept; then swapped as usual
    set.(source(FakeSource, "b"))
    assert {^pid, FakeSource} = PhotoSource.active(registry)
    set.(source(OtherSource, "c"))
    assert {_other, OtherSource} = PhotoSource.active(registry)
    refute Process.alive?(pid)
  end

  test "module lookup by type" do
    assert PhotoSource.module_for("immich") == {:ok, PictureRail.Immich.Source}
    assert PhotoSource.module_for("nope") == :error
    assert PhotoSource.types() == ["immich"]
    assert PhotoSource.status_message(FakeSource, :weird) == nil
  end
end
