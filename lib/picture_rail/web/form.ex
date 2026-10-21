defmodule PictureRail.Web.Form do
  @moduledoc """
  The settings web page's forms, as pure functions over the Setup page's
  sections and drafts (`PictureRail.Setup`): which sections the page has,
  a draft from a posted form, and what each input shows.

  Inputs are named `f[<file section>][<key>]`. Every input the page draws
  also posts its id in `shown[]` (`"<file section>/<key>"`): only those
  are taken from the form, the rest keep what's saved. So an unticked
  checkbox (which posts nothing) reads as off, while an album list that
  couldn't be loaded, and so wasn't drawn, leaves the saved albums alone.

  A secret is never put back into a page: its input is always empty, and
  left empty it keeps the saved one.
  """

  alias PictureRail.{PhotoSource, Setup}
  alias PictureRail.Setup.{Field, Secret}

  @sections %{
    "photo_source" => :photo_source,
    "home_assistant" => :home_assistant,
    "display" => :display
  }

  @doc "The sections the web page edits (Wi-Fi is set on the frame only)."
  @spec sections() :: [Setup.section()]
  def sections, do: [:photo_source, :home_assistant, :display]

  @doc "A section from its path segment (`\"photo_source\"`), or `:error`."
  @spec section(String.t()) :: {:ok, Setup.section()} | :error
  def section(slug), do: Map.fetch(@sections, slug)

  @doc "A section's path segment."
  @spec slug(Setup.section()) :: String.t()
  def slug(section), do: Atom.to_string(section)

  @doc "An input's id in `shown[]`."
  @spec shown_id(Setup.id()) :: String.t()
  def shown_id({name, key}), do: "#{name}/#{key}"

  @doc """
  The draft a posted form makes: what's saved (`public`, from
  `PictureRail.Settings.public/1`), with the shown inputs' values over it.
  A photo source of another type than the saved one starts afresh.
  """
  @spec draft(Setup.section(), map(), map()) :: Setup.draft()
  def draft(section, params, public) do
    base = base_draft(section, params, public)
    form = map_param(params, "f")
    shown = params |> Map.get("shown") |> List.wrap() |> MapSet.new()

    for {name, %Field{} = f} <- Setup.fields(section, base),
        MapSet.member?(shown, shown_id({name, f.key})),
        reduce: base do
      draft -> Map.put(draft, {name, f.key}, value(f, map_param(form, name)[f.key]))
    end
  end

  defp base_draft(:photo_source, params, public) do
    saved = Setup.draft(:photo_source, public)
    type = params["type"]

    if is_binary(type) and type in PhotoSource.types() and type != saved[Setup.type_id()],
      do: Setup.draft(:photo_source, %{photo_source: %{"type" => type}}),
      else: saved
  end

  defp base_draft(section, _params, public), do: Setup.draft(section, public)

  defp map_param(params, key) do
    case Map.get(params, key) do
      %{} = map -> map
      _ -> %{}
    end
  end

  # A posted value as the draft holds it. What doesn't parse is kept as
  # text, for validation to reject with its message.
  defp value(%Field{type: :toggle}, raw), do: raw == "true"

  defp value(%Field{type: {:choices, _}}, raw) when is_list(raw),
    do: Enum.filter(raw, &is_binary/1)

  defp value(%Field{type: {:choices, _}}, _raw), do: []

  defp value(%Field{type: :secret}, raw) do
    case trim(raw) do
      "" -> nil
      value -> %Secret{value: value}
    end
  end

  defp value(%Field{type: :integer}, raw) do
    case trim(raw) do
      "" -> nil
      text -> parse(Integer.parse(text), text, & &1)
    end
  end

  defp value(%Field{type: :seconds}, raw) do
    case trim(raw) do
      "" -> nil
      text -> parse(Float.parse(text), text, &round(&1 * 1000))
    end
  end

  defp value(%Field{}, raw) do
    case trim(raw) do
      "" -> nil
      text -> text
    end
  end

  defp parse({number, ""}, _text, fun), do: fun.(number)
  defp parse(_result, text, _fun), do: text

  defp trim(raw) when is_binary(raw), do: String.trim(raw)
  defp trim(_raw), do: ""

  @doc """
  The inputs of a section, for the page to draw: `%{id:, field:, value:,
  set?:, error:, choices:}`. `value` is what the input shows (`nil` for a
  secret, seconds as a number for `:seconds`), `set?` whether a secret is
  saved, `choices` `{:ok, [{value, label}]}` or `{:error, text}` for a
  multiple choice (from `choices`, by id).
  """
  @spec inputs(Setup.section(), Setup.draft(), map(), map(), map()) :: [map()]
  def inputs(section, draft, public, errors, choices) do
    for {name, %Field{} = f} <- Setup.fields(section, draft) do
      id = {name, f.key}

      %{
        id: id,
        field: f,
        value: shown_value(f, Map.get(draft, id)),
        set?: f.type == :secret and Setup.secret_set?(id, draft, public),
        error: Map.get(errors, id),
        choices: Map.get(choices, id, {:error, "Not loaded"})
      }
    end
  end

  defp shown_value(%Field{type: :secret}, _value), do: nil
  defp shown_value(%Field{type: :seconds}, ms) when is_integer(ms), do: seconds(ms)
  defp shown_value(%Field{type: {:choices, _}}, value), do: List.wrap(value)
  defp shown_value(%Field{}, value), do: value

  @doc ~s{Milliseconds as the seconds a number input shows: `"6"`, `"1.5"`.}
  @spec seconds(integer()) :: String.t()
  def seconds(ms) when rem(ms, 1000) == 0, do: Integer.to_string(div(ms, 1000))
  def seconds(ms), do: :erlang.float_to_binary(ms / 1000, [:compact, decimals: 3])

  @doc "Whether the draft holds a secret that was typed (and won't be shown back)."
  @spec typed_secret?(Setup.draft()) :: boolean()
  def typed_secret?(draft), do: Enum.any?(draft, fn {_id, value} -> is_struct(value, Secret) end)
end
