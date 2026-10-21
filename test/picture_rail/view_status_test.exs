defmodule PictureRail.View.StatusTest do
  use ExUnit.Case, async: true

  alias PictureRail.View.Status

  @configured %{
    status: :ok,
    configured: %{photo_source: true, home_assistant: true},
    photo_source_type: "immich"
  }

  test "settings problems come first, then pointing at Setup" do
    assert Status.message(%{status: {:error, ["x"]}}, nil) == "picture_rail.json has errors"
    unset = %{status: :missing, configured: %{photo_source: false, home_assistant: false}}
    assert Status.message(unset, nil, nil) == "Tap to set up Wi-Fi"
    assert Status.message(unset, nil, %{status: :disconnected}) == "Tap to set up Wi-Fi"
    assert Status.message(unset, nil, %{status: :connected}) == "Tap to set up photos"
  end

  test "then the photo source's status: common ones, then the source's own" do
    assert Status.message(@configured, %{status: :invalid_key}) == "Immich API key rejected"

    assert Status.message(@configured, %{status: {:missing_permission, "Missing album.read"}}) ==
             "Missing album.read"

    assert Status.message(@configured, %{status: :no_albums}) == "No albums found"
    assert Status.message(@configured, %{status: :offline}) == "Immich offline"
    assert Status.message(@configured, %{status: :online, photos: 0}) == "No photos to show"
    assert Status.message(@configured, %{status: :online, photos: 5}) == "Loading photos"
    assert Status.message(@configured, %{status: :connecting, photos: 0}) == "Loading photos"
    assert Status.message(@configured, %{status: :something_new}) == "Loading photos"
    assert Status.message(@configured, nil) == "Loading photos"

    unknown = %{@configured | photo_source_type: "retired"}
    assert Status.message(unknown, %{status: :offline}) == "Photos offline"
    assert Status.message(unknown, %{status: :invalid_key}) == "Loading photos"
  end
end
