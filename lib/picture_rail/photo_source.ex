defmodule PictureRail.PhotoSource do
  @moduledoc """
  Where the slideshow's photos come from.

  A photo source is a module implementing this behaviour. It declares its
  settings as `PictureRail.Setup.Field`s, which the settings file's
  `photo_source` section is validated against and the Setup page and web
  page render their forms from:

      {"photo_source": {"type": "immich", "url": "...", "api_key": "...", "album_ids": []}}

  The sources the frame knows are listed in the application environment
  (`config :picture_rail, photo_sources: [PictureRail.Immich.Source]`).
  """

  alias PictureRail.Setup.Field

  @doc "The value of the `type` key that selects this source (`\"immich\"`)."
  @callback type() :: String.t()

  @doc "The source's name, as shown on the Setup page (`\"Immich\"`)."
  @callback label() :: String.t()

  @doc "The source's settings."
  @callback fields() :: [Field.t()]

  @doc """
  Checks beyond the fields' own, run on values that passed
  `PictureRail.Setup.Field.validate/3`.
  """
  @callback validate(config :: map()) :: {:ok, map()} | {:error, [String.t()]}

  @doc "The photo source modules the frame knows."
  @spec sources() :: [module()]
  def sources, do: Application.get_env(:picture_rail, :photo_sources, [PictureRail.Immich.Source])

  @doc "The source for a `type` value."
  @spec module_for(String.t()) :: {:ok, module()} | :error
  def module_for(type) do
    case Enum.find(sources(), &(&1.type() == type)) do
      nil -> :error
      module -> {:ok, module}
    end
  end

  @doc "The `type` values of the known sources."
  @spec types() :: [String.t()]
  def types, do: Enum.map(sources(), & &1.type())
end
