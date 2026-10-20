defmodule PictureRail.App.SettingsTest do
  use ExUnit.Case, async: true

  alias PictureRail.App.Settings, as: Controller
  alias PictureRail.Settings

  test "exposes the status, what's configured, and no credentials" do
    {:ok, settings} =
      Settings.parse(%{"home_assistant" => %{"url" => "http://ha", "token" => "secret"}})

    state = Controller.loaded({settings, :ok}, Controller.init(nil, %{}))
    exposed = Controller.expose(state, %{}, nil)

    assert %{loaded?: true, status: :ok, configured: %{immich: false, home_assistant: true}} =
             exposed

    refute inspect(exposed) =~ "secret"
  end

  test "a new key or token changes what's exposed; other reloads don't" do
    ha = fn token ->
      {:ok, s} = Settings.parse(%{"home_assistant" => %{"url" => "http://ha", "token" => token}})
      s
    end

    state = Controller.loaded({ha.("one"), :ok}, {Settings.defaults(), :missing, 0})
    rev = Controller.expose(state, %{}, nil).credentials_rev

    same = Controller.loaded({ha.("one"), :ok}, state)
    assert Controller.expose(same, %{}, nil).credentials_rev == rev

    rotated = Controller.loaded({ha.("two"), :ok}, same)
    assert Controller.expose(rotated, %{}, nil).credentials_rev == rev + 1
    refute inspect(Controller.expose(rotated, %{}, nil)) =~ "two"
  end

  test "an invalid file is reported but not loaded" do
    exposed = Controller.expose({Settings.defaults(), {:error, ["x"]}, 0}, %{}, nil)
    assert %{loaded?: false, status: {:error, ["x"]}} = exposed
  end

  test "a (re)started controller picks the settings up from the running watcher" do
    # the watcher is the app's singleton; its first report can come before
    # the app is up, so init's read is what a fresh controller has
    {settings, status, 0} = Controller.init(nil, %{})
    assert {settings, status} == Settings.Watcher.state()
    refute match?({_, :missing}, Settings.Watcher.state())
  end
end
