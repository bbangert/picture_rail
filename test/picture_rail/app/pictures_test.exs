defmodule PictureRail.App.PicturesTest do
  use ExUnit.Case, async: true

  alias PictureRail.App.Pictures

  # callbacks that tell the test what the controller did
  defp callbacks do
    test = self()

    %{
      fetch: fn id, last_url ->
        ref = make_ref()
        send(test, {:fetch, id, last_url, ref})
        %{ref: ref}
      end,
      discard: &send(test, {:discard, &1})
    }
  end

  defp fetched(state, result) do
    assert_received {:fetch, _id, _url, ref}
    {Pictures.handle_info({ref, result}, state, %{}, callbacks()), ref}
  end

  test "a camera's detail: fetched at once, then every few seconds" do
    state = Pictures.view({:entity, "camera.door"}, Pictures.init(nil, %{}), %{}, callbacks())

    assert Pictures.expose(state, %{}, nil) == %{
             entity_id: "camera.door",
             path: nil,
             previous: nil
           }

    {state, _ref} = fetched(state, {:ok, "/pics/door-1.jpg", "http://ha/door"})
    assert %{path: "/pics/door-1.jpg", previous: nil} = Pictures.expose(state, %{}, nil)

    # the refresh: the new picture over the last one, which stays until the next
    state = Pictures.handle_info({:refresh, state.timer}, state, %{}, callbacks())
    {state, _ref} = fetched(state, {:ok, "/pics/door-2.jpg", "http://ha/door"})

    assert %{path: "/pics/door-2.jpg", previous: "/pics/door-1.jpg"} =
             Pictures.expose(state, %{}, nil)

    refute_received {:discard, "/pics/door-1.jpg"}

    state = Pictures.handle_info({:refresh, state.timer}, state, %{}, callbacks())
    {state, _ref} = fetched(state, {:ok, "/pics/door-3.jpg", "http://ha/door"})
    assert_received {:discard, "/pics/door-1.jpg"}

    assert %{path: "/pics/door-3.jpg", previous: "/pics/door-2.jpg"} =
             Pictures.expose(state, %{}, nil)

    # unchanged or failed: the picture stays
    state = Pictures.handle_info({:refresh, state.timer}, state, %{}, callbacks())
    assert_received {:fetch, "camera.door", "http://ha/door", _}
    {state, _ref} = fetched_again(state, {:error, :timeout})
    assert %{path: "/pics/door-3.jpg"} = Pictures.expose(state, %{}, nil)
  end

  defp fetched_again(state, result) do
    ref = state.ref
    {Pictures.handle_info({ref, result}, state, %{}, callbacks()), ref}
  end

  test "leaving the detail removes the picture and ignores what comes after" do
    state = Pictures.view({:entity, "image.porch"}, Pictures.init(nil, %{}), %{}, callbacks())
    {state, _ref} = fetched(state, {:ok, "/pics/porch-1.jpg", "u"})
    timer = state.timer
    state = Pictures.handle_info({:refresh, timer}, state, %{}, callbacks())
    assert_received {:fetch, "image.porch", "u", late}

    state = Pictures.view(:overview, state, %{}, callbacks())
    assert_received {:discard, "/pics/porch-1.jpg"}
    assert Pictures.expose(state, %{}, nil) == %{entity_id: nil, path: nil, previous: nil}

    # a download that finishes now is removed, and no refresh follows
    assert Pictures.handle_info({late, {:ok, "/pics/porch-2.jpg", "u"}}, state, %{}, callbacks()) ==
             state

    assert_received {:discard, "/pics/porch-2.jpg"}
    assert Pictures.handle_info({:refresh, timer}, state, %{}, callbacks()) == state
    refute_received {:fetch, _, _, _}
  end

  test "only cameras, images and media players; the same view again is nothing new" do
    state = Pictures.view({:entity, "light.hall"}, Pictures.init(nil, %{}), %{}, callbacks())
    assert Pictures.expose(state, %{}, nil).entity_id == nil
    refute_received {:fetch, _, _, _}

    state = Pictures.view({:entity, "media_player.tv"}, state, %{}, callbacks())
    assert_received {:fetch, "media_player.tv", nil, _}
    assert Pictures.view({:entity, "media_player.tv"}, state, %{}, callbacks()) == state
    refute_received {:fetch, _, _, _}
  end
end
