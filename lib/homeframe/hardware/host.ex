defmodule HomeFrame.Hardware.Host do
  @moduledoc """
  Development on a laptop: a 1920x1080 window through Emerge's default
  backend (Wayland or macOS), mouse input, no sensors.
  """
  @behaviour HomeFrame.Hardware

  @impl HomeFrame.Hardware
  def children, do: []

  @impl HomeFrame.Hardware
  def screen_size, do: nil

  @impl HomeFrame.Hardware
  def emerge_config do
    [output: %Emerge.Config.Window{title: "HomeFrame", size: {1920, 1080}}]
  end
end
