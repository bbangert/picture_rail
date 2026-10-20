defmodule HomeFrame.App.Settings do
  @moduledoc """
  `:settings` controller: the settings in use, without credentials, and the
  status of the settings file.

  Fed by `HomeFrame.Settings.Watcher`. Code that needs the credentials
  (the Immich and Home Assistant clients) reads them from
  `HomeFrame.Settings.current/0` instead, so they never sit in UI state.

  Exposes:

    * `:loaded?` - the file was read and validated
    * `:status` - `:ok`, `:missing`, `:template` (not filled in yet) or
      `{:error, messages}` (the previous settings stay in use)
    * `:configured` - `%{immich: boolean, home_assistant: boolean}`
    * `:settings` - `HomeFrame.Settings.public/1` of the settings
  """
  use Solve.Controller, events: [:loaded]

  alias HomeFrame.Settings

  @impl Solve.Controller
  def init(_params, _dependencies) do
    # A restarted controller picks the settings up again from the watcher.
    if Process.whereis(Settings.Watcher),
      do: Settings.Watcher.state(),
      else: {Settings.defaults(), :missing}
  end

  def loaded({settings, status}, _state), do: {settings, status}

  @impl Solve.Controller
  def expose({settings, status}, _dependencies, _params) do
    %{
      loaded?: status == :ok,
      status: status,
      configured: %{
        immich: settings.immich != nil,
        home_assistant: settings.home_assistant != nil
      },
      settings: Settings.public(settings)
    }
  end
end
