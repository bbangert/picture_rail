defmodule HomeFrame.Orientation do
  @moduledoc """
  Which way up the screen is, as reported by a hardware module's sensor.

  Names follow the device's natural (landscape) orientation:

    * `:landscape` - upright as designed
    * `:landscape_inverted` - upside down
    * `:portrait_x_pos` / `:portrait_x_neg` - turned onto either side
    * `:flat` - lying face up or down; the UI keeps its last orientation
  """

  @type t :: :landscape | :landscape_inverted | :portrait_x_pos | :portrait_x_neg
  @type reading :: t() | :flat

  @doc """
  Report a new orientation reading from a sensor. The UI picks it up (with
  hysteresis) once the app is running; until then readings are dropped.
  """
  @spec report(reading()) :: :ok
  def report(orientation)
      when orientation in [
             :landscape,
             :landscape_inverted,
             :portrait_x_pos,
             :portrait_x_neg,
             :flat
           ] do
    if Process.whereis(HomeFrame.App) do
      Solve.dispatch(HomeFrame.App, :orientation, :reading, orientation)
    end

    :ok
  end

  # Which portrait side needs 90 vs 270 is checked on the device in the
  # rotation spike (plan task 2.3).
  @doc "Clockwise rotation (degrees) that turns the UI upright for `orientation`."
  @spec rotation(t()) :: 0 | 90 | 180 | 270
  def rotation(:landscape), do: 0
  def rotation(:portrait_x_neg), do: 90
  def rotation(:landscape_inverted), do: 180
  def rotation(:portrait_x_pos), do: 270

  @doc "True for the two portrait orientations."
  @spec portrait?(t()) :: boolean()
  def portrait?(orientation), do: orientation in [:portrait_x_pos, :portrait_x_neg]
end
