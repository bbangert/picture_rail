defmodule PictureRail.App.Panel do
  @moduledoc """
  `:panel` controller: whether the Home Assistant panel is up, which view
  it shows and on which page, and its idle timeout.

  Events:

    * `:show` - a tap on the photos; while visible it just counts as
      activity
    * `:activity` - any interaction with the panel; restarts the timeout
    * `:open` - push a view (`{:area, id}`, `{:summary, kind}`, `:media`,
      `:devices`, `:energy`, `{:device, device_id}`, `{:entity, entity_id}`)
    * `:goto` - go to a view from the navigation: it replaces the stack
      (`:overview` empties it)
    * `:back` - pop a view (to the overview at the bottom), back to the
      page it was left on
    * `:page` - turn the current view to page `n`
    * `:nav_page` - turn the navigation to page `n`
    * `:hide` - hide now

  The panel hides after `panel.timeout_ms` (settings) without activity and
  comes back fresh: on the overview, first pages.

  Exposes `%{visible?: boolean, view: view, depth: n, page: n, nav_page: n}`.
  """
  use Solve.Controller,
    events: [:show, :activity, :open, :goto, :back, :page, :nav_page, :hide]

  @impl Solve.Controller
  def init(_params, _dependencies), do: fresh()

  # The stack holds `{view, page}`; the overview's page is `root_page`.
  defp fresh, do: %{visible?: false, stack: [], root_page: 0, nav_page: 0, token: nil}

  def show(_payload, state, deps), do: %{state | visible?: true} |> restart_timer(deps)

  def activity(_payload, %{visible?: true} = state, deps), do: restart_timer(state, deps)
  def activity(_payload, state, _deps), do: state

  def open(view, state, deps),
    do: %{state | visible?: true, stack: [{view, 0} | state.stack]} |> restart_timer(deps)

  def goto(:overview, state, deps),
    do: %{state | visible?: true, stack: [], root_page: 0} |> restart_timer(deps)

  def goto(view, state, deps),
    do: %{state | visible?: true, stack: [{view, 0}]} |> restart_timer(deps)

  def back(_payload, %{stack: [_ | rest]} = state, deps),
    do: %{state | stack: rest} |> restart_timer(deps)

  def back(_payload, state, deps), do: restart_timer(state, deps)

  def page(n, %{stack: [{view, _} | rest]} = state, deps),
    do: %{state | stack: [{view, n} | rest]} |> restart_timer(deps)

  def page(n, state, deps), do: %{state | root_page: n} |> restart_timer(deps)

  def nav_page(n, state, deps), do: %{state | nav_page: n} |> restart_timer(deps)

  def hide(_payload, _state), do: fresh()

  def handle_info({:timeout, token}, state), do: timed_out(token, state)
  def handle_info(_message, state), do: state

  @doc "Hide the panel if `token` is the current idle timer's."
  @spec timed_out(reference(), map()) :: map()
  def timed_out(token, %{token: token}), do: fresh()
  def timed_out(_token, state), do: state

  # A fresh token per restart: a timeout already in the mailbox from an
  # earlier one is ignored.
  defp restart_timer(state, deps) do
    token = make_ref()
    Process.send_after(self(), {:timeout, token}, timeout_ms(deps))
    %{state | token: token}
  end

  defp timeout_ms(%{settings: %{settings: %{panel: %{timeout_ms: ms}}}}), do: ms
  defp timeout_ms(_deps), do: PictureRail.Settings.defaults().panel.timeout_ms

  @impl Solve.Controller
  def expose(state, _dependencies, _params) do
    {view, page} = List.first(state.stack, {:overview, state.root_page})

    %{
      visible?: state.visible?,
      view: view,
      page: page,
      nav_page: state.nav_page,
      depth: length(state.stack)
    }
  end
end
