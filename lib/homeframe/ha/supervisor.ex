defmodule HomeFrame.HA.Supervisor do
  @moduledoc """
  The Home Assistant side: a dynamic supervisor for the hassock connection
  (started and replaced by `HomeFrame.HA.Model` as the settings change),
  then the model itself. `rest_for_one`, so a restarted connection
  supervisor restarts the model that owns it.
  """
  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Supervisor
  def init(opts) do
    children = [
      {DynamicSupervisor, name: HomeFrame.HA.ConnSup, strategy: :one_for_one},
      {HomeFrame.HA.Model, opts}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
