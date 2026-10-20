defmodule HomeFrame.App do
  @moduledoc """
  The Solve application: HomeFrame's state, as a graph of controllers.

  | Controller | Exposes |
  |---|---|
  | `:settings` | settings without credentials, file status |

  Outside processes (the settings watcher, the orientation sensor, the
  Immich cache, the Home Assistant connection) feed it with
  `Solve.dispatch/4`; the viewport subscribes with `Solve.Lookup`.
  """
  use Solve

  @impl Solve
  def controllers do
    [
      controller!(name: :settings, module: HomeFrame.App.Settings)
    ]
  end
end
