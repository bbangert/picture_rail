defmodule HomeFrame.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      HomeFrame.Hardware.impl().children() ++
        [
          {Task.Supervisor, name: HomeFrame.TaskSup},
          HomeFrame.Settings.Watcher,
          {HomeFrame.App, name: HomeFrame.App},
          HomeFrame.Immich.Cache,
          HomeFrame.HA.Supervisor
        ] ++ view()

    Supervisor.start_link(children, strategy: :one_for_one, name: HomeFrame.Supervisor)
  end

  # Started last, once the state it renders exists, under its own restart
  # budget (`HomeFrame.View.Supervisor`). Devices can leave it to be started
  # by hand (`HomeFrame.View.start/1`) while a new viewport is being tried
  # out.
  defp view do
    if Application.get_env(:homeframe, :start_view, true),
      do: [HomeFrame.View.Supervisor.root_child()],
      else: []
  end
end
