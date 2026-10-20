defmodule HomeFrame.Hardware.Frame156.AccelerometerTest do
  use ExUnit.Case, async: true

  alias HomeFrame.Hardware.Frame156.Accelerometer

  defp g(x, y, z), do: %{x: x, y: y, z: z}

  test "gravity on one axis picks the orientation" do
    assert Accelerometer.classify(g(0.0, -1.0, 0.0), :unknown) == :landscape
    assert Accelerometer.classify(g(0.0, 1.0, 0.0), :unknown) == :landscape_inverted
    assert Accelerometer.classify(g(1.0, 0.0, 0.0), :unknown) == :portrait_x_pos
    assert Accelerometer.classify(g(-1.0, 0.0, 0.0), :unknown) == :portrait_x_neg
    assert Accelerometer.classify(g(0.0, 0.0, 1.0), :landscape) == :flat
  end

  test "an in-between tilt keeps the previous orientation" do
    assert Accelerometer.classify(g(0.5, -0.5, 0.5), :portrait_x_pos) == :portrait_x_pos
  end
end
