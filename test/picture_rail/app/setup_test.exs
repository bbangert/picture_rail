defmodule PictureRail.App.SetupTest do
  use ExUnit.Case, async: true

  alias PictureRail.App.Setup, as: Controller
  alias PictureRail.Settings
  alias PictureRail.Settings.Watcher
  alias PictureRail.Setup.Secret

  @moduletag :tmp_dir

  @immich %{
    "type" => "immich",
    "url" => "https://photos.example.com",
    "api_key" => "secret-key",
    "album_ids" => ["a1"]
  }

  defp deps(map) do
    {:ok, settings} = Settings.parse(map)
    configured = %{photo_source: settings.photo_source != nil, home_assistant: false}
    %{settings: %{settings: Settings.public(settings), configured: configured}}
  end

  # Runs the work in a task (as the app does) and records what it's given.
  defp callbacks(opts \\ []) do
    test = self()

    %{
      run: fn fun -> Task.async(fun) end,
      stored: fn name ->
        send(test, {:stored, name})
        Keyword.get(opts, :stored, @immich)
      end,
      save:
        Keyword.get(opts, :save, fn values ->
          send(test, {:save, values})
          :ok
        end)
    }
  end

  defp open(section, deps, callbacks),
    do: Controller.open(section, Controller.init(nil, deps), deps, callbacks)

  # The task's reply, handed to the controller as Solve would.
  defp settle(state) do
    receive do
      {ref, _result} = message when is_reference(ref) -> Controller.task_reply(message, state)
    after
      1_000 -> flunk("no task reply")
    end
  end

  defp exposed(state, deps), do: Controller.expose(state, deps, nil)

  test "edits: set, toggle, steps within bounds, choices" do
    deps = deps(%{})
    state = open(:display, deps, callbacks())
    interval = {"slideshow", "interval_ms"}

    state = Controller.step({interval, 1}, state)
    assert state.draft[interval] == 7_000

    state =
      Enum.reduce(1..10, state, fn _, s -> Controller.step({{"slideshow", "fade_ms"}, -1}, s) end)

    assert state.draft[{"slideshow", "fade_ms"}] == 0

    state = Controller.toggle({"cache", "include_live_photos"}, state)
    assert state.draft[{"cache", "include_live_photos"}] == false

    # not a field of this section: ignored
    assert Controller.set({{"photo_source", "url"}, "x"}, state) == state
    assert exposed(state, deps).busy?
  end

  test "opening the photo source loads its choices with the stored credentials" do
    deps = deps(%{"photo_source" => @immich})
    state = open(:photo_source, deps, callbacks())
    id = {"photo_source", "album_ids"}
    assert state.choices[id] == :loading
    assert exposed(state, deps).busy?

    Req.Test.stub(PictureRail.Immich.Source, fn conn ->
      Req.Test.json(conn, [%{"id" => "a1", "albumName" => "Frame", "assetCount" => 2}])
    end)

    state = settle(state)
    assert_received {:stored, "photo_source"}
    assert {:ok, [{"a1", "Frame (2 photos)"}]} = state.choices[id]

    state = Controller.toggle_choice({id, "a2"}, state)
    assert state.draft[id] == ["a1", "a2"]
  end

  test "a result for an editor that moved on is dropped" do
    deps = deps(%{"photo_source" => @immich})
    Req.Test.stub(PictureRail.Immich.Source, fn conn -> Req.Test.json(conn, []) end)
    _loading = open(:photo_source, deps, callbacks())
    moved_on = open(:display, deps, callbacks())

    receive do
      {ref, _} = message when is_reference(ref) ->
        assert Controller.task_reply(message, moved_on) == moved_on
    after
      1_000 -> flunk("no task reply")
    end
  end

  test "save sends only typed secrets, and errors land on their fields" do
    deps = deps(%{"photo_source" => @immich})
    state = open(:home_assistant, deps, callbacks())
    state = Controller.set({{"home_assistant", "url"}, "http://ha"}, state)

    state = Controller.save(nil, state, deps, callbacks())
    assert exposed(state, deps).saving?
    state = settle(state)
    assert_received {:save, %{"home_assistant" => values}}
    assert values == %{"url" => "http://ha", "ssl_verify" => true}
    assert state.message == {:ok, "Saved"}

    typed = Controller.set({{"home_assistant", "token"}, %Secret{value: "tok"}}, state)
    typed = Controller.save(nil, typed, deps, callbacks()) |> settle()
    assert_received {:save, %{"home_assistant" => %{"token" => "tok"}}}
    # saved: the typed secret leaves the draft
    refute Map.has_key?(typed.draft, {"home_assistant", "token"})
  end

  test "save against a real watcher: errors mapped, success written", %{tmp_dir: dir} do
    path = Path.join(dir, "picture_rail.json")
    name = :"watcher_#{System.unique_integer([:positive])}"
    start_supervised!({Watcher, path: path, name: name, notify: fn _, _ -> :ok end})
    cbs = callbacks(save: &Watcher.update(&1, name))
    deps = deps(%{})

    state = open(:home_assistant, deps, cbs)
    state = Controller.set({{"home_assistant", "url"}, "ha.lan"}, state)
    state = Controller.save(nil, state, deps, cbs) |> settle()

    assert state.errors == %{
             {"home_assistant", "url"} => "must start with http:// or https://",
             {"home_assistant", "token"} => "is required"
           }

    assert state.message == {:error, "Check the fields marked"}
    refute File.exists?(path)

    state = Controller.set({{"home_assistant", "url"}, "http://ha.lan"}, state)
    refute Map.has_key?(state.errors, {"home_assistant", "url"})
    state = Controller.set({{"home_assistant", "token"}, %Secret{value: "tok"}}, state)
    state = Controller.save(nil, state, deps, cbs) |> settle()
    assert state.message == {:ok, "Saved"}
    assert Watcher.current(name).home_assistant.token == "tok"
    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
  end

  test "test runs the source's check with the draft" do
    deps = deps(%{"photo_source" => @immich})

    Req.Test.stub(PictureRail.Immich.Source, fn conn ->
      conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{})
    end)

    # opening loads the albums first
    state = open(:photo_source, deps, callbacks()) |> settle()
    assert state.choices[{"photo_source", "album_ids"}] == {:error, "API key rejected"}

    state = Controller.test(nil, state, deps, callbacks())
    assert state.check == :running
    state = settle(state)
    assert state.check == {:error, "API key rejected"}
  end

  test "discard goes back to what's saved; close ends editing" do
    deps = deps(%{})
    state = open(:display, deps, callbacks())
    changed = Controller.step({{"slideshow", "interval_ms"}, 1}, state)
    assert Controller.discard(nil, changed, deps).draft == state.draft
    refute exposed(Controller.discard(nil, changed, deps), deps).busy?
    assert exposed(Controller.close(nil, changed), deps).section == nil
  end

  test "nothing typed stays out of what's exposed" do
    deps = deps(%{"photo_source" => @immich})
    state = %{open(:photo_source, deps, callbacks()) | pending: %{}}
    state = Controller.set({{"photo_source", "api_key"}, %Secret{value: "typed-key"}}, state)
    refute inspect(exposed(state, deps)) =~ "typed-key"
    refute inspect(exposed(state, deps)) =~ "secret-key"
  end
end
