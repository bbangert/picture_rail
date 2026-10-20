defmodule PictureRail.View.Theme do
  @moduledoc """
  The panel's LCARS-style look: a palette of flat colours on black,
  colours per Home Assistant domain, type sizes (Antonio, upper case) and
  spacing. Touch targets are at least 72 px.

  Colours are hex integers (`0xFF9900`); `color/1` and `color/2` turn them
  into Emerge colours, `dim/1` gives the darker tint for "off".
  """
  import Bitwise
  import Emerge.UI.Color, only: [color_rgba: 4]

  @palette %{
    orange: 0xFF9900,
    gold: 0xFFAA44,
    peach: 0xFFCC99,
    almond: 0xD29B7F,
    lilac: 0xCC99CC,
    mauve: 0xC082A9,
    violet: 0x9977CC,
    bluey: 0x8899FF,
    sky: 0x99CCFF,
    red: 0xFF3300,
    rose: 0xCC6666,
    grey: 0x585A68,
    white: 0xF3F3FC,
    black: 0x000000
  }

  @doc "A named palette colour as a hex integer."
  @spec hex(atom()) :: non_neg_integer()
  def hex(name), do: Map.fetch!(@palette, name)

  @doc "An Emerge colour from a palette name or a hex integer, with optional alpha."
  @spec color(atom() | non_neg_integer(), number()) :: term()
  def color(name_or_hex, alpha \\ 1.0)
  def color(name, alpha) when is_atom(name), do: color(hex(name), alpha)

  def color(hex, alpha) when is_integer(hex) do
    color_rgba(hex >>> 16 &&& 0xFF, hex >>> 8 &&& 0xFF, hex &&& 0xFF, alpha)
  end

  @doc "The darker tint of a colour, for things that are off."
  @spec dim(non_neg_integer()) :: non_neg_integer()
  def dim(hex) do
    scale = fn c -> round(c * 0.38) end
    r = scale.(hex >>> 16 &&& 0xFF)
    g = scale.(hex >>> 8 &&& 0xFF)
    b = scale.(hex &&& 0xFF)
    r <<< 16 ||| g <<< 8 ||| b
  end

  @domains %{
    "light" => :gold,
    "switch" => :lilac,
    "input_boolean" => :lilac,
    "fan" => :sky,
    "climate" => :orange,
    "water_heater" => :orange,
    "humidifier" => :sky,
    "cover" => :mauve,
    "media_player" => :bluey,
    "lock" => :rose,
    "alarm_control_panel" => :rose,
    "camera" => :rose,
    "scene" => :peach,
    "script" => :peach,
    "automation" => :violet,
    "button" => :peach,
    "input_button" => :peach,
    "sensor" => :almond,
    "binary_sensor" => :almond,
    "person" => :sky,
    "update" => :violet
  }

  @doc "The colour (hex) for a domain's pills."
  @spec domain(String.t()) :: non_neg_integer()
  def domain(domain), do: hex(Map.get(@domains, domain, :lilac))

  @doc "Colours (hex) for the summary pills and section headings."
  @spec kind(atom()) :: non_neg_integer()
  def kind(:light), do: hex(:gold)
  def kind(:climate), do: hex(:orange)
  def kind(:security), do: hex(:rose)
  def kind(:media_players), do: hex(:bluey)
  def kind(:maintenance), do: hex(:almond)
  def kind(:persons), do: hex(:sky)
  def kind(:scenes), do: hex(:peach)
  def kind(:automations), do: hex(:violet)
  def kind(:device), do: hex(:lilac)
  def kind(_kind), do: hex(:lilac)

  # Sizes, in px at 1080 p.
  @sizes %{
    sidebar: 260,
    elbow_arm: 48,
    top: 150,
    top_bar: 36,
    bottom: 88,
    bottom_bar: 26,
    gap: 6,
    pill: 84,
    nav: 72,
    gutter: 24,
    title: 60,
    heading: 30,
    label: 26,
    small: 21
  }

  @doc "A size or font size, in px."
  @spec size(atom()) :: number()
  def size(name), do: Map.fetch!(@sizes, name)
end
