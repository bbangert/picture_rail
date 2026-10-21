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
    * `:replace` - put a view in place of the current one (Setup's "Next":
      there's one Setup editor, so a section doesn't stack on another)
    * `:goto` - go to a view from the navigation: it replaces the stack
      (`:overview` empties it)
    * `:back` - pop a view (to the overview at the bottom), back to the
      page it was left on
    * `:page` - turn the current view to page `n`
    * `:nav_page` - turn the navigation to page `n`
    * `:hide` - hide now

  The panel hides after `panel.timeout_ms` (settings) without activity and
  comes back fresh: on the overview, first pages. On a Setup page with
  something going on (unsaved changes, an album list loading, Wi-Fi not
  connected: `busy?` from `:setup`) it waits five minutes instead. That's
  checked again when the time is up, as `:setup` can become busy after
  the timer was set (on first boot it opens with the panel).

  Exposes `%{visible?: boolean, view: view, depth: n, page: n, nav_page: n}`.
  """
  use Solve.Controller,
    events: [:show, :activity, :open, :replace, :goto, :back, :page, :nav_page, :hide]

  @doc "Whether a view is one of the Setup pages (`:setup`, `{:setup, section}`)."
  defguard is_setup_view(view)
           when view == :setup or
                  (is_tuple(view) and tuple_size(view) == 2 and elem(view, 0) == :setup)

  @impl Solve.Controller
  def init(_params, _dependencies), do: fresh()

  # The stack holds `{view, page}`; the overview's page is `root_page`.
  defp fresh, do: %{visible?: false, stack: [], root_page: 0, nav_page: 0, token: nil}

  def show(_payload, state, deps), do: %{state | visible?: true} |> restart_timer(deps)

  def activity(_payload, %{visible?: true} = state, deps), do: restart_timer(state, deps)
  def activity(_payload, state, _deps), do: state

  def open(view, state, deps),
    do: %{state | visible?: true, stack: [{view, 0} | state.stack]} |> restart_timer(deps)

  def replace(view, %{stack: [_ | rest]} = state, deps),
    do: %{state | visible?: true, stack: [{view, 0} | rest]} |> restart_timer(deps)

  def replace(view, state, deps), do: open(view, state, deps)

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

  def handle_info({:timeout, token}, state, deps), do: timed_out(token, state, deps)
  def handle_info(_message, state, _deps), do: state

  @doc """
  Hide the panel if `token` is the current idle timer's, unless a Setup
  page is busy by now: then wait again.
  """
  @spec timed_out(reference(), map(), map()) :: map()
  def timed_out(token, state, deps \\ %{})

  def timed_out(token, %{token: token} = state, deps),
    do: if(busy_setup?(state, deps), do: restart_timer(state, deps), else: fresh())

  def timed_out(_token, state, _deps), do: state

  # A fresh token per restart: a timeout already in the mailbox from an
  # earlier one is ignored.
  defp restart_timer(state, deps) do
    token = make_ref()
    Process.send_after(self(), {:timeout, token}, timeout_ms(state, deps))
    %{state | token: token}
  end

  @busy_timeout_ms 300_000

  @doc false
  @spec timeout_ms(map(), map()) :: pos_integer()
  def timeout_ms(state, deps) do
    case {busy_setup?(state, deps), deps} do
      {true, _} -> @busy_timeout_ms
      {false, %{settings: %{settings: %{panel: %{timeout_ms: ms}}}}} -> ms
      {false, _} -> PictureRail.Settings.defaults().panel.timeout_ms
    end
  end

  defp busy_setup?(%{stack: [{view, _page} | _]}, %{setup: %{busy?: true}}),
    do: is_setup_view(view)

  defp busy_setup?(_state, _deps), do: false

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
