defmodule PictureRail.Settings do
  @moduledoc """
  The settings file (`PictureRail.Paths.settings_file/0`), parsed and
  validated.

  Everything but the credentials has a default. A missing `immich` or
  `home_assistant` section means that service isn't configured (the
  slideshow or panel says so); a section that is there must be complete.

  The credentials are kept in `PictureRail.Settings.Immich` and
  `PictureRail.Settings.HomeAssistant`, whose `inspect/1` leaves them out, so
  they don't end up in logs or crash reports.
  """

  require Logger

  defmodule Immich do
    @moduledoc "Immich server, API key and the albums to show."
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

  defstruct immich: nil,
            home_assistant: nil,
            slideshow: %{interval_ms: 6_000, fade_ms: 1_500},
            cache: %{window: 25, include_live_photos: true},
            panel: %{timeout_ms: 30_000, long_press_ms: 500},
            live_photo: %{pause_ms: 3_000}

  @type t :: %__MODULE__{
          immich: Immich.t() | nil,
          home_assistant: HomeAssistant.t() | nil,
          slideshow: %{interval_ms: pos_integer(), fade_ms: non_neg_integer()},
          cache: %{window: pos_integer(), include_live_photos: boolean()},
          panel: %{timeout_ms: pos_integer(), long_press_ms: pos_integer()},
          live_photo: %{pause_ms: non_neg_integer()}
        }

  @sections ~w(immich home_assistant slideshow cache panel live_photo)

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
    for key <- Map.keys(map) -- @sections do
      Logger.warning("Settings: ignoring unknown section #{inspect(key)}")
    end

    d = defaults()

    {fields, errors} =
      [
        immich: section(map, "immich", &immich/1),
        home_assistant: section(map, "home_assistant", &home_assistant/1),
        slideshow: timings(map, "slideshow", d.slideshow, interval_ms: :pos, fade_ms: :non_neg),
        cache: timings(map, "cache", d.cache, window: :pos, include_live_photos: :bool),
        panel: timings(map, "panel", d.panel, timeout_ms: :pos, long_press_ms: :pos),
        live_photo: timings(map, "live_photo", d.live_photo, pause_ms: :non_neg)
      ]
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

  # A credential section: absent (or null) means not configured.
  defp section(map, name, parse) do
    case Map.get(map, name) do
      nil -> {:ok, nil}
      %{} = section -> parse.(section)
      _other -> {:error, ["#{name} must be an object"]}
    end
  end

  defp immich(section) do
    errors =
      url_errors(section, "immich") ++
        string_errors(section, "immich", "api_key") ++
        list_errors(section, "immich", "album_ids") ++
        list_errors(section, "immich", "album_names")

    if errors == [] do
      {:ok,
       %Immich{
         url: trim_url(section["url"]),
         api_key: section["api_key"],
         album_ids: Map.get(section, "album_ids", []),
         album_names: Map.get(section, "album_names", [])
       }}
    else
      {:error, errors}
    end
  end

  defp home_assistant(section) do
    ssl_errors =
      case Map.get(section, "ssl_verify", true) do
        verify when is_boolean(verify) -> []
        _ -> ["home_assistant.ssl_verify must be true or false"]
      end

    errors =
      url_errors(section, "home_assistant") ++
        string_errors(section, "home_assistant", "token") ++ ssl_errors

    if errors == [] do
      {:ok,
       %HomeAssistant{
         url: trim_url(section["url"]),
         token: section["token"],
         ssl_verify: Map.get(section, "ssl_verify", true)
       }}
    else
      {:error, errors}
    end
  end

  defp url_errors(section, name) do
    case section["url"] do
      "http://" <> _ -> []
      "https://" <> _ -> []
      nil -> ["#{name}.url is required"]
      _ -> ["#{name}.url must start with http:// or https://"]
    end
  end

  defp string_errors(section, name, key) do
    case section[key] do
      value when is_binary(value) and value != "" -> []
      nil -> ["#{name}.#{key} is required"]
      _ -> ["#{name}.#{key} must be a non-empty string"]
    end
  end

  defp list_errors(section, name, key) do
    case Map.get(section, key, []) do
      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1),
          do: [],
          else: ["#{name}.#{key} must be a list of strings"]

      _ ->
        ["#{name}.#{key} must be a list of strings"]
    end
  end

  defp trim_url(url), do: String.trim_trailing(url, "/")

  # A section of timings and flags, each with a default.
  defp timings(map, name, defaults, kinds) do
    case Map.get(map, name, %{}) do
      %{} = section -> check_timings(section, name, defaults, kinds)
      _other -> {:error, ["#{name} must be an object"]}
    end
  end

  defp check_timings(section, name, defaults, kinds) do
    values =
      Map.new(kinds, fn {key, _kind} ->
        {key, Map.get(section, Atom.to_string(key), Map.fetch!(defaults, key))}
      end)

    case for(
           {key, kind} <- kinds,
           not valid?(kind, values[key]),
           do: "#{name}.#{key} #{describe(kind)}"
         ) do
      [] -> {:ok, values}
      errors -> {:error, errors}
    end
  end

  defp valid?(:pos, value), do: is_integer(value) and value > 0
  defp valid?(:non_neg, value), do: is_integer(value) and value >= 0
  defp valid?(:bool, value), do: is_boolean(value)

  defp describe(:pos), do: "must be a positive integer"
  defp describe(:non_neg), do: "must be a non-negative integer"
  defp describe(:bool), do: "must be true or false"

  @doc """
  A copy with the credentials replaced by whether they are set, for state
  that the UI holds.
  """
  @spec public(t()) :: map()
  def public(%__MODULE__{} = settings) do
    settings
    |> Map.from_struct()
    |> Map.update!(:immich, fn
      nil -> nil
      immich -> immich |> Map.from_struct() |> Map.delete(:api_key)
    end)
    |> Map.update!(:home_assistant, fn
      nil -> nil
      ha -> ha |> Map.from_struct() |> Map.delete(:token)
    end)
  end

  @doc "The current settings (from `PictureRail.Settings.Watcher`)."
  @spec current() :: t()
  defdelegate current(), to: PictureRail.Settings.Watcher

  @doc """
  Re-read the settings file now (also happens within ten seconds of a
  change). Returns `:ok` or the validation errors; on errors the previous
  settings stay in use.
  """
  @spec reload() :: :ok | {:error, [String.t()]}
  defdelegate reload(), to: PictureRail.Settings.Watcher
end
