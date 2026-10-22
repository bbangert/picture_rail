defmodule PictureRail.View.DetailTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Hassock.EntityState
  alias PictureRail.View.{Detail, Panel}

  defp es(id, state, attrs), do: %EntityState{entity_id: id, state: state, attributes: attrs}

  defp blocks(es, ha \\ %{}) do
    ctx = %{
      ha: Map.merge(%{states: %{es.entity_id => es}, sliders: %{}, armed: %{}}, ha),
      live?: true,
      content_w: 1574,
      portrait?: false
    }

    Detail.blocks(ctx, es.entity_id)
  end

  # every block built (rows hold functions for the page shown), as text
  defp shown(blocks) do
    blocks
    |> Enum.map(fn
      {:row, h, items, heading} ->
        {:row, h, Enum.map(items, &if(is_function(&1, 0), do: &1.(), else: &1)), heading}

      block ->
        block
    end)
    |> inspect(limit: :infinity, printable_limit: :infinity)
  end

  @t9 %EntityState{
    entity_id: "climate.t9",
    state: "heat_cool",
    attributes: %{
      "current_humidity" => 54,
      "current_temperature" => 73,
      "hvac_action" => "idle",
      "hvac_modes" => ["off", "heat", "cool", "heat_cool"],
      "max_temp" => 90,
      "min_temp" => 50,
      "supported_features" => 387,
      "target_temp_high" => 76,
      "target_temp_low" => 68,
      "temperature" => nil
    }
  }

  test "a thermostat in heat/cool: both ends of the range, readings and modes" do
    blocks = blocks(@t9)
    text = shown(blocks)

    assert [{:heading, _, "73° › 68–76°"} | _] = blocks
    assert text =~ "\"Heat to\""
    assert text =~ "\"Cool to\""
    assert text =~ "\"68°\""
    assert text =~ "\"76°\""
    assert text =~ "INSIDE 73°   ·   HUMIDITY 54%   ·   IDLE"
    assert text =~ "\"HEAT COOL\""
    refute text =~ "Target"
  end

  test "a thermostat with one target" do
    text =
      @t9
      |> Map.put(:state, "heat")
      |> put_in([Access.key(:attributes), "temperature"], 70)
      |> blocks()
      |> shown()

    assert text =~ "\"Target\""
    assert text =~ "\"70°\""
    refute text =~ "Heat to"
  end

  @anthem %EntityState{
    entity_id: "media_player.anthem",
    state: "on",
    attributes: %{
      "supported_features" => 69_004,
      "volume_level" => 0.4,
      "is_volume_muted" => false,
      "source_list" => ["Apple TV", "Blu-ray", "Game", "PC", "Tuner"],
      "source" => "Apple TV",
      "sound_mode_list" => Enum.map(1..17, &"Mode #{&1}"),
      "sound_mode" => "Mode 3"
    }
  }

  test "a receiver: power, volume, sources and every sound mode, but no transport" do
    blocks = blocks(@anthem)
    text = shown(blocks)

    for label <- ~w(ON OFF MUTE) ++ ["VOL −", "VOL +", "Sound mode", "MODE 17", "TUNER"],
        do: assert(text =~ "\"#{label}\"")

    refute text =~ "PAUSE"
    refute text =~ "\"PLAY\""
    refute text =~ "SHUFFLE"
    assert text =~ "{:slider, \"media_player.anthem\", :volume}"

    # long lists page like any view
    pages = Panel.paginate(blocks, 700)
    assert length(pages) > 1
    refute Enum.any?(blocks, &match?({:block, 0, _}, &1))
  end

  test "a music player: transport and now playing; volume buttons only when it steps" do
    player =
      es("media_player.kitchen", "playing", %{
        # pause, seek, prev/next, stop, play, shuffle, repeat
        "supported_features" => 1 ||| 2 ||| 16 ||| 32 ||| 4096 ||| 16_384 ||| 32_768 ||| 262_144,
        "media_title" => "Blue in Green",
        "media_artist" => "Miles Davis",
        "media_album_name" => "Kind of Blue",
        "shuffle" => true,
        "repeat" => "off"
      })

    text = player |> blocks() |> shown()

    for label <- ["‹‹", "PAUSE", "STOP", "››", "SHUFFLE", "REPEAT OFF", "BLUE IN GREEN"],
        do: assert(text =~ "\"#{label}\"")

    assert text =~ "MILES DAVIS  ·  KIND OF BLUE"
    refute text =~ "Volume"
    refute text =~ "\"ON\""
  end

  test "play and pause only as the player supports them" do
    only_play = es("media_player.a", "playing", %{"supported_features" => 16_384})
    text = only_play |> blocks() |> shown()
    refute text =~ "\"PAUSE\""
    refute text =~ "\"PLAY\""

    text = only_play |> Map.put(:state, "paused") |> blocks() |> shown()
    assert text =~ "\"PLAY\""

    only_pause = es("media_player.b", "idle", %{"supported_features" => 1})
    text = only_pause |> blocks() |> shown()
    refute text =~ "\"PLAY\""

    text = only_pause |> Map.put(:state, "playing") |> blocks() |> shown()
    assert text =~ "\"PAUSE\""
  end

  test "a colour light: colour sliders, swatches and effects" do
    hue =
      es("light.signe", "on", %{
        "supported_color_modes" => ["color_temp", "xy"],
        "supported_features" => 44,
        "brightness" => 128,
        "hs_color" => [30.0, 64.0],
        "min_color_temp_kelvin" => 2000,
        "max_color_temp_kelvin" => 6535,
        "color_temp_kelvin" => nil,
        "effect_list" => ["off", "candle", "fire"],
        "effect" => "off"
      })

    text = hue |> blocks() |> shown()

    for label <- ["Brightness", "Colour temperature", "Colour", "Effect", "CANDLE"],
        do: assert(text =~ "\"#{label}\"")

    assert text =~ "{:slider, \"light.signe\", :hue}"
    assert text =~ "{:slider, \"light.signe\", :saturation}"

    # a dimmer has none of it
    dimmer =
      es("light.hall", "on", %{"supported_color_modes" => ["brightness"], "brightness" => 255})

    text = dimmer |> blocks() |> shown()
    assert text =~ "\"Brightness\""
    refute text =~ "Colour"
    refute text =~ "Effect"
  end

  test "a lock asks to confirm an unlock" do
    lock = es("lock.garage", "locked", %{"supported_features" => 0})

    text = lock |> blocks() |> shown()
    assert text =~ "\"UNLOCK\""
    refute text =~ "CONFIRM"

    text = lock |> blocks(%{armed: %{"lock.garage" => :unlock}}) |> shown()
    assert text =~ "CONFIRM UNLOCK"
  end

  test "a select lists its options" do
    select = es("select.office_scene", "Relax", %{"options" => ["Blossom", "Relax"]})
    text = select |> blocks() |> shown()
    assert text =~ "\"BLOSSOM\""
    assert text =~ "\"RELAX\""
  end

  test "an Apple TV remote gets a D-pad; one whose commands aren't known doesn't" do
    remote = es("remote.loft", "on", %{"supported_features" => 0})

    text =
      remote |> blocks(%{slice: %{entity_id: "remote.loft", platform: "apple_tv"}}) |> shown()

    for label <- ~w(ON OFF BACK UP HOME LEFT OK RIGHT DOWN PLAY/PAUSE),
        do: assert(text =~ "\"#{label}\"")

    text =
      remote |> blocks(%{slice: %{entity_id: "remote.loft", platform: "broadlink"}}) |> shown()

    assert text =~ "\"ON\""
    refute text =~ "\"OK\""

    # Bravia has no toggle: Play and Pause
    text =
      remote |> blocks(%{slice: %{entity_id: "remote.loft", platform: "braviatv"}}) |> shown()

    assert text =~ "\"PLAY\""
    assert text =~ "\"PAUSE\""
    refute text =~ "PLAY/PAUSE"
  end

  test "a camera: its snapshot once downloaded" do
    camera = es("camera.door", "recording", %{})
    assert shown(blocks(camera)) =~ "LOADING"

    ctx = %{
      ha: %{states: %{"camera.door" => camera}, sliders: %{}, armed: %{}},
      pictures: %{entity_id: "camera.door", path: "/pics/door-1.jpg"},
      live?: true,
      content_w: 1574,
      content_h: 700,
      portrait?: false
    }

    assert [{:heading, _, "RECORDING"}, {:block, 634, picture}] =
             Detail.blocks(ctx, "camera.door")

    assert inspect(picture) =~ "/pics/door-1.jpg"

    # another entity's picture isn't this one's
    ctx = %{ctx | pictures: %{entity_id: "camera.yard", path: "/pics/yard-1.jpg"}}
    refute shown(Detail.blocks(ctx, "camera.door")) =~ "yard"
  end

  test "a grouping player: artwork with now playing, and the players to group with" do
    kitchen =
      es("media_player.kitchen", "playing", %{
        "supported_features" => 524_288,
        "media_title" => "So What",
        "group_members" => ["media_player.kitchen", "media_player.office"]
      })

    ctx = %{
      ha: %{
        states: %{
          "media_player.kitchen" => kitchen,
          "media_player.office" =>
            es("media_player.office", "playing", %{"supported_features" => 524_288}),
          "media_player.den" =>
            es("media_player.den", "unavailable", %{"supported_features" => 524_288}),
          "media_player.attic" => es("media_player.attic", "idle", %{"supported_features" => 0})
        },
        names: %{
          {"media_player.office", :full} => "Office speaker",
          {"media_player.den", :full} => "Den speaker",
          {"media_player.attic", :full} => "Attic speaker"
        },
        slice: %{
          entity_id: "media_player.kitchen",
          platform: "music_assistant",
          group: ["media_player.attic", "media_player.den", "media_player.office"]
        },
        sliders: %{},
        armed: %{}
      },
      pictures: %{entity_id: "media_player.kitchen", path: "/pics/art-1.png"},
      live?: true,
      content_w: 1574,
      portrait?: false
    }

    text = ctx |> Detail.blocks("media_player.kitchen") |> shown()
    assert text =~ "/pics/art-1.png"
    assert text =~ "\"SO WHAT\""
    assert text =~ "\"Group\""
    assert text =~ "\"OFFICE SPEAKER\""
    assert text =~ "\"DEN SPEAKER\""
    # one that can't group isn't offered
    refute text =~ "ATTIC SPEAKER"
  end

  test "an image not loaded yet says so, not LATEST" do
    assert [{:heading, _, "UNKNOWN"}] = blocks(es("image.porch", "unknown", %{}))
    assert [{:heading, _, "LATEST"} | _] = blocks(es("image.porch", "2026-10-21T19:08:34", %{}))
  end

  test "unusable: just the state" do
    assert [{:heading, _, "UNAVAILABLE"}] = blocks(es("lock.garage", "unavailable", %{}))
  end

  test "colours at full brightness" do
    assert Detail.hs_hex(0, 100) == 0xFF0000
    assert Detail.hs_hex(120, 100) == 0x00FF00
    assert Detail.hs_hex(240, 100) == 0x0000FF
    assert Detail.hs_hex(360, 100) == 0xFF0000
    assert Detail.hs_hex(200, 0) == 0xFFFFFF
  end
end
