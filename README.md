# Picture Rail

A Home Assistant dashboard and photo frame for Nerves touch displays.

- Full-screen photos from your [Immich](https://immich.app) albums, with
  GPU crossfades. A rolling cache of the next photos keeps the slideshow
  going when the network is down.
- Tap the screen for an LCARS-style panel with every Home Assistant
  device, organised like Home Assistant's Overview dashboard: floors,
  areas, then lights, climate, media and the rest. Tap to toggle, long-press
  for details (brightness, setpoints, cover position, volume). The panel
  hides itself after a while and the slideshow resumes.
- The UI and photos rotate with the device when it has an orientation
  sensor.

It is built with [Emerge](https://hex.pm/packages/emerge) (Skia on the
GPU), [Solve](https://hex.pm/packages/solve) for state, and
[hassock](https://hex.pm/packages/hassock) for Home Assistant.

## Supported hardware

| Target | Device | Nerves system |
|---|---|---|
| `frame156` | Pastigio FRAME156 (Rockchip PX30, 1920x1080 touch) | [nerves_system_rk3326_frame156](https://github.com/bbangert/nerves_system_rk3326_frame156) |
| host | your laptop (a window, for development) | - |

### Adding another touch display

Everything device-specific is behind `PictureRail.Hardware`
(`lib/picture_rail/hardware.ex`). To run Picture Rail on another Nerves device
with a touchscreen and a GPU (or enough CPU for raster rendering):

1. Add its Nerves system to `deps/0` in `mix.exs` and its target name to
   `@all_targets`.
2. Write `lib/picture_rail/hardware/<device>.ex` implementing the behaviour:
   `children/0` for any sensors or boot-time tweaks, `emerge_config/0` for
   the display output, renderer and input, and `screen_size/0` (DRM devices
   can use `PictureRail.Hardware.drm_screen_size/1`); see
   `PictureRail.Hardware.Frame156`. If the device can sense its
   orientation, report changes with `PictureRail.Orientation.report/1`.
3. Add `config/<target>.exs` with
   `config :picture_rail, hardware: PictureRail.Hardware.<Device>, data_dir: "/root"`.

## Building

You need the host tools in `mise.toml` (the host's major OTP must match
the target system's) and the Nerves bootstrap archive
(`mix archive.install hex nerves_bootstrap`).

```sh
mix deps.get
mix test                  # host tests
mix run --no-halt         # run on the host in a window (needs settings, below)

export MIX_TARGET=frame156
mix deps.get
mix firmware
```

The FRAME156 system is used from a local checkout until it publishes
release artifacts: by default `../nerves_system_rk3326_frame156`, or set
`FRAME156_SYSTEM_PATH`.

### SSH keys

The firmware authorizes your `~/.ssh/id_*.pub` keys and any `*.pub` in
this project's `.ssh/` directory (git-ignored). To make a key just for the
device:

```sh
ssh-keygen -t ed25519 -N '' -f .ssh/picture_rail_ed25519
```

### FRAME156 touchscreen firmware

The GSL3676 touch controller needs a firmware blob that can't be
redistributed. If you build the system yourself with the blob in its
`rootfs_overlay/lib/firmware/silead/`, it's already in the image.
Otherwise (a system release artifact can't include it), extract it from
your own frame's stock kernel with the system repo's script and put it in
this project (the path is git-ignored):

```sh
../nerves_system_rk3326_frame156/scripts/extract-touch-fw.py \
  <backup>/parts/p5-kernel.img.gz \
  rootfs_overlay/lib/firmware/silead/gsl3676.fw
```

The backup has to be taken while the frame still runs Android: installing
Nerves overwrites the stock kernel. The system README's
[Touchscreen](https://github.com/bbangert/nerves_system_rk3326_frame156#touchscreen)
section has every step, from the backup to checking `silead_ts` on the
frame.

### Installing

Upload new firmware over SSH. The device tries it once: it's marked good
once the viewport has been up for 30 seconds (`PictureRail.FirmwareGuard`),
and if that hasn't happened within 3 minutes, or the device restarts
before then, it falls back to the previous firmware:

```sh
ssh -i .ssh/picture_rail_ed25519 -s <device-ip> fwup < _build/frame156_dev/nerves/images/picture_rail.fw
```

## Setting up

Everything can be set up on the frame. Editing the settings file
([Settings](#settings)) still works too.

On first boot (no Wi-Fi saved, no Ethernet and nothing set up), the frame
opens Setup on its Wi-Fi page a few seconds after it starts. Any other
time, tap the screen and choose **Setup**, the last item in the panel's
navigation. Setup has four sections:

- **Wi-Fi**: choose a network (or OTHER NETWORK... for a hidden one), type
  the password on the on-screen keyboard and tap JOIN. The frame tries the
  network for up to 30 seconds and saves it only once it has an address.
  A wrong password, or a network out of reach, puts the previous one back.
- **Photos**: the photo source and its settings. For Immich, that's the
  server URL and the API key, then LOAD lists your albums to choose from.
  TEST checks the connection without saving.
- **Home Assistant**: the URL and a long-lived access token.
- **Slideshow & panel**: the photo interval and fade, how many photos
  are kept ready, Live Photos, and the panel's timings.

Changes are kept as a draft until SAVE, which checks them as the settings
file is checked. DISCARD drops the draft.

### From a phone or laptop

Keys and tokens are long to type on the frame, so the frame also serves a
settings page on your network (port 80, or 4080 on the host):
`http://<hostname>.local`, advertised over mDNS. While the frame is
connected, Setup shows a QR code, the address and a 6-digit code beside
its sections.

- Scanning the QR code pairs the phone: the code is in the link.
- In any other browser, open the address and type the code.

Each code pairs one device and then changes; it also changes by itself
every 30 minutes, and five wrong tries change it and lock pairing for a
minute (doubling each time, up to an hour). A paired browser stays paired for 12 hours.
FORGET DEVICES on the frame logs every paired browser out.

The page has the same sections as the frame, apart from Wi-Fi (changing it
from the network you're on would cut the page off). Keys and tokens are
never shown back: leave the field empty to keep the saved one. Albums are
listed from the saved connection, so on a new frame save the URL and key
first. The page is plain HTTP on your local network, like the Home
Assistant connection can be: pair only on a network you trust.

## Settings

Settings live in a JSON file in the data directory: `/root/picture_rail.json`
on the device (`tmp/data/picture_rail.json` on the host). There's none until
something is set up. You can also edit it over SSH; Picture Rail notices
changes within ten seconds, or run `PictureRail.Settings.reload()` in the
device's IEx shell to see any validation errors straight away. An invalid
file is logged and the previous settings stay in use.

```json
{
  "photo_source": {
    "type": "immich",
    "url": "https://photos.example.com",
    "api_key": "...",
    "album_ids": ["8b0c...", "1f2e..."]
  },
  "home_assistant": {
    "url": "http://homeassistant.local:8123",
    "token": "..."
  },
  "slideshow": {"interval_ms": 6000, "fade_ms": 1500},
  "cache": {"window": 25, "include_live_photos": true},
  "panel": {"timeout_ms": 30000, "long_press_ms": 500},
  "live_photo": {"pause_ms": 3000}
}
```

Files from earlier versions have an `"immich"` section (the same keys,
without `"type"`) instead of `"photo_source"`. It still works, and becomes
`"photo_source"` the next time the frame saves the settings.

Only the credentials are required; everything else has the defaults
shown. Leave a section out to switch that service off. Picture Rail keeps
the file readable only by its owner (mode 0600).

`home_assistant.ssl_verify` (default `true`) can be set to `false` for a
self-signed certificate on an `https://` URL.

### Adding a photo source

A photo source is a module implementing the `PictureRail.PhotoSource`
behaviour (`PictureRail.Immich.Source` is the example):

- `type/0` is the value of `photo_source.type` that selects it, and
  `label/0` its name on the Setup page.
- `fields/0` declares its settings as `PictureRail.Setup.Field`s (URL,
  text, secret, toggle, integer, seconds, or choices). The settings file
  is validated against them, and the frame's Setup page and the web page
  draw their forms from them, so the source needs no UI code.
  `validate/1` adds any checks across fields.
- `choices/2` lists the choices for a `{:choices, :multi}` field (Immich's
  albums) and `check/1` tests a connection. Both may be slow: they run in a
  task.
- `child_spec/1` starts its process, which fetches and caches photos;
  `next/1` and `stats/1` answer the slideshow and the UI without waiting
  on the network.

Then list it, with the sources you keep:

```elixir
config :picture_rail, photo_sources: [PictureRail.Immich.Source, MySource]
```

### Immich API key

Create an API key in Immich (Account settings, API keys) with these
permissions:

- `album.read` - list albums and notice changes
- `asset.read` - list the photos in the selected albums
- `asset.view` - download previews and Live Photo clips

Picture Rail downloads Immich's preview images (1440 px JPEG by default), not
the originals, so it doesn't need `asset.download`. If the server's
preview format is set to WebP, previews are skipped with a warning; switch
it back to JPEG in Immich's image settings.

Album ids are the last part of an album's URL in the Immich web app.

### Home Assistant token

Create a long-lived access token in Home Assistant (your profile,
Security, Long-lived access tokens). The panel shows every device the
token's user can see.

With an `https://` URL the certificate is verified against the system CA
store. Nerves systems usually don't have one, in which case hassock logs
a warning and connects without verification. Plain `http://` on your
local network sends the token unencrypted. On Nerves, `.local` names need
mDNS name resolution set up; an IP address or a regular DNS name always
works.

## Fonts

Antonio and Noto Sans, both under the SIL Open Font License; see
`priv/fonts/README.md`. "LCARS-style" describes the look only; Picture Rail
ships no Star Trek assets.
