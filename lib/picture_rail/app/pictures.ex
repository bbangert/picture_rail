defmodule PictureRail.App.Pictures do
  @moduledoc """
  `:pictures` controller: the picture of the entity whose detail the panel
  shows (`PictureRail.HA.Picture`), downloaded while it's shown: a
  camera's snapshot every second, an image entity's image or a media
  player's artwork every 10 s, when it has changed.

  Events:

    * `:view` - the panel's view on screen (`nil`: none), from the
      panel's `:viewing` callback

  Downloads run in tasks (the `:fetch` callback). The picture before the
  current one is kept too (`previous`): the view draws it under the new
  one while that loads. Older pictures, and any that come for an entity
  no longer shown, are removed (the `:discard` callback). A failed
  download keeps the last picture.

  Exposes `%{entity_id: id | nil, path: path | nil, previous: path | nil}`.
  """
  use Solve.Controller, events: [:view]

  alias PictureRail.HA.Index

  @domains ~w(camera image media_player)
  @camera_ms 1_000
  @other_ms 10_000

  @impl Solve.Controller
  def init(_params, _dependencies), do: fresh(nil)

  # `ref`: the download running; `timer`: the next one's token
  defp fresh(entity_id),
    do: %{entity_id: entity_id, url: nil, path: nil, previous: nil, ref: nil, timer: nil}

  def view(view, state, _deps, callbacks) do
    case shown(view) do
      id when id == state.entity_id ->
        state

      nil ->
        discard_all(state, callbacks)
        fresh(nil)

      id ->
        discard_all(state, callbacks)
        fetch(fresh(id), callbacks)
    end
  end

  defp shown({:entity, id}), do: if(Index.domain(id) in @domains, do: id)
  defp shown(_view), do: nil

  def handle_info({ref, result}, %{ref: ref} = state, _deps, callbacks) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    state |> fetched(result, callbacks) |> schedule()
  end

  # from a download for an entity no longer shown
  def handle_info({ref, result}, state, _deps, callbacks) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    with {:ok, path, _url} <- result, do: callbacks.discard.(path)
    state
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{ref: ref} = state, _deps, _callbacks),
    do: schedule(state)

  def handle_info({:refresh, token}, %{timer: token} = state, _deps, callbacks),
    do: fetch(%{state | timer: nil}, callbacks)

  def handle_info(_message, state, _deps, _callbacks), do: state

  defp fetch(state, callbacks) do
    %{ref: ref} = callbacks.fetch.(state.entity_id, state.url)
    %{state | ref: ref}
  end

  defp fetched(state, {:ok, path, url}, callbacks) do
    callbacks.discard.(state.previous)
    %{state | previous: state.path, path: path, url: url}
  end

  defp fetched(state, _unchanged_or_error, _callbacks), do: state

  defp schedule(state) do
    token = make_ref()
    ms = if Index.domain(state.entity_id) == "camera", do: @camera_ms, else: @other_ms
    Process.send_after(self(), {:refresh, token}, ms)
    %{state | ref: nil, timer: token}
  end

  defp discard_all(state, callbacks) do
    callbacks.discard.(state.previous)
    callbacks.discard.(state.path)
  end

  @impl Solve.Controller
  def expose(state, _dependencies, _params),
    do: %{entity_id: state.entity_id, path: state.path, previous: state.previous}
end
