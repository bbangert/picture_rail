defmodule PictureRail.App.Slideshow do
  @moduledoc """
  `:slideshow` controller: which photo is on screen and which one is
  fading out.

  Every `slideshow.interval_ms` it takes the next photo through the
  `:next_photo` callback (`PictureRail.Immich.Cache.next/1`, which never
  waits). The previous photo stays exposed for the length of the fade
  (`slideshow.fade_ms`) plus a margin, so the view can crossfade. While the
  panel is up the slideshow doesn't advance; it carries on at the next tick
  after the panel hides.

  Exposes `%{current: photo | nil, previous: photo | nil, index: n, fade_ms: ms}`
  where a photo is `%{path:, id:, portrait?:}` and `index` counts photos
  shown (the view keys each photo's layer on it).
  """
  use Solve.Controller, events: []

  # How soon to look again while there's nothing to show yet.
  @empty_retry_ms 2_000
  @fade_margin_ms 200

  @impl Solve.Controller
  def init(_params, _dependencies) do
    send(self(), :tick)
    %{current: nil, previous: nil, index: 0, timer: nil, clear: nil}
  end

  def handle_info(:tick, state, deps, callbacks), do: tick(state, deps, callbacks)

  def handle_info({:clear_previous, index}, %{index: index} = state, _deps, _callbacks),
    do: %{state | previous: nil}

  def handle_info(_message, state, _deps, _callbacks), do: state

  @doc false
  # Show the next photo, unless the panel is up or there's none yet.
  @spec tick(map(), map(), map()) :: map()
  def tick(state, deps, callbacks) do
    %{interval_ms: interval, fade_ms: fade} = timings(deps)

    if panel_visible?(deps) do
      schedule(state, interval)
    else
      state = advance(state, callbacks.next_photo.(), fade)
      schedule(state, if(state.current, do: interval, else: @empty_retry_ms))
    end
  end

  defp advance(state, {:ok, entry}, fade) do
    photo = to_photo(entry)

    if state.current && photo.path == state.current.path do
      state
    else
      index = state.index + 1
      Process.send_after(self(), {:clear_previous, index}, fade + @fade_margin_ms)
      %{state | current: photo, previous: state.current, index: index}
    end
  end

  defp advance(state, :none, _fade), do: state

  defp schedule(state, ms) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :tick, ms)}
  end

  defp to_photo(%{asset: asset, path: path}) do
    portrait? =
      is_integer(asset.width) and is_integer(asset.height) and asset.height > asset.width

    %{path: path, id: asset.id, portrait?: portrait?}
  end

  defp panel_visible?(%{panel: %{visible?: true}}), do: true
  defp panel_visible?(_deps), do: false

  defp timings(%{settings: %{settings: %{slideshow: slideshow}}}), do: slideshow
  defp timings(_deps), do: PictureRail.Settings.defaults().slideshow

  @impl Solve.Controller
  def expose(state, deps, _params) do
    %{
      current: state.current,
      previous: state.previous,
      index: state.index,
      fade_ms: timings(deps).fade_ms
    }
  end
end
