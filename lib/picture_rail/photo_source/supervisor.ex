defmodule PictureRail.PhotoSource.Supervisor do
  @moduledoc """
  Runs the configured photo source (`PictureRail.PhotoSource`).

  Holds the registry the running source is found through (key `:active`,
  value its module), a dynamic supervisor for the source's process, and
  `PictureRail.PhotoSource.Manager`, which starts the source of the
  configured type and swaps it when the type changes or the source is
  removed from the settings.
  """
  use Supervisor

  alias PictureRail.PhotoSource.Manager

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @doc "Check the settings again now (they're also followed through `:settings`)."
  @spec refresh(atom()) :: :ok
  def refresh(name \\ __MODULE__), do: Manager.refresh(manager(name))

  @impl Supervisor
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    registry = Keyword.get(opts, :registry, PictureRail.PhotoSource.Registry)
    sources = Module.concat(name, Sources)

    manager_opts =
      opts
      |> Keyword.take([:settings, :app])
      |> Keyword.merge(name: manager(name), registry: registry, sources: sources)

    children = [
      {Registry, keys: :unique, name: registry},
      {DynamicSupervisor, name: sources, strategy: :one_for_one},
      {Manager, manager_opts}
    ]

    # The manager's idea of what's running is only right as long as the
    # registry and the sources are the ones it started with.
    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp manager(name), do: Module.concat(name, Manager)
end
