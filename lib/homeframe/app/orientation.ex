defmodule HomeFrame.App.Orientation do
  @moduledoc """
  `:orientation` controller: which way up the UI is drawn.

  It starts from the sensor's current reading (`HomeFrame.Hardware`'s
  `orientation/0`): the sensor reports only changes, so a controller that
  started after the last report (a restart, or the app coming up after the
  sensor's first reading) would otherwise never hear it.

  Fed with sensor readings by `HomeFrame.Orientation.report/1`. A new
  orientation has to hold for a second before the UI turns, so a frame
  being carried around doesn't flip back and forth; `:flat` readings are
  ignored (the UI keeps its last orientation). Devices without a sensor
  stay in `config :homeframe, default_orientation: ...` (`:landscape`).

  Exposes `%{orientation: o, rotation: degrees, portrait?: boolean}`.
  """
  use Solve.Controller, events: [:reading]

  alias HomeFrame.Orientation

  @settle_ms 1_000

  @impl Solve.Controller
  def init(params, _dependencies) do
    default =
      case params do
        %{default: default} -> default
        _ -> Application.get_env(:homeframe, :default_orientation, :landscape)
      end

    reading =
      case params do
        %{reading: reading} -> reading
        _ -> HomeFrame.Hardware.impl().orientation()
      end

    %{current: initial(reading, default), pending: nil, settle_ms: settle_ms(params)}
  end

  @doc "Where to start: the sensor's reading if it is an orientation, else the default."
  @spec initial(Orientation.reading() | :unknown, Orientation.t()) :: Orientation.t()
  def initial(reading, _default)
      when reading in [:landscape, :landscape_inverted, :portrait_x_pos, :portrait_x_neg],
      do: reading

  def initial(_reading, default), do: default

  defp settle_ms(%{settle_ms: ms}), do: ms
  defp settle_ms(_params), do: @settle_ms

  def reading(:flat, state), do: state
  def reading(orientation, %{current: orientation} = state), do: %{state | pending: nil}
  def reading(orientation, %{pending: {orientation, _token}} = state), do: state

  def reading(orientation, state) do
    token = make_ref()
    Process.send_after(self(), {:settle, token}, state.settle_ms)
    %{state | pending: {orientation, token}}
  end

  def handle_info({:settle, token}, state), do: settle(token, state)
  def handle_info(_message, state), do: state

  @doc "Apply the pending orientation if `token` is its settle timer's."
  @spec settle(reference(), map()) :: map()
  def settle(token, %{pending: {orientation, token}} = state),
    do: %{state | current: orientation, pending: nil}

  def settle(_token, state), do: state

  @impl Solve.Controller
  def expose(state, _dependencies, _params) do
    %{
      orientation: state.current,
      rotation: Orientation.rotation(state.current),
      portrait?: Orientation.portrait?(state.current)
    }
  end
end
