defmodule PictureRail.View.Supervisor do
  @moduledoc """
  The viewport under its own restart budget.

  The viewport talks to native code (DRM, GPU, input) and is the part most
  likely to crash-loop. Under this supervisor, a viewport that keeps
  failing (more than 3 restarts in 30 s) ends only this subtree, which the
  root doesn't restart (`:temporary`): the slideshow cache, Home Assistant
  and the rest keep running, and the frame stays reachable over SSH.

  The viewport gets 5 s to shut down (Emerge's default is `:infinity`,
  which would hold up the whole tree's teardown on it).
  """
  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The root's child spec for it: `:temporary`, so giving up is final."
  @spec root_child(keyword()) :: Supervisor.child_spec()
  def root_child(opts \\ []), do: Supervisor.child_spec({__MODULE__, opts}, restart: :temporary)

  @impl Supervisor
  def init(opts) do
    children = [Supervisor.child_spec({PictureRail.View, opts}, shutdown: 5_000)]
    Supervisor.init(children, strategy: :one_for_one, max_restarts: 3, max_seconds: 30)
  end
end
