defmodule PictureRail.View.StatusTest do
  use ExUnit.Case, async: true

  alias PictureRail.View.Status

  @configured %{status: :ok, configured: %{immich: true, home_assistant: true}}

  test "settings problems come first" do
    assert Status.message(%{status: :template}, nil) == "Set up picture_rail.json"
    assert Status.message(%{status: {:error, ["x"]}}, nil) == "picture_rail.json has errors"

    assert Status.message(%{status: :ok, configured: %{immich: false}}, nil) ==
             "Immich isn't set up"
  end

  test "then the cache's status" do
    assert Status.message(@configured, %{status: :invalid_key}) == "Immich API key rejected"

    assert Status.message(@configured, %{status: {:missing_permission, "Missing album.read"}}) ==
             "Missing album.read"

    assert Status.message(@configured, %{status: :offline}) == "Immich offline"
    assert Status.message(@configured, %{status: :online, photos: 0}) == "The albums are empty"
    assert Status.message(@configured, %{status: :online, photos: 5}) == "Loading photos"
  end
end
