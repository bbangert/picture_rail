defmodule PictureRail.Application do
  @moduledoc false

  use Application

  alias PictureRail.HA.Picture
  alias PictureRail.Network

  @impl true
  def start(_type, _args) do
    # pictures downloaded for the panel last time aren't on screen any more
    Picture.clear()

    children =
      PictureRail.Hardware.impl().children() ++
        [
          {Task.Supervisor, name: PictureRail.TaskSup},
          PictureRail.Settings.Watcher,
          {PictureRail.App, name: PictureRail.App},
          PictureRail.PhotoSource.Supervisor
        ] ++
        network() ++
        [
          PictureRail.HA.Supervisor
        ] ++ PictureRail.Web.children() ++ view() ++ firmware_guard()

    Supervisor.start_link(children, strategy: :one_for_one, name: PictureRail.Supervisor)
  end

  # Wi-Fi (`PictureRail.Network`), and the stand-in backend on the host.
  # Tests start their own.
  defp network do
    if Application.get_env(:picture_rail, :start_network, true) do
      fake = if Network.Backend.impl() == Network.Fake, do: [Network.Fake], else: []
      fake ++ [Network]
    else
      []
    end
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

  # Validates new firmware once the viewport has run steadily (Nerves
  # targets; replaces nerves_runtime's startup guard). Last, so it only
  # starts once everything before it has.
  defp firmware_guard do
    if Application.get_env(:picture_rail, :firmware_guard, false),
      do: [PictureRail.FirmwareGuard],
      else: []
  end
end
