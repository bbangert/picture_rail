defmodule PictureRail.Setup.Field do
  @moduledoc """
  One setting: its key in the settings file, how it is shown and edited,
  and how it is validated.

  The built-in sections (`PictureRail.Settings.Sections`) and every photo
  source (`PictureRail.PhotoSource`) declare their settings as a list of
  fields. `validate/3` checks a section of the settings file against it,
  and the frame's Setup page and the web page both render their forms from
  it, so nothing about a particular section lives in the UI.

  Types:

    * `:url` - an `http://` or `https://` URL, stored without a trailing `/`
    * `:text` - a non-empty string
    * `:secret` - a non-empty string that is never shown back, only replaced
    * `:toggle` - `true` or `false`
    * `:integer` - an integer within `min`..`max`
    * `:seconds` - a duration, stored in milliseconds (`min`, `max` and
      `step` are in milliseconds too) and shown in seconds
    * `{:choices, :multi}` - a list of strings picked from choices the
      section provides (a photo source's `choices/2`)

  Fields with `ui?: false` are read from the file but never shown (older
  keys kept for files edited by hand). One with `superseded_by: key` is an
  older way of setting that field: a save from the Setup page or the web
  page that changes the newer field removes it, so what's shown is what's
  used (`PictureRail.Setup.values/3`).

  A stored secret is only ever sent to the server it was given for: see
  `same_server?/3`. A toggle with `secures?: true` (checking the server's
  certificate) counts as part of the server.

  For the text types, `max` is the most characters the Setup page lets you
  type (512 when unset); it isn't checked in the file.
  """

  @enforce_keys [:key, :label, :type]
  defstruct [
    :key,
    :label,
    :type,
    required?: false,
    default: nil,
    help: nil,
    min: nil,
    max: nil,
    step: nil,
    ui?: true,
    secures?: false,
    superseded_by: nil
  ]

  @type type :: :url | :text | :secret | :toggle | :integer | :seconds | {:choices, :multi}

  @type t :: %__MODULE__{
          key: String.t(),
          label: String.t(),
          type: type(),
          required?: boolean(),
          default: term(),
          help: String.t() | nil,
          min: integer() | nil,
          max: integer() | nil,
          step: pos_integer() | nil,
          ui?: boolean(),
          secures?: boolean(),
          superseded_by: String.t() | nil
        }

  @doc """
  Validate `section` (a map with string keys, from the settings file)
  against `fields`. `name` prefixes the error messages
  (`"immich.url is required"`).

  Returns the declared keys only, with defaults for those left out
  (fields without a default are left out when absent). All errors are
  collected.
  """
  @spec validate([t()], String.t(), map()) :: {:ok, map()} | {:error, [String.t()]}
  def validate(fields, name, section) when is_map(section) do
    {values, errors} =
      Enum.reduce(fields, {%{}, []}, fn field, {values, errors} ->
        case check(field, Map.get(section, field.key)) do
          {:ok, nil} -> {values, errors}
          {:ok, value} -> {Map.put(values, field.key, value), errors}
          {:error, message} -> {values, ["#{name}.#{field.key} #{message}" | errors]}
        end
      end)

    if errors == [], do: {:ok, values}, else: {:error, Enum.reverse(errors)}
  end

  defp check(%__MODULE__{required?: true}, nil), do: {:error, "is required"}
  defp check(%__MODULE__{default: default}, nil), do: {:ok, default}
  defp check(%__MODULE__{type: type} = field, value), do: check_type(type, field, value)

  defp check_type(:url, _field, "http://" <> _ = url), do: {:ok, trim_url(url)}
  defp check_type(:url, _field, "https://" <> _ = url), do: {:ok, trim_url(url)}
  defp check_type(:url, _field, _value), do: {:error, "must start with http:// or https://"}

  defp check_type(type, _field, value) when type in [:text, :secret] do
    if is_binary(value) and value != "",
      do: {:ok, value},
      else: {:error, "must be a non-empty string"}
  end

  defp check_type(:toggle, _field, value) when is_boolean(value), do: {:ok, value}
  defp check_type(:toggle, _field, _value), do: {:error, "must be true or false"}

  defp check_type(type, field, value) when type in [:integer, :seconds] do
    cond do
      not is_integer(value) or (field.min != nil and value < field.min) ->
        {:error, describe_min(field.min)}

      field.max != nil and value > field.max ->
        {:error, "must be at most #{field.max}"}

      true ->
        {:ok, value}
    end
  end

  defp check_type({:choices, :multi}, _field, value) do
    if is_list(value) and Enum.all?(value, &is_binary/1),
      do: {:ok, value},
      else: {:error, "must be a list of strings"}
  end

  defp describe_min(1), do: "must be a positive integer"
  defp describe_min(0), do: "must be a non-negative integer"
  defp describe_min(nil), do: "must be an integer"
  defp describe_min(min), do: "must be an integer of at least #{min}"

  defp trim_url(url), do: String.trim_trailing(url, "/")

  @doc "The most characters a text field takes on the Setup page."
  @spec max_length(t()) :: pos_integer()
  def max_length(%__MODULE__{max: max}) when is_integer(max), do: max
  def max_length(%__MODULE__{}), do: 512

  @doc """
  Whether a section's `new` values still point at the server its `old`
  ones did, so that stored secrets may go along: every `:url` field keeps
  its scheme, host and port, and no `secures?` toggle is turned off.
  Changing the server means typing the secrets again, so that whoever can
  change the URL can't have the frame send a stored key elsewhere.
  """
  @spec same_server?([t()], map(), map()) :: boolean()
  def same_server?(fields, old, new) do
    Enum.all?(fields, fn
      %__MODULE__{type: :url, key: key} ->
        origin(old[key]) == origin(new[key])

      %__MODULE__{type: :toggle, secures?: true} = field ->
        not (value_of(field, old) == true and value_of(field, new) == false)

      _field ->
        true
    end)
  end

  defp origin(url) when is_binary(url) do
    uri = url |> String.trim() |> URI.parse()
    {uri.scheme && String.downcase(uri.scheme), uri.host && String.downcase(uri.host), uri.port}
  end

  defp origin(_url), do: nil

  # As validation reads it: absent or `null` is the default.
  defp value_of(%__MODULE__{key: key, default: default}, values) do
    case Map.get(values, key) do
      nil -> default
      value -> value
    end
  end

  @doc "What a kept secret needs when the server changes."
  @spec retype() :: String.t()
  def retype, do: "must be entered again for a new server"

  @doc "The keys of the secret fields."
  @spec secret_keys([t()]) :: [String.t()]
  def secret_keys(fields), do: for(%__MODULE__{type: :secret, key: key} <- fields, do: key)

  @doc """
  `values` without the secrets, and with `"<key>_set?"` saying whether each
  secret has a value, for state that the UI holds.
  """
  @spec public([t()], map()) :: map()
  def public(fields, values) do
    Enum.reduce(secret_keys(fields), values, fn key, acc ->
      acc
      |> Map.delete(key)
      |> Map.put(key <> "_set?", Map.get(values, key) not in [nil, ""])
    end)
  end
end
