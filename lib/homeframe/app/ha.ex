defmodule HomeFrame.App.HA do
  @moduledoc """
  `:ha` controller: Home Assistant's connection status, the model revision,
  and, while the panel is up, the slice of the model its view shows.

  Events from `HomeFrame.HA.Model`:

    * `:status` - the connection status
    * `:model` - a new model revision
    * `:states` - ids of entities whose state changed; the slice is
      recomputed only if one of them is on screen

  From the view:

    * `:call` - `%{domain:, service:, entity_id:, data: map, optimistic: state | nil}`.
      The call runs in a task (the `:call_service` callback). With
      `optimistic`, the entity shows that state at once, until Home
      Assistant reports a change, the call fails (rolled back, and
      `error` set), or 10 s pass.

  Exposes `%{status:, revision:, view:, slice:, states:, error:}`. `slice`
  is `HomeFrame.HA.Overview`'s result for the panel's view (`nil` while the
  panel is down); `states` maps each entity id in it to its state, with
  pending optimistic states applied. Disconnected, everything stays, and
  `status` tells the view to grey it out.
  """
  use Solve.Controller, events: [:status, :model, :states, :call]

  require Logger

  alias HomeFrame.HA.{Model, Overview}

  @optimistic_ms 10_000

  @impl Solve.Controller
  def init(_params, _dependencies) do
    # From ETS: the model may itself be waiting on the app (subscribing).
    %{
      status: Model.status(),
      revision: Model.revision(),
      # bumped when a state on screen changes, so the slice is recomputed
      tick: 0,
      shown: nil,
      pending: %{},
      error: nil
    }
  end

  def status(status, state), do: %{state | status: status}
  def model(revision, state), do: %{state | revision: revision, shown: nil}

  def states(ids, state, deps, _callbacks, params) do
    state = settle(state, ids)
    {state, shown} = shown_ids(state, deps, params)

    if Enum.any?(ids, &MapSet.member?(shown, &1)),
      do: %{state | tick: state.tick + 1},
      else: state
  end

  def call(request, state, _deps, callbacks), do: start_call(request, state, callbacks)

  def handle_info({ref, result}, state) when is_reference(ref), do: call_done(ref, result, state)

  def handle_info({:DOWN, ref, :process, _pid, reason}, state),
    do: call_done(ref, {:error, {:crashed, reason}}, state)

  def handle_info({:expire, entity_id, ref}, state), do: expire(entity_id, ref, state)
  def handle_info(_message, state), do: state

  @doc false
  @spec start_call(map(), map(), map()) :: map()
  def start_call(request, state, callbacks) do
    %{ref: ref} = callbacks.call_service.(request)

    case Map.get(request, :optimistic) do
      nil ->
        %{state | error: nil}

      optimistic ->
        Process.send_after(self(), {:expire, request.entity_id, ref}, @optimistic_ms)
        pending = Map.put(state.pending, request.entity_id, %{state: optimistic, ref: ref})
        %{state | pending: pending, error: nil, tick: state.tick + 1}
    end
  end

  @doc false
  # A finished call: success keeps the optimistic state until HA reports
  # the change; failure rolls it back.
  @spec call_done(reference(), term(), map()) :: map()
  def call_done(ref, result, state) do
    Process.demonitor(ref, [:flush])

    case result do
      {:ok, _} ->
        state

      {:error, reason} ->
        Logger.warning("HA: service call failed: #{inspect(reason)}")
        pending = state.pending |> Enum.reject(fn {_id, p} -> p.ref == ref end) |> Map.new()
        %{state | pending: pending, error: reason, tick: state.tick + 1}
    end
  end

  defp expire(entity_id, ref, state) do
    case state.pending do
      %{^entity_id => %{ref: ^ref}} ->
        %{state | pending: Map.delete(state.pending, entity_id), tick: state.tick + 1}

      _ ->
        state
    end
  end

  # Home Assistant reported a change: its state replaces the optimistic one.
  defp settle(state, ids), do: %{state | pending: Map.drop(state.pending, ids)}

  # The entity ids on screen, cached per view and model revision.
  defp shown_ids(state, deps, params) do
    key = {view(deps), state.revision}

    case state.shown do
      {^key, ids} ->
        {state, ids}

      _ ->
        ids = state |> slice(deps, params) |> slice_ids() |> MapSet.new()
        {%{state | shown: {key, ids}}, ids}
    end
  end

  defp view(%{panel: %{visible?: true, view: view}}), do: view
  defp view(_deps), do: nil

  @doc false
  @spec slice(map(), map(), term()) :: term()
  def slice(_state, deps, params) do
    src = source(params)

    case view(deps) do
      nil -> nil
      :overview -> Overview.overview(src)
      {:area, id} -> Overview.area_view(src, id)
      :media -> Overview.media_view(src)
      :devices -> Overview.devices_view(src)
      {:entity, id} -> %{entity_id: id}
    end
  end

  defp source(%{source: src}), do: src
  defp source(_params), do: Overview.source()

  @doc "Every entity id a slice shows."
  @spec slice_ids(term()) :: [String.t()]
  def slice_ids(nil), do: []
  def slice_ids(%{entity_id: id}), do: [id]

  def slice_ids(%{summaries: summaries, floors: floors, other_areas: others}) do
    temps =
      for area <- Enum.flat_map(floors, & &1.areas) ++ others,
          id = area.area.temperature_entity_id,
          do: id

    Enum.flat_map(summaries, & &1.entity_ids) ++ temps
  end

  def slice_ids(%{sections: sections, area: area}) do
    Enum.flat_map(sections, &[Map.get(&1, :battery) | &1.entity_ids]) ++
      [area.temperature_entity_id, area.humidity_entity_id]
  end

  def slice_ids(groups) when is_list(groups),
    do: Enum.flat_map(groups, &[Map.get(&1, :battery) | &1.entity_ids])

  @impl Solve.Controller
  def expose(state, deps, params) do
    slice = slice(state, deps, params)
    src = source(params)

    states =
      for id <- slice_ids(slice), id != nil, into: %{} do
        {id, with_pending(src.state.(id), state.pending[id])}
      end

    %{
      status: state.status,
      revision: state.revision,
      view: view(deps),
      slice: slice,
      states: states,
      error: state.error
    }
  end

  defp with_pending(es, nil), do: es
  defp with_pending(nil, _pending), do: nil
  defp with_pending(es, %{state: optimistic}), do: %{es | state: optimistic}
end
