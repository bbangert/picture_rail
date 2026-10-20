defmodule HomeFrame.App.SettingsTest do
  use ExUnit.Case, async: true

  alias HomeFrame.App.Settings, as: Controller
  alias HomeFrame.Settings

  test "exposes the status, what's configured, and no credentials" do
    {:ok, settings} =
      Settings.parse(%{"home_assistant" => %{"url" => "http://ha", "token" => "secret"}})

    state = Controller.loaded({settings, :ok}, Controller.init(nil, %{}))
    exposed = Controller.expose(state, %{}, nil)

    assert %{loaded?: true, status: :ok, configured: %{immich: false, home_assistant: true}} =
             exposed

    refute inspect(exposed) =~ "secret"
  end

  test "an invalid file is reported but not loaded" do
    exposed = Controller.expose({Settings.defaults(), {:error, ["x"]}}, %{}, nil)
    assert %{loaded?: false, status: {:error, ["x"]}} = exposed
  end

  test "the running app's controller picks up the watcher's settings" do
    exposed = Solve.subscribe(HomeFrame.App, :settings)
    assert %{status: status} = exposed
    assert status in [:ok, :missing, :template]
  end
end
