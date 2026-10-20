defmodule PictureRail.Hardware.Host do
  @moduledoc """
  Development on a laptop: a 1920x1080 window through Emerge's default
  backend (Wayland or macOS), mouse input, no sensors.
  """
  @behaviour PictureRail.Hardware

  @impl PictureRail.Hardware
  def children, do: []

  @impl PictureRail.Hardware
  def screen_size, do: nil

  @impl PictureRail.Hardware
  def orientation, do: :unknown

  @impl PictureRail.Hardware
  def emerge_config do
    [output: %Emerge.Config.Window{title: "Picture Rail", size: {1920, 1080}}]
  end
end
