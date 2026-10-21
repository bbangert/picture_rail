defmodule PictureRail.Settings do
  @moduledoc """
  The settings file (`PictureRail.Paths.settings_file/0`), parsed and
  validated.

  Everything but the credentials has a default. A missing `photo_source`
  or `home_assistant` section means that service isn't configured (the
  slideshow or panel says so); a section that is there must be complete.
  Each section is validated against its `PictureRail.Setup.Field`
  declarations: `PictureRail.Settings.Sections` for the built-in ones, the
  photo source's own (`PictureRail.PhotoSource`) for `photo_source`.

  Files written before photo sources existed have an `immich` section
  instead of `photo_source`; it is read as an Immich photo source (and
  renamed when the settings are next saved, see
  `PictureRail.Settings.Watcher.update/2`).

  The credentials are kept in `PictureRail.Settings.PhotoSource` and
  `PictureRail.Settings.HomeAssistant`, whose `inspect/1` leaves them out, so
  they don't end up in logs or crash reports.
  """

  require Logger

  alias PictureRail.PhotoSource, as: Sources
  alias PictureRail.Settings.{Sections, Watcher}
  alias PictureRail.Setup.Field

  defmodule Immich do
    @moduledoc """
    Immich server, API key and the albums to show, as the Immich client and
    cache use them (built from the photo source's settings by
    `PictureRail.Immich.Source.immich/1`).
    """
    @derive {Inspect, except: [:api_key]}
    @enforce_keys [:url, :api_key]
    defstruct [:url, :api_key, album_ids: [], album_names: []]

    @type t :: %__MODULE__{
            url: String.t(),
            api_key: String.t(),
            album_ids: [String.t()],
            album_names: [String.t()]
          }
  end

  defmodule HomeAssistant do
    @moduledoc "Home Assistant URL and long-lived access token."
    @derive {Inspect, except: [:token]}
    @enforce_keys [:url, :token]
    defstruct [:url, :token, ssl_verify: true]

    @type t :: %__MODULE__{url: String.t(), token: String.t(), ssl_verify: boolean()}
  end

  defmodule PhotoSource do
    @moduledoc """
    The photo source in use: its module (a `PictureRail.PhotoSource`) and
    its validated settings (string keys, without `"type"`). `inspect/1`
    leaves out the fields the module declares secret.
    """
    @enforce_keys [:module, :config]
    defstruct [:module, :config]

    @type t :: %__MODULE__{module: module(), config: map()}

    defimpl Inspect do
      import Inspect.Algebra

      def inspect(%{module: module, config: config}, opts) do
        shown = Map.drop(config, Field.secret_keys(module.fields()))

        concat([
          "#PictureRail.Settings.PhotoSource<",
          to_doc(module.type(), opts),
          " ",
          to_doc(shown, opts),
          ">"
        ])
      end
    end
  end

  defstruct photo_source: nil,
            home_assistant: nil,
            slideshow: Sections.defaults("slideshow"),
            cache: Sections.defaults("cache"),
            panel: Sections.defaults("panel"),
            live_photo: Sections.defaults("live_photo")

  @type t :: %__MODULE__{
          photo_source: PhotoSource.t() | nil,
          home_assistant: HomeAssistant.t() | nil,
          slideshow: %{interval_ms: pos_integer(), fade_ms: non_neg_integer()},
          cache: %{window: pos_integer(), include_live_photos: boolean()},
          panel: %{timeout_ms: pos_integer(), long_press_ms: pos_integer()},
          live_photo: %{pause_ms: non_neg_integer()}
        }

  @timing_sections %{
    "slideshow" => :slideshow,
    "cache" => :cache,
    "panel" => :panel,
    "live_photo" => :live_photo
  }

  @doc "The defaults: nothing configured, default timings."
  @spec defaults() :: t()
  def defaults, do: %__MODULE__{}

  @doc """
  Read and validate a settings file. A missing file gives the defaults
  (`{:error, :enoent}` is never returned).
  """
  @spec load(Path.t()) :: {:ok, t()} | {:error, [String.t()]}
  def load(path) do
    case File.read(path) do
      {:ok, json} -> decode(json)
      {:error, :enoent} -> {:ok, defaults()}
      {:error, reason} -> {:error, ["can't read #{path}: #{:file.format_error(reason)}"]}
    end
  end

  @doc "Validate the JSON text of a settings file."
  @spec decode(String.t()) :: {:ok, t()} | {:error, [String.t()]}
  def decode(json) do
    case Jason.decode(json) do
      {:ok, %{} = map} -> parse(map)
      {:ok, _other} -> {:error, ["the settings file must contain a JSON object"]}
      {:error, error} -> {:error, ["not valid JSON: #{Exception.message(error)}"]}
    end
  end

  @doc "Validate a decoded settings map (string keys)."
  @spec parse(map()) :: {:ok, t()} | {:error, [String.t()]}
  def parse(map) when is_map(map) do
    for key <- Map.keys(map) -- ["photo_source", "immich" | Sections.names()] do
      Logger.warning("Settings: ignoring unknown section #{inspect(key)}")
    end

    timings =
      for name <- Sections.names(), Map.has_key?(@timing_sections, name) do
        {@timing_sections[name], timings(map, name)}
      end

    {fields, errors} =
      [photo_source: photo_source(map), home_assistant: home_assistant(map)]
      |> Kernel.++(timings)
      |> Enum.reduce({[], []}, fn
        {key, {:ok, value}}, {fields, errors} -> {[{key, value} | fields], errors}
        {_key, {:error, more}}, {fields, errors} -> {fields, errors ++ more}
      end)

    case errors ++ cross_checks(Map.new(fields)) do
      [] -> {:ok, struct!(__MODULE__, fields)}
      errors -> {:error, errors}
    end
  end

  defp cross_checks(%{slideshow: %{interval_ms: interval, fade_ms: fade}}) when fade >= interval,
    do: ["slideshow.fade_ms must be shorter than slideshow.interval_ms"]

  defp cross_checks(_fields), do: []

  defp photo_source(map) do
    case {Map.get(map, "photo_source"), Map.get(map, "immich")} do
      {nil, nil} ->
        {:ok, nil}

      {nil, legacy} ->
        source(legacy, "immich", PictureRail.Immich.Source)

      {section, legacy} ->
        if legacy != nil,
          do: Logger.warning("Settings: both photo_source and immich are set; using photo_source")

        typed_source(section)
    end
  end

  defp typed_source(%{"type" => type} = section) do
    with true <- is_binary(type),
         {:ok, module} <- Sources.module_for(type) do
      source(Map.delete(section, "type"), "photo_source", module)
    else
      _ -> {:error, ["photo_source.type must be one of: #{Enum.join(Sources.types(), ", ")}"]}
    end
  end

  defp typed_source(%{}), do: {:error, ["photo_source.type is required"]}
  defp typed_source(_section), do: {:error, ["photo_source must be an object"]}

  defp source(%{} = section, name, module) do
    with {:ok, values} <- Field.validate(module.fields(), name, section),
         {:ok, config} <- module.validate(values) do
      {:ok, %PhotoSource{module: module, config: config}}
    end
  end

  defp source(_section, name, _module), do: {:error, ["#{name} must be an object"]}

  # A credential section: absent (or null) means not configured.
  defp home_assistant(map) do
    case Map.get(map, "home_assistant") do
      nil -> {:ok, nil}
      %{} = section -> home_assistant_section(section)
      _other -> {:error, ["home_assistant must be an object"]}
    end
  end

  defp home_assistant_section(section) do
    with {:ok, values} <-
           Field.validate(Sections.fields("home_assistant"), "home_assistant", section) do
      {:ok,
       %HomeAssistant{
         url: values["url"],
         token: values["token"],
         ssl_verify: values["ssl_verify"]
       }}
    end
  end

  # A section of timings and flags, each with a default.
  defp timings(map, name) do
    case Map.get(map, name, %{}) do
      %{} = section ->
        with {:ok, values} <- Field.validate(Sections.fields(name), name, section) do
          {:ok, Map.new(values, fn {key, value} -> {Sections.atom_key(key), value} end)}
        end

      _other ->
        {:error, ["#{name} must be an object"]}
    end
  end

  @doc """
  The values of one section (`"photo_source"`, `"home_assistant"` or a
  timing section) with string keys, as the settings file has them,
  credentials included; `nil` for a section that isn't configured. The
  photo source's include its `"type"`.
  """
  @spec values(t(), String.t()) :: map() | nil
  def values(%__MODULE__{photo_source: nil}, "photo_source"), do: nil

  def values(%__MODULE__{photo_source: %PhotoSource{} = source}, "photo_source"),
    do: Map.put(source.config, "type", source.module.type())

  def values(%__MODULE__{home_assistant: nil}, "home_assistant"), do: nil

  def values(%__MODULE__{home_assistant: %HomeAssistant{} = ha}, "home_assistant"),
    do: %{"url" => ha.url, "token" => ha.token, "ssl_verify" => ha.ssl_verify}

  def values(%__MODULE__{} = settings, name) when is_map_key(@timing_sections, name) do
    settings
    |> Map.fetch!(@timing_sections[name])
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  @doc """
  The fields of a section of these settings: the photo source's own for
  `"photo_source"` (none when no source is set up).
  """
  @spec fields(t(), String.t()) :: [Field.t()]
  def fields(%__MODULE__{photo_source: %PhotoSource{module: module}}, "photo_source"),
    do: module.fields()

  def fields(%__MODULE__{}, "photo_source"), do: []
  def fields(%__MODULE__{}, name), do: Sections.fields(name)

  @doc """
  Every credential (the secret fields of the photo source and Home
  Assistant), so a change to any of them can be noticed.
  """
  @spec credentials(t()) :: %{String.t() => map()}
  def credentials(%__MODULE__{} = settings) do
    for name <- ["photo_source", "home_assistant"], into: %{} do
      values = values(settings, name) || %{}
      {name, Map.take(values, Field.secret_keys(fields(settings, name)))}
    end
  end

  @doc """
  A copy with the credentials replaced by whether they are set
  (`"api_key_set?" => true`), for state that the UI holds. The
  `photo_source` and `home_assistant` sections have string keys, as their
  fields do; the timing sections are as in `t:t/0`.
  """
  @spec public(t()) :: map()
  def public(%__MODULE__{} = settings) do
    settings
    |> Map.from_struct()
    |> Map.put(:photo_source, public_section(settings, "photo_source"))
    |> Map.put(:home_assistant, public_section(settings, "home_assistant"))
  end

  defp public_section(settings, name) do
    case values(settings, name) do
      nil -> nil
      values -> Field.public(fields(settings, name), values)
    end
  end

  @doc "The current settings (from `PictureRail.Settings.Watcher`)."
  @spec current() :: t()
  defdelegate current(), to: Watcher

  @doc """
  Re-read the settings file now (also happens within ten seconds of a
  change). Returns `:ok` or the validation errors; on errors the previous
  settings stay in use.
  """
  @spec reload() :: :ok | {:error, [String.t()]}
  defdelegate reload(), to: Watcher

  @doc """
  Change one section of the settings file (`nil` removes it) and load the
  result. See `PictureRail.Settings.Watcher.update/2`.
  """
  @spec update(String.t(), map() | nil) :: :ok | {:error, [String.t()]}
  def update(section, values), do: Watcher.update(%{section => values})
end
