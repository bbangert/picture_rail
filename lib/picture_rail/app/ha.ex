defmodule PictureRail.App.HA do
  @moduledoc """
  `:ha` controller: Home Assistant's connection status, the model revision,
  and, while the panel is up, what the panel's view shows.

  Events from `PictureRail.HA.Model` and `PictureRail.HA.EnergyPoller`:

    * `:status` - the connection status
    * `:model` - a new model revision
    * `:states` - ids of entities whose state changed (batched by the model)
    * `:energy` - today's energy summary

  From the view:

    * `:call` - `%{domain:, service:, entity_id:, data: map, optimistic: state,
      optimistic_attrs: map}` (both optimistic keys optional). The call runs
      in a task (the `:call_service` callback). With an optimistic state or
      attributes, the entity shows them at once, until Home Assistant
      reports them, the call fails (rolled back, and `error` set), or 10 s
      pass.

  Exposes `%{status:, revision:, view:, slice:, states:, nav:, energy:, error:}`.
  `slice` is `PictureRail.HA.Overview`'s result for the panel's view, or
  `:loading` before the model's first build, `:gone` when what the view
  showed was removed in Home Assistant, `nil` while the panel is down.
  `states` maps each entity id on screen to its state, pending optimistic
  values applied. Disconnected, everything stays, and `status` tells the
  view to grey it out.

  Solve calls `expose/3` after every event, so the slice is cached in this
  process per view, model revision and on-screen change (`tick`): an event
  for an entity that isn't on screen costs a map lookup.
  """
  use Solve.Controller, events: [:status, :model, :states, :call, :energy]

  require Logger

  alias PictureRail.HA.{EnergyPoller, Model, Overview}

  @optimistic_ms 10_000

  @impl Solve.Controller
  def init(_params, _dependencies) do
    # From ETS: the model may itself be waiting on the app (subscribing).
    %{
      status: Model.status(),
      revision: Model.revision(),
      tick: 0,
      pending: %{},
      error: nil,
      energy: EnergyPoller.latest()
    }
  end

  def status(status, state), do: %{state | status: status}
  def model(revision, state), do: %{state | revision: revision}
  def energy(summary, state), do: %{state | energy: summary}

  def states(ids, state, deps, _callbacks, params) do
    state = settle(state, ids, source(params))
    shown = state |> slice(deps, params) |> slice_ids() |> MapSet.new()

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

  # -- Service calls and optimistic state --

  @doc false
  @spec start_call(map(), map(), map()) :: map()
  def start_call(request, state, callbacks) do
    %{ref: ref} = callbacks.call_service.(request)
    optimistic = Map.get(request, :optimistic)
    attrs = Map.get(request, :optimistic_attrs, %{})

    if optimistic == nil and attrs == %{} do
      %{state | error: nil}
    else
      Process.send_after(self(), {:expire, request.entity_id, ref}, @optimistic_ms)
      entry = %{state: optimistic, attrs: attrs, ref: ref}
      pending = Map.put(state.pending, request.entity_id, entry)
      %{state | pending: pending, error: nil, tick: state.tick + 1}
    end
  end

  @doc false
  # A finished call: success keeps the optimistic value until HA reports
  # it; failure rolls it back.
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

  # A pending value ends when Home Assistant reports it, not on whichever
  # report comes next: one from before the call, or from an earlier tap,
  # leaves it in place.
  defp settle(state, ids, src) do
    pending =
      Enum.reduce(ids, state.pending, fn id, pending ->
        with %{^id => entry} <- pending, true <- reported?(src.state.(id), entry) do
          Map.delete(pending, id)
        else
          _ -> pending
        end
      end)

    %{state | pending: pending}
  end

  @doc false
  @spec reported?(Hassock.EntityState.t() | nil, map()) :: boolean()
  def reported?(nil, _entry), do: false

  def reported?(es, %{state: wanted, attrs: attrs}) do
    (wanted == nil or es.state == wanted) and
      Enum.all?(attrs, fn {key, value} -> close?(es.attributes[key], value) end)
  end

  # Home Assistant rounds (brightness 0-255 from a percentage, positions).
  defp close?(a, b) when is_number(a) and is_number(b), do: abs(a - b) <= max(1.5, abs(b) * 0.02)
  defp close?(a, b), do: a == b

  defp with_pending(es, nil), do: es
  defp with_pending(nil, _pending), do: nil

  defp with_pending(es, %{state: wanted, attrs: attrs}) do
    %{es | state: wanted || es.state, attributes: Map.merge(es.attributes || %{}, attrs)}
  end

  # -- The slice --

  defp view(%{panel: %{visible?: true, view: view}}), do: view
  defp view(_deps), do: nil

  @doc false
  # What the view shows, cached per {view, revision, tick} in this process.
  @spec slice(map(), map(), term()) :: term()
  def slice(state, deps, params) do
    case view(deps) do
      nil ->
        nil

      :energy ->
        state.energy

      view ->
        memo({:slice, view, state.revision, state.tick, params}, fn ->
          compute(view, state, params)
        end)
    end
  end

  defp compute(_view, %{revision: 0}, _params), do: :loading

  defp compute(view, _state, params), do: view_slice(view, source(params)) || :gone

  defp view_slice(:overview, src), do: Overview.overview(src)
  defp view_slice({:area, id}, src), do: Overview.area_view(src, id)
  defp view_slice(:media, src), do: Overview.media_view(src)
  defp view_slice(:devices, src), do: Overview.devices_view(src)
  defp view_slice({:summary, kind}, src), do: Overview.summary_view(src, kind)
  defp view_slice({:device, id}, src), do: Overview.device_view(src, id)

  defp view_slice({:entity, id}, src),
    do: if(Model.entity(id, src.table), do: %{entity_id: id})

  defp nav(state, params) do
    memo({:nav, state.revision, params}, fn ->
      if state.revision > 0, do: Overview.nav(source(params)), else: []
    end)
  end

  # One cached value per kind of key: the last one computed.
  defp memo(key, fun) do
    slot = {__MODULE__, elem(key, 0)}

    case Process.get(slot) do
      {^key, value} ->
        value

      _ ->
        value = fun.()
        Process.put(slot, {key, value})
        value
    end
  end

  defp source(%{source: src}), do: src
  defp source(_params), do: Overview.source()

  @doc "Every entity id a slice shows."
  @spec slice_ids(term()) :: [String.t()]
  def slice_ids(slice) when slice in [nil, :loading, :gone], do: []
  def slice_ids(%{entity_id: id}), do: [id]
  # the energy page shows the grid's live power
  def slice_ids(%{totals: _, power_entity: id}), do: [id]

  def slice_ids(%{kind: _, sections: sections}),
    do: for(s <- sections, g <- s.groups, id <- g.entity_ids, do: id)

  def slice_ids(%{kind: :device} = s), do: [s.battery | s.entity_ids]

  def slice_ids(%{summaries: summaries, floors: floors, other_areas: others}) do
    temps =
      for area <- Enum.flat_map(floors, & &1.areas) ++ others,
          id = area.area.temperature_entity_id,
          do: id

    Enum.flat_map(summaries, & &1.entity_ids) ++ temps
  end

  def slice_ids(%{sections: sections, area: area}) do
    Enum.flat_map(sections, &section_ids/1) ++
      [area.temperature_entity_id, area.humidity_entity_id]
  end

  def slice_ids(groups) when is_list(groups), do: Enum.flat_map(groups, &section_ids/1)

  # A device's entities are on its own page; its pill only shows the battery.
  defp section_ids(%{kind: :device, device_id: id, battery: battery}) when is_binary(id),
    do: [battery]

  defp section_ids(section), do: [Map.get(section, :battery) | section.entity_ids]

  @impl Solve.Controller
  def expose(state, deps, params) do
    slice = slice(state, deps, params)
    src = source(params)
    visible? = view(deps) != nil

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
      nav: if(visible?, do: nav(state, params), else: []),
      # only while the panel is up, so a refresh doesn't redraw the slideshow
      energy: if(visible?, do: state.energy),
      error: state.error
    }
  end
end
