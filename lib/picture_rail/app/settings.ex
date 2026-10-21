defmodule PictureRail.App.Settings do
  @moduledoc """
  `:settings` controller: the settings in use, without credentials, and the
  status of the settings file.

  Fed by `PictureRail.Settings.Watcher`. Code that needs the credentials
  (the photo source and the Home Assistant client) reads them from
  `PictureRail.Settings.current/0` instead, so they never sit in UI state.

  Exposes:

    * `:loaded?` - the file was read and validated
    * `:status` - `:ok`, `:missing`, `:template` (not filled in yet) or
      `{:error, messages}` (the previous settings stay in use)
    * `:configured` - `%{photo_source: boolean, home_assistant: boolean}`
    * `:photo_source_type` - the photo source's `type` (`"immich"`), or nil
    * `:settings` - `PictureRail.Settings.public/1` of the settings
    * `:credentials_rev` - bumped when a reload changes a credential, so
      subscribers that read them hear about a new key or token (the
      other exposed values don't change with it)
  """
  use Solve.Controller, events: [:loaded]

  alias PictureRail.Settings

  @impl Solve.Controller
  def init(_params, _dependencies) do
    # A restarted controller picks the settings up again from the watcher.
    {settings, status} =
      if Process.whereis(Settings.Watcher),
        do: Settings.Watcher.state(),
        else: {Settings.defaults(), :missing}

    {settings, status, 0}
  end

  def loaded({settings, status}, {old, _status, rev}) do
    rev =
      if Settings.credentials(settings) == Settings.credentials(old), do: rev, else: rev + 1

    {settings, status, rev}
  end

  @impl Solve.Controller
  def expose({settings, status, credentials_rev}, _dependencies, _params) do
    %{
      loaded?: status == :ok,
      status: status,
      configured: %{
        photo_source: settings.photo_source != nil,
        home_assistant: settings.home_assistant != nil
      },
      photo_source_type: settings.photo_source && settings.photo_source.module.type(),
      settings: Settings.public(settings),
      credentials_rev: credentials_rev
    }
  end
end
