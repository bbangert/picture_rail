defmodule PictureRail.App.Photos do
  @moduledoc """
  `:photos` controller: the photo source's status and counts, as reported
  by the running source (`PictureRail.PhotoSource`).

  Exposes `%{status: status, photos: n, ready: n, window: n, downloading?: boolean}`
  (see `PictureRail.PhotoSource` for the statuses).
  """
  use Solve.Controller, events: [:stats]

  alias PictureRail.PhotoSource

  @impl Solve.Controller
  # A restarted controller asks the source again.
  def init(_params, _dependencies), do: PhotoSource.stats()

  def stats(stats, _state), do: stats
end
