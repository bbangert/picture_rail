defmodule PictureRail.App do
  @moduledoc """
  The Solve application: Picture Rail's state, as a graph of controllers.

  | Controller | Exposes |
  |---|---|
  | `:settings` | settings without credentials, file status |
  | `:orientation` | the UI's orientation and rotation |
  | `:panel` | whether the panel is up, its view, the idle timeout |
  | `:photos` | the photo source's status and counts |
  | `:slideshow` | the photo on screen and the one fading out |
  | `:setup` | the Setup page's editor |
  | `:network` | Wi-Fi status, networks around, a join on trial |
  | `:ha` | Home Assistant status and the panel view's slice of the model |

  Outside processes (the settings watcher, the orientation sensor, the
  photo source, the Home Assistant connection) feed it with
  `Solve.dispatch/4`; the viewport subscribes with `Solve.Lookup`.
  """
  use Solve

  alias PictureRail.Settings.Watcher

  @impl Solve
  def controllers do
    [
      controller!(name: :settings, module: PictureRail.App.Settings),
      controller!(name: :orientation, module: PictureRail.App.Orientation),
      controller!(name: :network, module: PictureRail.App.Network),
      controller!(
        name: :setup,
        module: PictureRail.App.Setup,
        dependencies: [:settings, :network],
        callbacks: %{
          run: &run_task/1,
          stored: &stored/1,
          save: &Watcher.update/1,
          join: &PictureRail.Network.join/3,
          wifi_watch: &wifi_watch/0
        }
      ),
      controller!(
        name: :panel,
        module: PictureRail.App.Panel,
        dependencies: [:settings, :setup]
      ),
      controller!(name: :photos, module: PictureRail.App.Photos),
      controller!(
        name: :slideshow,
        module: PictureRail.App.Slideshow,
        dependencies: [:settings, :panel],
        callbacks: %{next_photo: &next_photo/0}
      ),
      controller!(
        name: :ha,
        module: PictureRail.App.HA,
        dependencies: [:panel],
        callbacks: %{call_service: &call_service/1}
      )
    ]
  end

  # Runs from the `:ha` controller, which gets the task's reply.
  defp call_service(%{domain: domain, service: service, entity_id: entity_id} = request) do
    call = %Hassock.ServiceCall{
      domain: domain,
      service: service,
      target: %{entity_id: entity_id},
      service_data: Map.get(request, :data, %{})
    }

    Task.Supervisor.async_nolink(PictureRail.TaskSup, fn ->
      Hassock.call_service(PictureRail.HA.Connection, call)
    end)
  end

  # Setup's slow work (talking to a photo source, saving); the `:setup`
  # controller gets the task's reply.
  defp run_task(fun), do: Task.Supervisor.async_nolink(PictureRail.TaskSup, fun)

  defp wifi_watch do
    if Process.whereis(PictureRail.Network), do: PictureRail.Network.watch()
    :ok
  end

  # A saved section with its credentials, read inside those tasks only.
  defp stored(name), do: PictureRail.Settings.values(PictureRail.Settings.current(), name)

  # The source never waits on the network; if none is running, there's
  # nothing to show.
  defp next_photo, do: PictureRail.PhotoSource.next()
end
