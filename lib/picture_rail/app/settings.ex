defmodule PictureRail.App.Settings do
  @moduledoc """
  `:settings` controller: the settings in use, without credentials, and the
  status of the settings file.

  Fed by `PictureRail.Settings.Watcher`. Code that needs the credentials
  (the Immich and Home Assistant clients) reads them from
  `PictureRail.Settings.current/0` instead, so they never sit in UI state.

  Exposes:

    * `:loaded?` - the file was read and validated
    * `:status` - `:ok`, `:missing`, `:template` (not filled in yet) or
      `{:error, messages}` (the previous settings stay in use)
    * `:configured` - `%{immich: boolean, home_assistant: boolean}`
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
    rev = if credentials(settings) == credentials(old), do: rev, else: rev + 1
    {settings, status, rev}
  end

  defp credentials(settings) do
    {settings.immich && settings.immich.api_key,
     settings.home_assistant && settings.home_assistant.token}
  end

  @impl Solve.Controller
  def expose({settings, status, credentials_rev}, _dependencies, _params) do
    %{
      loaded?: status == :ok,
      status: status,
      configured: %{
        immich: settings.immich != nil,
        home_assistant: settings.home_assistant != nil
      },
      settings: Settings.public(settings),
      credentials_rev: credentials_rev
    }
  end
end
