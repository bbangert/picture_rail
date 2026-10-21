defmodule PictureRail.Setup do
  @moduledoc """
  The sections of the Setup page and the drafts they're edited in, as pure
  functions over `PictureRail.Setup.Field` declarations (the frame's
  `:setup` controller and the web page share them).

  A section shows fields of one or more sections of the settings file:

    * `:wifi` - not in the settings file: the network to join
      (`PictureRail.Network`), with a `"mode"` of `:list` (picking from the
      scan), `:picked` (a listed network: its password) or `:other` (a
      hidden one: name, security, password)
    * `:photo_source` - the photo source's own fields (`"photo_source"`)
    * `:home_assistant` - `"home_assistant"`
    * `:display` - "Slideshow & panel": `"slideshow"`, `"cache"`,
      `"panel"` and `"live_photo"`

  A field is addressed by its id, `{file_section, key}`. A draft maps ids to
  values. Stored secrets are never in a draft: a secret the user types is
  held as a `PictureRail.Setup.Secret`, and one left alone is left out of
  the saved values, so the stored one is kept.
  """

  alias PictureRail.PhotoSource
  alias PictureRail.Settings.Sections
  alias PictureRail.Setup.{Field, Secret}

  @type section :: :wifi | :photo_source | :home_assistant | :display
  @type id :: {String.t(), String.t()}
  @type draft :: %{id() => term()}

  @display ~w(slideshow cache panel live_photo)

  @doc "The sections, in the order the Setup page lists them."
  @spec sections() :: [section()]
  def sections, do: [:wifi, :photo_source, :home_assistant, :display]

  @doc "A section's title."
  @spec label(section()) :: String.t()
  def label(:wifi), do: "Wi-Fi"
  def label(:photo_source), do: "Photos"
  def label(:home_assistant), do: "Home Assistant"
  def label(:display), do: "Slideshow & panel"

  @doc "The id of the photo source's type in a draft."
  @spec type_id() :: id()
  def type_id, do: {"photo_source", "type"}

  @doc """
  The fields a section shows (`ui?` ones only), with the file section each
  belongs to. For `:photo_source`, those of the draft's source type.
  """
  @spec fields(section(), draft()) :: [{String.t(), Field.t()}]
  def fields(:wifi, draft) do
    ssid = %Field{key: "ssid", label: "Network name", type: :text, required?: true, max: 32}

    secured = %Field{key: "secured", label: "Password protected", type: :toggle, default: true}

    password = %Field{
      key: "password",
      label: "Password",
      type: :secret,
      max: 63,
      help: "WPA2: 8 to 63 characters"
    }

    fields =
      case draft[wifi_id("mode")] do
        :other -> [ssid, secured] ++ if(draft[wifi_id("secured")], do: [password], else: [])
        :picked -> if draft[wifi_id("secured")], do: [password], else: []
        _list -> []
      end

    for f <- fields, do: {"wifi", f}
  end

  def fields(:photo_source, draft) do
    case source(draft) do
      nil -> []
      module -> for %Field{ui?: true} = f <- module.fields(), do: {"photo_source", f}
    end
  end

  def fields(:home_assistant, _draft),
    do: for(f <- Sections.fields("home_assistant"), do: {"home_assistant", f})

  def fields(:display, _draft),
    do: for(name <- @display, f <- Sections.fields(name), do: {name, f})

  @doc "The file sections a section saves."
  @spec file_sections(section()) :: [String.t()]
  def file_sections(:wifi), do: []
  def file_sections(:photo_source), do: ["photo_source"]
  def file_sections(:home_assistant), do: ["home_assistant"]
  def file_sections(:display), do: @display

  @doc ~s{The id of a Wi-Fi draft value: `"mode"`, `"ssid"`, ...}
  @spec wifi_id(String.t()) :: id()
  def wifi_id(key), do: {"wifi", key}

  @doc """
  A Wi-Fi draft for joining a listed network (`PictureRail.Network.networks/1`)
  or, with `nil`, one typed in by hand.
  """
  @spec wifi_draft(map() | nil) :: draft()
  def wifi_draft(%{ssid: ssid, security: security}) do
    %{
      wifi_id("mode") => :picked,
      wifi_id("ssid") => ssid,
      wifi_id("secured") => security != :open,
      wifi_id("hidden") => false
    }
  end

  def wifi_draft(nil) do
    %{
      wifi_id("mode") => :other,
      wifi_id("ssid") => "",
      wifi_id("secured") => true,
      wifi_id("hidden") => true
    }
  end

  @doc """
  What to join from a Wi-Fi draft: `{:ok, {ssid, password | nil, hidden?}}`,
  or errors by field id.
  """
  @spec wifi_join(draft()) :: {:ok, {String.t(), String.t() | nil, boolean()}} | {:error, map()}
  def wifi_join(draft) do
    ssid = String.trim(draft[wifi_id("ssid")] || "")

    password =
      case draft[wifi_id("password")] do
        %Secret{value: value} -> value
        _ -> ""
      end

    secured? = draft[wifi_id("secured")] == true

    errors =
      %{}
      |> then(&if(ssid == "", do: Map.put(&1, wifi_id("ssid"), "is required"), else: &1))
      |> then(
        &if(secured? and password == "",
          do: Map.put(&1, wifi_id("password"), "is required"),
          else: &1
        )
      )

    if errors == %{},
      do: {:ok, {ssid, if(secured?, do: password), draft[wifi_id("hidden")] == true}},
      else: {:error, errors}
  end

  @doc "The photo source module a draft is for (`nil` if its type is unknown)."
  @spec source(draft()) :: module() | nil
  def source(draft) do
    case PhotoSource.module_for(Map.get(draft, type_id(), "")) do
      {:ok, module} -> module
      :error -> nil
    end
  end

  @doc """
  A fresh draft of a section from the settings the UI holds
  (`PictureRail.Settings.public/1`): what's saved, or the defaults.
  """
  @spec draft(section(), map()) :: draft()
  def draft(:wifi, _public), do: %{wifi_id("mode") => :list}

  def draft(:photo_source, public) do
    stored = public.photo_source || %{}
    type = Map.get(stored, "type") || hd(PhotoSource.types())
    with_type = %{type_id() => type}
    stored = if stored["type"] == type, do: stored, else: %{}
    Map.merge(with_type, values_of(fields(:photo_source, with_type), stored))
  end

  def draft(section, public) do
    section
    |> fields(%{})
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.reduce(%{}, fn {name, fields}, draft ->
      Map.merge(draft, values_of(fields, stored(public, name)))
    end)
  end

  defp stored(public, name) do
    case Map.get(public, String.to_existing_atom(name)) do
      nil -> %{}
      map -> Map.new(map, fn {key, value} -> {to_string(key), value} end)
    end
  end

  defp values_of(fields, stored) do
    for {name, %Field{} = f} <- fields, f.type != :secret, into: %{} do
      {{name, f.key}, Map.get(stored, f.key, f.default)}
    end
  end

  @doc """
  Whether a secret field has a stored value, from the public settings
  (`"<key>_set?"`). A photo source of another type than the stored one has
  none.
  """
  @spec secret_set?(id(), draft(), map()) :: boolean()
  def secret_set?({"photo_source", key}, draft, public) do
    stored = public.photo_source || %{}
    stored["type"] == draft[type_id()] and stored[key <> "_set?"] == true
  end

  def secret_set?({"wifi", _key}, _draft, _public), do: false

  def secret_set?({name, key}, _draft, public),
    do: stored(public, name)[key <> "_set?"] == true

  @doc """
  The draft as `PictureRail.Settings.Watcher.update/2` takes it: values by
  file section, typed secrets unwrapped, untouched (or emptied) ones left
  out so the stored value is kept.
  """
  @spec values(section(), draft()) :: %{String.t() => map()}
  def values(section, draft) do
    base =
      for name <- file_sections(section), into: %{}, do: {name, %{}}

    base =
      if section == :photo_source,
        do: Map.put(base, "photo_source", %{"type" => draft[type_id()]}),
        else: base

    Enum.reduce(fields(section, draft), base, fn {name, field}, acc ->
      case {field.type, Map.get(draft, {name, field.key})} do
        {:secret, %Secret{value: value}} when value != "" -> put_in(acc, [name, field.key], value)
        {:secret, _} -> acc
        {_type, value} -> put_in(acc, [name, field.key], value)
      end
    end)
  end

  @doc """
  The photo source settings to try a draft with (Test, loading choices):
  the draft over the stored ones (`PictureRail.Settings.values/2`, with
  credentials), so a secret that wasn't retyped is the stored one. Another
  type than the stored one starts from nothing.
  """
  @spec source_config(draft(), map() | nil) :: map()
  def source_config(draft, stored) do
    stored = if stored && stored["type"] == draft[type_id()], do: stored, else: %{}
    Map.merge(stored, values(:photo_source, draft)["photo_source"])
  end

  @doc "Step an `:integer` or `:seconds` value by one `step` up (`1`) or down (`-1`)."
  @spec step(Field.t(), integer() | nil, 1 | -1) :: integer()
  def step(%Field{} = field, value, direction) do
    step = field.step || 1
    value = (value || field.default || 0) + direction * step
    value = if field.min, do: Kernel.max(value, field.min), else: value
    if field.max, do: Kernel.min(value, field.max), else: value
  end

  @doc "Add `choice` to a multi-choice value, or take it out."
  @spec toggle_choice([String.t()] | nil, String.t()) :: [String.t()]
  def toggle_choice(list, choice) do
    list = list || []
    if choice in list, do: List.delete(list, choice), else: list ++ [choice]
  end

  @doc """
  Validation messages (`"slideshow.fade_ms must be ..."`) sorted onto the
  fields of a section by their `file_section.key` prefix; the rest are
  returned for the section as a whole.
  """
  @spec field_errors(section(), draft(), [String.t()]) :: {%{id() => String.t()}, [String.t()]}
  def field_errors(section, draft, messages) do
    ids = for {name, f} <- fields(section, draft), do: {name, f.key}

    Enum.reduce(messages, {%{}, []}, fn message, {by_field, rest} ->
      case on_field(ids, message) do
        {id, detail} -> {Map.put_new(by_field, id, detail), rest}
        nil -> {by_field, rest ++ [message]}
      end
    end)
  end

  defp on_field(ids, message) do
    Enum.find_value(ids, fn {name, key} = id ->
      prefix = "#{name}.#{key} "

      if String.starts_with?(message, prefix),
        do: {id, String.replace_prefix(message, prefix, "")}
    end)
  end

  @doc "The field a section shows under an id."
  @spec field(section(), draft(), id()) :: Field.t() | nil
  def field(section, draft, {name, key}) do
    Enum.find_value(fields(section, draft), fn
      {^name, %Field{key: ^key} = f} -> f
      _ -> nil
    end)
  end
end
