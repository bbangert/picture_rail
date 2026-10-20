defmodule PictureRail do
  @moduledoc """
  A Home Assistant dashboard and photo frame for Nerves touch displays.

  Photos from Immich albums cycle full screen; a tap brings up an
  LCARS-style panel with the home's devices, organised like Home
  Assistant's Overview dashboard.

  Everything device-specific (sensors, display output, boot tweaks) lives
  behind `PictureRail.Hardware`, so another Nerves touch display needs a
  Nerves system and a hardware module, nothing else.
  """
end
