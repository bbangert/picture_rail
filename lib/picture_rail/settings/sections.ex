defmodule PictureRail.Settings.Sections do
  @moduledoc """
  The built-in sections of the settings file, declared as
  `PictureRail.Setup.Field`s: Home Assistant, and the slideshow, cache,
  panel and Live Photo timings. Photo sources declare their own
  (`PictureRail.PhotoSource`).
  """

  alias PictureRail.Setup.Field

  @doc "The built-in section names, in the order they're validated."
  @spec names() :: [String.t()]
  def names, do: ~w(home_assistant slideshow cache panel live_photo)

  @doc "The fields of a built-in section."
  @spec fields(String.t()) :: [Field.t()]
  def fields("home_assistant") do
    [
      %Field{
        key: "url",
        label: "Server URL",
        type: :url,
        required?: true,
        help: "e.g. http://homeassistant.local:8123"
      },
      %Field{
        key: "token",
        label: "Access token",
        type: :secret,
        required?: true,
        help: "A long-lived access token, from your Home Assistant profile"
      },
      %Field{
        key: "ssl_verify",
        label: "Check the certificate",
        type: :toggle,
        default: true,
        help: "Turn off for a self-signed certificate"
      }
    ]
  end

  def fields("slideshow") do
    [
      %Field{
        key: "interval_ms",
        label: "Photo interval",
        type: :seconds,
        default: 6_000,
        min: 1,
        max: 3_600_000,
        step: 1_000
      },
      %Field{
        key: "fade_ms",
        label: "Fade",
        type: :seconds,
        default: 1_500,
        min: 0,
        max: 10_000,
        step: 250,
        help: "Shorter than the photo interval"
      }
    ]
  end

  def fields("cache") do
    [
      %Field{
        key: "window",
        label: "Photos kept ready",
        type: :integer,
        default: 25,
        min: 1,
        max: 200,
        step: 5,
        help: "How many photos are downloaded ahead"
      },
      %Field{key: "include_live_photos", label: "Live Photos", type: :toggle, default: true}
    ]
  end

  def fields("panel") do
    [
      %Field{
        key: "timeout_ms",
        label: "Panel hides after",
        type: :seconds,
        default: 30_000,
        min: 1,
        max: 600_000,
        step: 5_000
      },
      %Field{
        key: "long_press_ms",
        label: "Long press",
        type: :seconds,
        default: 500,
        min: 1,
        max: 5_000,
        step: 100
      }
    ]
  end

  def fields("live_photo") do
    [
      %Field{
        key: "pause_ms",
        label: "Live Photo pause",
        type: :seconds,
        default: 3_000,
        min: 0,
        max: 60_000,
        step: 500
      }
    ]
  end

  @doc """
  The defaults of a section without credentials, with atom keys (the shape
  of `PictureRail.Settings`' timing sections).
  """
  @spec defaults(String.t()) :: map()
  def defaults(name), do: Map.new(fields(name), &{atom_key(&1.key), &1.default})

  @atom_keys Map.new(
               ~w(interval_ms fade_ms window include_live_photos timeout_ms long_press_ms pause_ms)a,
               &{Atom.to_string(&1), &1}
             )

  @doc "The atom key of a timing section's field."
  @spec atom_key(String.t()) :: atom()
  def atom_key(key), do: Map.fetch!(@atom_keys, key)
end
