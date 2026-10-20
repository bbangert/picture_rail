defmodule PictureRail.View.Format do
  @moduledoc """
  How entity states read on the panel: short, upper case, with units, and
  whether a state counts as "on" (bright pill) or "off" (dark tint).
  """

  alias PictureRail.HA.Index

  @off ~w(off closed idle standby locked not_home paused unavailable unknown)

  @doc "Whether a state draws its pill bright."
  @spec on?(Hassock.EntityState.t() | nil) :: boolean()
  def on?(nil), do: false

  def on?(%{entity_id: id, state: state}) do
    case Index.domain(id) do
      domain when domain in ["sensor", "scene", "script", "button", "input_button"] ->
        state not in ["unavailable", "unknown"]

      _ ->
        state not in @off
    end
  end

  @doc "The state as the pill shows it."
  @spec state(Hassock.EntityState.t() | nil) :: String.t()
  def state(nil), do: "—"
  def state(%{state: "unavailable"}), do: "UNAVAILABLE"

  def state(%{entity_id: id} = es), do: id |> Index.domain() |> state(es) |> String.upcase()

  defp state("light", %{state: "on", attributes: %{"brightness" => b}}) when is_number(b),
    do: "on #{round(b / 255 * 100)}%"

  defp state("sensor", %{state: value, attributes: attrs}),
    do:
      [number(value), attrs["unit_of_measurement"]]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" ")

  defp state("climate", %{state: mode, attributes: attrs}) do
    current = attrs["current_temperature"]
    target = attrs["temperature"]

    case {current, target} do
      {nil, nil} -> mode
      {c, nil} -> "#{mode} #{number(c)}°"
      {nil, t} -> "#{mode} › #{number(t)}°"
      {c, t} -> "#{number(c)}° › #{number(t)}°"
    end
  end

  defp state("cover", %{state: state, attributes: %{"current_position" => p}})
       when is_number(p) and state in ["open", "opening", "closing"],
       do: "#{state} #{p}%"

  defp state("binary_sensor", %{state: state, attributes: attrs}),
    do: binary(attrs["device_class"], state)

  defp state("person", %{state: "not_home"}), do: "away"

  defp state("media_player", %{state: "playing", attributes: %{"media_title" => t}})
       when is_binary(t), do: t

  defp state(domain, %{state: _}) when domain in ["scene", "script", "button", "input_button"],
    do: "run"

  defp state(_domain, %{state: state}), do: String.replace(state, "_", " ")

  @open_classes ~w(door garage_door opening window)

  defp binary(class, "on") when class in @open_classes, do: "open"
  defp binary(class, "off") when class in @open_classes, do: "closed"
  defp binary("motion", "on"), do: "motion"
  defp binary("occupancy", "on"), do: "occupied"
  defp binary("presence", "on"), do: "home"
  defp binary(class, "off") when class in ~w(motion occupancy presence), do: "clear"
  defp binary("battery", "on"), do: "low"
  defp binary("battery", "off"), do: "ok"

  defp binary(class, "on") when class in ~w(moisture smoke gas carbon_monoxide safety),
    do: "alert"

  defp binary(class, "off") when class in ~w(moisture smoke gas carbon_monoxide safety), do: "ok"
  defp binary(_class, state), do: state

  # "21.53" -> "21.5", "40.0" -> "40"; anything else unchanged.
  defp number(value) when is_number(value), do: number(to_string(value))

  defp number(value) when is_binary(value) do
    case Float.parse(value) do
      {n, ""} -> n |> Float.round(1) |> trim()
      _ -> value
    end
  end

  defp number(value), do: to_string(value)

  defp trim(n) when n == trunc(n), do: Integer.to_string(trunc(n))
  defp trim(n), do: Float.to_string(n)
end
