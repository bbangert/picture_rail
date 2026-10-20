defmodule HomeFrame.App.Panel do
  @moduledoc """
  `:panel` controller: whether the Home Assistant panel is up, which view
  it shows, and its idle timeout.

  Events:

    * `:show` - a tap on the photos; while visible it just counts as
      activity
    * `:activity` - any interaction with the panel; restarts the timeout
    * `:open` - push a view (`{:area, id}`, `:media`, `:devices`,
      `{:entity, entity_id}`)
    * `:back` - pop a view (to the overview at the bottom)
    * `:hide` - hide now

  The panel hides after `panel.timeout_ms` (settings) without activity and
  comes back on the overview next time.

  Exposes `%{visible?: boolean, view: view, depth: n}`.
  """
  use Solve.Controller, events: [:show, :activity, :open, :back, :hide]

  @impl Solve.Controller
  def init(_params, _dependencies), do: %{visible?: false, stack: [], token: nil}

  def show(_payload, state, deps), do: %{state | visible?: true} |> restart_timer(deps)

  def activity(_payload, %{visible?: true} = state, deps), do: restart_timer(state, deps)
  def activity(_payload, state, _deps), do: state

  def open(view, state, deps),
    do: %{state | visible?: true, stack: [view | state.stack]} |> restart_timer(deps)

  def back(_payload, %{stack: [_ | rest]} = state, deps),
    do: %{state | stack: rest} |> restart_timer(deps)

  def back(_payload, state, deps), do: restart_timer(state, deps)

  def hide(_payload, state), do: %{state | visible?: false, stack: [], token: nil}

  def handle_info({:timeout, token}, state), do: timed_out(token, state)
  def handle_info(_message, state), do: state

  @doc "Hide the panel if `token` is the current idle timer's."
  @spec timed_out(reference(), map()) :: map()
  def timed_out(token, %{token: token} = state),
    do: %{state | visible?: false, stack: [], token: nil}

  def timed_out(_token, state), do: state

  # A fresh token per restart: a timeout already in the mailbox from an
  # earlier one is ignored.
  defp restart_timer(state, deps) do
    token = make_ref()
    Process.send_after(self(), {:timeout, token}, timeout_ms(deps))
    %{state | token: token}
  end

  defp timeout_ms(%{settings: %{settings: %{panel: %{timeout_ms: ms}}}}), do: ms
  defp timeout_ms(_deps), do: HomeFrame.Settings.defaults().panel.timeout_ms

  @impl Solve.Controller
  def expose(state, _dependencies, _params) do
    %{
      visible?: state.visible?,
      view: List.first(state.stack, :overview),
      depth: length(state.stack)
    }
  end
end
