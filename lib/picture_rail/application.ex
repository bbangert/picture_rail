defmodule PictureRail.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      PictureRail.Hardware.impl().children() ++
        [
          {Task.Supervisor, name: PictureRail.TaskSup},
          PictureRail.Settings.Watcher,
          {PictureRail.App, name: PictureRail.App},
          PictureRail.Immich.Cache,
          PictureRail.HA.Supervisor
        ] ++ view()

    Supervisor.start_link(children, strategy: :one_for_one, name: PictureRail.Supervisor)
  end

  # Started last, once the state it renders exists, under its own restart
  # budget (`PictureRail.View.Supervisor`). Devices can leave it to be started
  # by hand (`PictureRail.View.start/1`) while a new viewport is being tried
  # out.
  defp view do
    if Application.get_env(:picture_rail, :start_view, true),
      do: [PictureRail.View.Supervisor.root_child()],
      else: []
  end
end
