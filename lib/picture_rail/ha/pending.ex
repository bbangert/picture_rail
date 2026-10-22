defmodule PictureRail.HA.Pending do
  @moduledoc """
  Optimistic values: what the panel shows for an entity between a service
  call and Home Assistant reporting its result.

  Per entity, a state and attributes, each with the ref of the call that
  set it, so each value ends on its own: when HA reports it, when its
  call fails, or when its call's time is up. A value from an earlier call
  stays while a later one sets something else (a hue, then a
  brightness), unless the later call replaces it:

    * a different state ends every pending attribute (off after a
      brightness);
    * a request's `supersedes` lists attributes it makes obsolete (a
      colour ends a pending colour temperature, a mode its old setpoints).

  Pure; the `:ha` controller holds it.
  """

  @type ref :: reference()
  @type entry :: %{state: {String.t(), ref()} | nil, attrs: %{String.t() => {term(), ref()}}}
  @type t :: %{String.t() => entry()}

  # A thermostat's setpoints come back as sent, and a step can be 0.5.
  @exact ~w(temperature target_temp_low target_temp_high)

  @doc "Add a call's optimistic values (`optimistic`, `optimistic_attrs`, `supersedes`)."
  @spec put(t(), map(), ref()) :: t()
  def put(pending, request, ref) do
    wanted = Map.get(request, :optimistic)
    entry = Map.get(pending, request.entity_id, %{state: nil, attrs: %{}})

    attrs =
      case entry.state do
        {old, _ref} when wanted != nil and old != wanted -> %{}
        _ -> Map.drop(entry.attrs, Map.get(request, :supersedes, []))
      end

    attrs =
      for {key, value} <- Map.get(request, :optimistic_attrs, %{}),
          into: attrs,
          do: {key, {value, ref}}

    state = if wanted == nil, do: entry.state, else: {wanted, ref}
    store(pending, request.entity_id, %{state: state, attrs: attrs})
  end

  @doc "End what Home Assistant now reports for `entity_id` (`es`)."
  @spec settle(t(), String.t(), Hassock.EntityState.t() | nil) :: t()
  def settle(pending, _entity_id, nil), do: pending

  def settle(pending, entity_id, es) do
    case pending do
      %{^entity_id => entry} -> store(pending, entity_id, unreported(entry, es))
      _ -> pending
    end
  end

  defp unreported(entry, es) do
    state =
      case entry.state do
        {wanted, _ref} when wanted == es.state -> nil
        state -> state
      end

    attrs =
      entry.attrs
      |> Enum.reject(fn {key, {value, _ref}} -> close?(key, es.attributes[key], value) end)
      |> Map.new()

    %{state: state, attrs: attrs}
  end

  @doc "End what a call set, everywhere (it failed)."
  @spec drop(t(), ref()) :: t()
  def drop(pending, ref) do
    Enum.reduce(pending, pending, fn {id, entry}, pending ->
      store(pending, id, without(entry, ref))
    end)
  end

  @doc "End what a call set for `entity_id` (its time is up)."
  @spec expire(t(), String.t(), ref()) :: t()
  def expire(pending, entity_id, ref) do
    case pending do
      %{^entity_id => entry} -> store(pending, entity_id, without(entry, ref))
      _ -> pending
    end
  end

  @doc "The entity as shown: its pending values over what HA reports."
  @spec shown(Hassock.EntityState.t() | nil, entry() | nil) :: Hassock.EntityState.t() | nil
  def shown(es, nil), do: es
  def shown(nil, _entry), do: nil

  def shown(es, entry) do
    state = with {wanted, _ref} <- entry.state, do: wanted
    attrs = Map.new(entry.attrs, fn {key, {value, _ref}} -> {key, value} end)
    %{es | state: state || es.state, attributes: Map.merge(es.attributes || %{}, attrs)}
  end

  defp without(entry, ref) do
    state = with {_wanted, ^ref} <- entry.state, do: nil

    %{
      state: state,
      attrs: entry.attrs |> Enum.reject(fn {_key, {_value, r}} -> r == ref end) |> Map.new()
    }
  end

  # an entity with nothing pending isn't kept
  defp store(pending, id, %{state: nil, attrs: attrs}) when attrs == %{},
    do: Map.delete(pending, id)

  defp store(pending, id, entry), do: Map.put(pending, id, entry)

  # Home Assistant rounds (brightness 0-255 from a percentage, positions,
  # kelvin through mireds), and a colour comes back through the light's
  # own colour space.
  defp close?(key, a, b) when key in @exact and is_number(a) and is_number(b),
    do: abs(a - b) < 0.01

  defp close?(_key, a, b) when is_number(a) and is_number(b),
    do: abs(a - b) <= max(1.5, abs(b) * 0.02)

  # hue means nothing at (near) zero saturation: white is white
  defp close?("hs_color", [h, s], [wanted_h, wanted_s]) when is_number(h) and is_number(s),
    do: abs(s - wanted_s) <= 4 and (wanted_s <= 4 or hue_distance(h, wanted_h) <= 4)

  defp close?(_key, a, b), do: a == b

  # around the circle: 359 and 1 are 2 apart, 360 and 0 the same red
  defp hue_distance(a, b) do
    d = :math.fmod(abs(a - b), 360)
    min(d, 360 - d)
  end
end
