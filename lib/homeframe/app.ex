defmodule HomeFrame.App do
  @moduledoc """
  The Solve application: HomeFrame's state, as a graph of controllers.

  | Controller | Exposes |
  |---|---|
  | `:settings` | settings without credentials, file status |
  | `:orientation` | the UI's orientation and rotation |
  | `:panel` | whether the panel is up, its view, the idle timeout |
  | `:immich` | photo cache status and counts |
  | `:slideshow` | the photo on screen and the one fading out |

  Outside processes (the settings watcher, the orientation sensor, the
  Immich cache, the Home Assistant connection) feed it with
  `Solve.dispatch/4`; the viewport subscribes with `Solve.Lookup`.
  """
  use Solve

  alias HomeFrame.Immich.Cache

  @impl Solve
  def controllers do
    [
      controller!(name: :settings, module: HomeFrame.App.Settings),
      controller!(name: :orientation, module: HomeFrame.App.Orientation),
      controller!(name: :panel, module: HomeFrame.App.Panel, dependencies: [:settings]),
      controller!(name: :immich, module: HomeFrame.App.Immich),
      controller!(
        name: :slideshow,
        module: HomeFrame.App.Slideshow,
        dependencies: [:settings, :panel],
        callbacks: %{next_photo: &next_photo/0}
      )
    ]
  end

  # The cache never waits on the network; if it isn't running, there's
  # nothing to show.
  defp next_photo do
    if Process.whereis(Cache), do: Cache.next(), else: :none
  end
end
