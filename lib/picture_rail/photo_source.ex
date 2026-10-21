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

  The source also runs its own pipeline: `PictureRail.PhotoSource.Supervisor`
  starts the configured source's `child_spec/1` and swaps it when the type
  changes. The source's process re-reads its own settings (with
  credentials, from `PictureRail.Settings.current/0`) when they change, and
  reports its `stats/1` to the `:photos` controller. The slideshow asks
  `next/0` here for the next photo, which never waits on the network.

  Statuses common to every source are `:unconfigured`, `:connecting`,
  `:online` and `:offline`; anything else is the source's own, put into
  words by its `status_message/1`.
  """

  alias PictureRail.Setup.Field

  @registry PictureRail.PhotoSource.Registry

  @typedoc "A photo ready to show: the file, and its size when known."
  @type photo :: %{
          id: String.t(),
          path: Path.t(),
          width: pos_integer() | nil,
          height: pos_integer() | nil,
          clip: Path.t() | nil
        }

  @typedoc "Status and counts, for the UI and the IEx shell."
  @type stats :: %{
          status: :unconfigured | :connecting | :online | :offline | term(),
          photos: non_neg_integer(),
          ready: non_neg_integer(),
          window: non_neg_integer(),
          downloading?: boolean()
        }

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

  @doc """
  The choices for a `{:choices, _}` field (Immich: the albums), as
  `{value, label}`, fetched with `config` (complete settings, possibly not
  saved yet). May take a while; runs in a task.
  """
  @callback choices(field_key :: String.t(), config :: map()) ::
              {:ok, [{String.t(), String.t()}]} | {:error, String.t()}

  @doc """
  Whether the source works with `config` (the Setup page's "Test"):
  `:ok`, or what's wrong in a few words. Runs in a task.
  """
  @callback check(config :: map()) :: :ok | {:error, String.t()}

  @doc """
  The source's process. `opts` has `:name` (register under it) and
  `:config` (the settings it starts with).
  """
  @callback child_spec(opts :: keyword()) :: Supervisor.child_spec()

  @doc "The next photo to show, or `:none` yet. Must not wait on the network."
  @callback next(GenServer.server()) :: {:ok, photo()} | :none

  @doc "Status and counts. Must not wait on the network."
  @callback stats(GenServer.server()) :: stats()

  @doc "Words for a status of the source's own; `nil` for the common ones."
  @callback status_message(status :: term()) :: String.t() | nil

  @optional_callbacks status_message: 1

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

  @doc "The stats when no source is running."
  @spec unconfigured_stats() :: stats()
  def unconfigured_stats,
    do: %{status: :unconfigured, photos: 0, ready: 0, window: 0, downloading?: false}

  @doc "The running source's process and module, if one is running."
  @spec active(atom()) :: {pid(), module()} | nil
  def active(registry \\ @registry) do
    # The registry starts with `PictureRail.PhotoSource.Supervisor`, after
    # the app whose controllers ask.
    with pid when is_pid(pid) <- Process.whereis(registry),
         [{pid, module}] <- Registry.lookup(registry, :active) do
      {pid, module}
    else
      _ -> nil
    end
  end

  @doc "The next photo from the running source; `:none` when nothing is running."
  @spec next(atom()) :: {:ok, photo()} | :none
  def next(registry \\ @registry) do
    case active(registry) do
      {pid, module} -> module.next(pid)
      nil -> :none
    end
  catch
    # stopped between the lookup and the call (a settings change)
    :exit, _reason -> :none
  end

  @doc "The running source's stats; `unconfigured_stats/0` when nothing is running."
  @spec stats(atom()) :: stats()
  def stats(registry \\ @registry) do
    case active(registry) do
      {pid, module} -> module.stats(pid)
      nil -> unconfigured_stats()
    end
  catch
    :exit, _reason -> unconfigured_stats()
  end

  @doc "Words for a source's own status (`nil` when it has none)."
  @spec status_message(module(), term()) :: String.t() | nil
  def status_message(module, status) do
    if function_exported?(module, :status_message, 1), do: module.status_message(status)
  end
end
