defmodule HomeFrame.App.Immich do
  @moduledoc """
  `:immich` controller: the photo cache's status and counts, as reported
  by `HomeFrame.Immich.Cache`.

  Exposes `%{status: status, photos: n, ready: n, window: n, downloading?: boolean}`
  (see `HomeFrame.Immich.Cache` for the statuses).
  """
  use Solve.Controller, events: [:stats]

  alias HomeFrame.Immich.Cache

  @impl Solve.Controller
  def init(_params, _dependencies) do
    # A restarted controller asks the cache again.
    if Process.whereis(Cache),
      do: Cache.stats(),
      else: %{status: :unconfigured, photos: 0, ready: 0, window: 0, downloading?: false}
  end

  def stats(stats, _state), do: stats
end
