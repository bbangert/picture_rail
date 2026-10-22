defmodule PictureRail.View.Detail do
  @moduledoc """
  An entity's detail view, as the panel's blocks (headings, rows of a
  known height), so a long one, like a TV's sources or a light's effects,
  pages like any other view.

  What it offers follows the entity's `supported_features`
  (`PictureRail.HA.Features`) and attributes:

    * light: on/off, brightness, colour temperature, colour (hue and
      saturation sliders, swatches), effects
    * climate: readings, the target or the heat/cool range (−/+), and its
      mode, fan, preset and swing lists
    * cover: open/stop/close, position
    * media player: power, transport, shuffle/repeat, now playing (with
      its artwork), volume (slider, −/+, mute), sources, sound modes, and
      the players it can group with
    * lock: lock, and unlock/open behind a confirming second press
    * select: its options
    * remote: on/off, and a D-pad for integrations whose commands are
      known (Apple TV, Bravia)
    * camera, image: the picture, as large as the page allows

  Every control sends its request (`PictureRail.HA.Actions`) to the `:ha`
  controller. Pictures come from `:pictures` (`ctx.pictures`), which
  downloads them while the detail is shown.
  """
  use Emerge.UI

  use Solve.Lookup, :helpers

  import Bitwise

  alias Emerge.UI.Color
  alias PictureRail.HA.{Actions, Features, Index, Overview}
  alias PictureRail.View.{Format, LCARS, Theme}

  @max_w 1100
  @gap 12
  @button_w 200
  @slider_h 80
  @readout_h 44
  @art 200
  @color_modes ~w(hs xy rgb rgbw rgbww)

  # warm to cool white, for the colour temperature slider's track
  @kelvin_track [0xFF9A3C, 0xFFE4C4, 0xDDE6FF]

  # hue, saturation: red, orange, yellow, green, cyan, blue, purple, pink
  @swatches [
    {0, 100},
    {30, 100},
    {55, 100},
    {120, 100},
    {180, 100},
    {225, 100},
    {275, 100},
    {320, 100}
  ]

  @doc """
  The blocks of `entity_id`'s detail: its state as the heading, then its
  controls while it's usable. `ctx` is the panel's (`ha`, `live?`,
  `content_w`, `portrait?`).
  """
  @spec blocks(map(), String.t()) :: [tuple()]
  def blocks(ctx, entity_id) do
    es = ctx.ha.states[entity_id]
    domain = Index.domain(entity_id)
    color = Theme.domain(domain)
    top = {:heading, color, Format.state(es)}

    ctx =
      Map.merge(ctx, %{id: entity_id, color: color, detail_w: Kernel.min(ctx.content_w, @max_w)})

    if ctx.live? and Overview.available?(es),
      do: [top | controls(ctx, domain, es, top)],
      else: [top]
  end

  # -- Per domain --

  defp controls(ctx, "light", es, top) do
    attrs = es.attributes
    modes = attrs["supported_color_modes"] || []
    on? = es.state == "on"
    turn = &%{domain: "light", service: &1, entity_id: ctx.id, optimistic: &2}

    brightness =
      if modes in [[], ["onoff"]],
        do: [],
        else:
          slider_section(
            ctx,
            "Brightness",
            :brightness,
            {1, 100, 1},
            round((attrs["brightness"] || 0) / 255 * 100)
          )

    temp =
      with true <- "color_temp" in modes,
           min when is_number(min) <- attrs["min_color_temp_kelvin"],
           max when is_number(max) <- attrs["max_color_temp_kelvin"] do
        slider_section(
          ctx,
          "Colour temperature",
          :color_temp,
          {min, max, 50},
          attrs["color_temp_kelvin"] || min,
          track: Color.gradient(Enum.map(@kelvin_track, &Theme.color/1), 0),
          filled: nil
        )
      else
        _ -> []
      end

    colour = if Enum.any?(modes, &(&1 in @color_modes)), do: colour(ctx, es), else: []
    effects = if Features.has?(es, :effect), do: options(ctx, "Effect", es, :effect), else: []

    buttons(ctx, top, [
      button(ctx, "On", call(ctx, turn.("turn_on", "on")), on?),
      button(ctx, "Off", call(ctx, turn.("turn_off", "off")), not on?)
    ]) ++ brightness ++ temp ++ colour ++ effects
  end

  defp controls(ctx, "climate", es, _top) do
    attrs = es.attributes

    setpoints =
      cond do
        Actions.range?(es) ->
          stepper(ctx, es, "Heat to", :low, attrs["target_temp_low"]) ++
            stepper(ctx, es, "Cool to", :high, attrs["target_temp_high"])

        is_number(attrs["temperature"]) ->
          stepper(ctx, es, "Target", :temperature, attrs["temperature"])

        true ->
          []
      end

    readout(climate_readings(attrs)) ++
      setpoints ++
      options(ctx, "Mode", es, :hvac_mode) ++
      options(ctx, "Fan", es, :fan_mode) ++
      options(ctx, "Preset", es, :preset_mode) ++
      options(ctx, "Swing", es, :swing_mode)
  end

  defp controls(ctx, "cover", es, top) do
    request = &%{domain: "cover", service: &1, entity_id: ctx.id}

    buttons =
      [
        {:open, "Open", "open_cover", es.state == "open"},
        {:stop, "Stop", "stop_cover", false},
        {:close, "Close", "close_cover", es.state == "closed"}
      ]
      |> Enum.filter(fn {feature, _, _, _} -> Features.has?(es, feature) end)
      |> Enum.map(fn {_, label, service, active?} ->
        button(ctx, label, call(ctx, request.(service)), active?)
      end)

    position =
      case es.attributes["current_position"] do
        p when is_number(p) ->
          if Features.has?(es, :set_position),
            do: slider_section(ctx, "Position", :position, {0, 100, 1}, p),
            else: []

        _ ->
          []
      end

    buttons(ctx, top, buttons) ++ position
  end

  defp controls(ctx, "media_player", es, top) do
    has? = &Features.has?(es, &1)

    buttons(ctx, top, media_power(ctx, es) ++ transport(ctx, es)) ++
      now_playing(ctx, es.attributes) ++
      volume(ctx, es) ++
      if(has?.(:select_source), do: options(ctx, "Source", es, :source), else: []) ++
      if(has?.(:select_sound_mode), do: options(ctx, "Sound mode", es, :sound_mode), else: []) ++
      group(ctx, es)
  end

  defp controls(ctx, "lock", es, top) do
    armed = Map.get(Map.get(ctx.ha, :armed) || %{}, ctx.id)

    open =
      if Features.has?(es, :open),
        do: [guarded(ctx, :open, "Open", armed, es.state == "open")],
        else: []

    buttons(
      ctx,
      top,
      [
        button(ctx, "Lock", call(ctx, Actions.lock(ctx.id, :lock)), es.state == "locked"),
        guarded(ctx, :unlock, "Unlock", armed, es.state == "unlocked")
      ] ++ open
    )
  end

  defp controls(ctx, domain, es, _top) when domain in ["select", "input_select"],
    do: options(ctx, "Options", es, :option)

  defp controls(ctx, "remote", es, top) do
    on? = es.state == "on"
    turn = &%{domain: "remote", service: &1, entity_id: ctx.id, optimistic: &2}

    pad =
      case Map.get(ctx.ha, :slice) do
        %{platform: platform} -> Actions.pad(platform)
        _ -> nil
      end

    buttons(ctx, top, [
      button(ctx, "On", call(ctx, turn.("turn_on", "on")), on?),
      button(ctx, "Off", call(ctx, turn.("turn_off", "off")), not on?)
    ]) ++ if(pad, do: dpad(ctx, pad), else: [])
  end

  defp controls(ctx, domain, _es, _top) when domain in ["camera", "image"] do
    # the page less its heading
    h = Map.get(ctx, :content_h, 600) - 66

    case picture(ctx) do
      nil ->
        readout(["Loading"])

      path ->
        [{:block, h, picture_el(ctx, path, ctx.content_w, h)}]
    end
  end

  defp controls(ctx, _domain, es, top) do
    case Actions.tap(ctx.id, es) do
      nil ->
        []

      request ->
        label = if request[:optimistic], do: "Toggle", else: "Run"
        buttons(ctx, top, [button(ctx, label, call(ctx, request), true)])
    end
  end

  # -- Climate --

  defp climate_readings(attrs) do
    [
      attrs["current_temperature"] && "Inside #{Format.temperature(attrs["current_temperature"])}",
      attrs["current_humidity"] && "Humidity #{attrs["current_humidity"]}%",
      attrs["hvac_action"] && String.replace(attrs["hvac_action"], "_", " ")
    ]
  end

  # A value between − and +; a press at a limit does nothing.
  defp stepper(ctx, es, title, which, value) do
    heading = {:heading, ctx.color, title}

    step = fn label, dir ->
      case Actions.climate_target(es, which, dir) do
        nil -> button(ctx, label, nil, false, font: 56)
        request -> button(ctx, label, call(ctx, request), true, font: 56)
      end
    end

    value =
      el(
        [width(px(220)), height(px(Theme.size(:pill))), Font.size(64)] ++
          [Font.color(Theme.color(ctx.color))],
        el([center_x(), center_y()], text(Format.temperature(value)))
      )

    [heading, {:row, Theme.size(:pill), [step.("−", -1), value, step.("+", 1)], heading}]
  end

  # -- Media players --

  defp media_power(ctx, es) do
    off? = es.state in ~w(off standby)

    if(Features.has?(es, :turn_on),
      do: [button(ctx, "On", call(ctx, Actions.power(ctx.id, true)), not off?)],
      else: []
    ) ++
      if Features.has?(es, :turn_off),
        do: [button(ctx, "Off", call(ctx, Actions.power(ctx.id, false)), off?)],
        else: []
  end

  # Each button with the features that offer it (any of them).
  defp transport(ctx, es) do
    attrs = es.attributes
    media = &call(ctx, Actions.media(ctx.id, &1))
    repeat = attrs["repeat"] || "off"

    # playing: Pause, if it can; otherwise: Play, if it can
    {play, play_feature, play_service} =
      if es.state == "playing",
        do: {"Pause", :pause, "media_pause"},
        else: {"Play", :play, "media_play"}

    [
      {[:previous_track], fn -> button(ctx, "‹‹", media.("media_previous_track"), false) end},
      {[play_feature], fn -> button(ctx, play, media.(play_service), true) end},
      {[:stop], fn -> button(ctx, "Stop", media.("media_stop"), false) end},
      {[:next_track], fn -> button(ctx, "››", media.("media_next_track"), false) end},
      {[:shuffle_set],
       fn ->
         button(ctx, "Shuffle", call(ctx, Actions.toggle_shuffle(es)), attrs["shuffle"] == true)
       end},
      {[:repeat_set],
       fn ->
         button(ctx, "Repeat #{repeat}", call(ctx, Actions.cycle_repeat(es)), repeat != "off")
       end}
    ]
    |> Enum.filter(fn {features, _button} -> Enum.any?(features, &Features.has?(es, &1)) end)
    |> Enum.map(fn {_features, button} -> button.() end)
  end

  defp now_playing(ctx, %{"media_title" => title} = attrs) when is_binary(title) do
    by =
      [attrs["media_artist"], attrs["media_album_name"]]
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.join("  ·  ")

    art = picture(ctx)
    text_w = if art, do: ctx.detail_w - @art - 24, else: ctx.detail_w
    chars = trunc(text_w / (Theme.size(:heading) * 0.45))

    words =
      column([spacing(8), Font.color(Theme.color(:peach))], [
        el([Font.size(Theme.size(:heading))], text(String.upcase(LCARS.fit(title, chars)))),
        el([Font.size(Theme.size(:small))], text(String.upcase(by)))
      ])

    case art do
      nil ->
        [{:block, 76, words}]

      path ->
        cover = picture_el(ctx, path, @art, @art)
        [{:block, @art, row([spacing(24)], [cover, el([center_y()], words)])}]
    end
  end

  defp now_playing(_ctx, _attrs), do: []

  defp volume(ctx, es) do
    heading = {:heading, ctx.color, "Volume"}
    level = es.attributes["volume_level"]
    media = &call(ctx, Actions.media(ctx.id, &1))

    slider =
      if Features.has?(es, :volume_set) and is_number(level),
        do: [slider_row(ctx, heading, :volume, {0, 100, 1}, round(level * 100))],
        else: []

    steps =
      if Features.has?(es, :volume_step),
        do: [
          button(ctx, "Vol −", media.("volume_down"), false),
          button(ctx, "Vol +", media.("volume_up"), false)
        ],
        else: []

    mute =
      if Features.has?(es, :volume_mute),
        do: [
          button(
            ctx,
            "Mute",
            call(ctx, Actions.toggle_mute(es)),
            es.attributes["is_volume_muted"] == true
          )
        ],
        else: []

    case slider ++ buttons(ctx, heading, steps ++ mute) do
      [] -> []
      rows -> [heading | rows]
    end
  end

  # Players of the same integration that can join this one's group: the
  # ones in it bright; a press puts one in or takes it out.
  defp group(ctx, es) do
    with %{group: others} <- Map.get(ctx.ha, :slice),
         heading = {:heading, ctx.color, "Group"},
         [_ | _] = rows <- group_rows(ctx, es, others, heading) do
      [heading | rows]
    else
      _ -> []
    end
  end

  defp group_rows(ctx, es, others, heading) do
    members = List.wrap(es.attributes["group_members"])
    cols = if ctx.portrait?, do: 2, else: 3
    w = Float.floor((ctx.detail_w - (cols - 1) * @gap) / cols)

    others
    |> Enum.filter(&Features.has?(ctx.ha.states[&1], :grouping))
    |> Enum.map(fn other -> fn -> group_pill(ctx, es, other, other in members, w) end end)
    |> Enum.chunk_every(cols)
    |> Enum.map(&{:row, Theme.size(:pill), &1, heading})
  end

  defp group_pill(ctx, es, other, member?, w) do
    chars = trunc((w - 60) / (Theme.size(:label) * 0.42))
    name = Map.get(Map.get(ctx.ha, :names) || %{}, {other, :full}, other)
    usable? = Overview.available?(ctx.ha.states[other])

    LCARS.pill(
      label: name |> LCARS.fit(chars) |> String.upcase(),
      fill: Theme.color(if(member?, do: ctx.color, else: Theme.dim(ctx.color))),
      width: px(w),
      attrs: if(usable?, do: [Event.on_press(call(ctx, Actions.group(es, other)))], else: [])
    )
  end

  # -- Remotes --

  defp dpad(ctx, pad) do
    heading = {:heading, ctx.color, "Remote"}
    key = &button(ctx, &1, call(ctx, Actions.command(ctx.id, Map.fetch!(pad, &2))), true)
    blank = el([width(px(@button_w)), height(px(Theme.size(:pill)))], none())

    # one toggle where the integration has it, else Play and Pause
    last =
      if Map.has_key?(pad, :play_pause),
        do: [key.("Play/Pause", :play_pause), key.("Down", :down), blank],
        else: [key.("Play", :play), key.("Down", :down), key.("Pause", :pause)]

    rows = [
      [key.("Back", :back), key.("Up", :up), key.("Home", :home)],
      [key.("Left", :left), key.("OK", :select), key.("Right", :right)],
      last
    ]

    [heading | Enum.map(rows, &{:row, Theme.size(:pill), &1, heading})]
  end

  # -- Pictures --

  # the shown entity's picture, once `:pictures` has it
  defp picture(ctx) do
    case Map.get(ctx, :pictures) do
      %{entity_id: id, path: path} when id == ctx.id and is_binary(path) -> path
      _ -> nil
    end
  end

  # The picture fades in over the one before it, on its own black layer
  # (keyed by its file), as the photos do: a refresh doesn't blink, and
  # nothing of the old picture shows in the new one's letterbox bars or
  # through its transparency. The fade also matters to Emerge: it draws a
  # loaded image at its next frame, but a fixed-size element's load
  # doesn't bring one about by itself (it only relayouts, and nothing
  # moves); the fade draws frames for 0.4 s, and a snapshot decodes in less.
  defp picture_el(ctx, path, w, h) do
    under =
      case Map.get(ctx.pictures, :previous) do
        nil -> []
        previous -> [Background.image({:path, previous}, fit: :contain)]
      end

    el(
      [width(px(w)), height(px(h))] ++ under,
      el(
        [
          key({:picture, path}),
          width(fill()),
          height(fill()),
          Background.color(Theme.color(:black)),
          Animation.animate_enter([[Transform.alpha(0.0)], [Transform.alpha(1.0)]], 400, :linear)
        ],
        el(
          [width(fill()), height(fill()), Background.image({:path, path}, fit: :contain)],
          none()
        )
      )
    )
  end

  # -- Locks --

  # A first press arms the action (`:ha`'s `:arm`); then, for a few
  # seconds, the control asks for a second one.
  defp guarded(ctx, action, label, armed, active?) do
    if armed == action do
      LCARS.pill(
        label: "CONFIRM #{String.upcase(label)}",
        fill: Theme.color(:red),
        width: px(@button_w + 100),
        attrs: [Event.on_press(event(ctx.ha, :confirm, {ctx.id, action}))]
      )
    else
      button(ctx, label, event(ctx.ha, :arm, {ctx.id, action}), active?)
    end
  end

  # -- Colour --

  defp colour(ctx, es) do
    heading = {:heading, ctx.color, "Colour"}
    sliders = Map.get(ctx.ha, :sliders) || %{}
    [h, s] = Actions.hs(es)
    h = Map.get(sliders, {ctx.id, :hue}, h)
    w = Float.floor((ctx.detail_w - (length(@swatches) - 1) * @gap) / length(@swatches))

    hues = Color.gradient(for(hue <- 0..360//60, do: Theme.color(hs_hex(hue, 100))), 0)
    saturation = Color.gradient([Theme.color(:white), Theme.color(hs_hex(h, 100))], 0)

    swatches =
      for {hue, sat} <- @swatches do
        LCARS.pill(
          label: "",
          fill: Theme.color(hs_hex(hue, sat)),
          width: px(w),
          attrs: [Event.on_press(call(ctx, Actions.color(ctx.id, [hue, sat])))]
        )
      end

    [
      heading,
      slider_row(ctx, heading, :hue, {0, 360, 1}, round(h), track: hues, filled: nil),
      slider_row(ctx, heading, :saturation, {0, 100, 1}, round(s),
        track: saturation,
        filled: nil
      ),
      {:row, Theme.size(:pill), swatches, heading}
    ]
  end

  @doc false
  # A hue (0-360) and saturation (0-100) at full brightness, as a hex colour.
  @spec hs_hex(number(), number()) :: non_neg_integer()
  def hs_hex(h, s) do
    c = s / 100
    sector = :math.fmod(:math.fmod(h, 360) + 360, 360) / 60
    x = c * (1 - abs(:math.fmod(sector, 2) - 1))

    {r, g, b} =
      case trunc(sector) do
        0 -> {c, x, 0}
        1 -> {x, c, 0}
        2 -> {0, c, x}
        3 -> {0, x, c}
        4 -> {x, 0, c}
        _ -> {c, 0, x}
      end

    channel = &round((&1 + 1 - c) * 255)
    channel.(r) <<< 16 ||| channel.(g) <<< 8 ||| channel.(b)
  end

  # -- Building blocks --

  defp call(ctx, request), do: event(ctx.ha, :call, request)

  # A row of buttons (as many rows as they need) under `heading`.
  defp buttons(_ctx, _heading, []), do: []

  defp buttons(ctx, heading, items) do
    per_row = Kernel.max(1, trunc((ctx.detail_w + @gap) / (@button_w + @gap)))

    items
    |> Enum.chunk_every(per_row)
    |> Enum.map(&{:row, Theme.size(:pill), &1, heading})
  end

  # `press` nil: disabled, dimmed. Option: `:font` (size).
  defp button(ctx, label, press, active?, opts \\ []) do
    LCARS.pill(
      label: String.upcase(label),
      fill: Theme.color(if(active?, do: ctx.color, else: Theme.dim(ctx.color))),
      width: px(@button_w),
      font: Keyword.get(opts, :font, Theme.size(:label)),
      attrs: if(press, do: [Event.on_press(press)], else: [])
    )
  end

  # A list to pick one from, under its own heading: 3 a row (2 in
  # portrait), the current one bright. Built only for the page shown.
  defp options(ctx, title, es, kind) do
    case Actions.options(es, kind) do
      {[], _current} ->
        []

      {list, current} ->
        heading = {:heading, ctx.color, title}
        [heading | option_rows(ctx, heading, kind, list, current)]
    end
  end

  defp option_rows(ctx, heading, kind, list, current) do
    cols = if ctx.portrait?, do: 2, else: 3
    w = Float.floor((ctx.detail_w - (cols - 1) * @gap) / cols)

    list
    |> Enum.map(fn option -> fn -> option_pill(ctx, kind, option, current, w) end end)
    |> Enum.chunk_every(cols)
    |> Enum.map(&{:row, Theme.size(:pill), &1, heading})
  end

  defp option_pill(ctx, kind, option, current, w) do
    chars = trunc((w - 60) / (Theme.size(:label) * 0.42))

    LCARS.pill(
      label: option |> String.replace("_", " ") |> LCARS.fit(chars) |> String.upcase(),
      fill: Theme.color(if(option == current, do: ctx.color, else: Theme.dim(ctx.color))),
      width: px(w),
      attrs: [Event.on_press(call(ctx, Actions.option(ctx.id, kind, option)))]
    )
  end

  defp readout(parts) do
    case Enum.filter(parts, & &1) do
      [] ->
        []

      parts ->
        [
          {:block, @readout_h,
           el(
             [Font.size(Theme.size(:label)), Font.color(Theme.color(:peach))],
             text(parts |> Enum.join("   ·   ") |> String.upcase())
           )}
        ]
    end
  end

  defp slider_section(ctx, title, kind, range, value, opts \\ []) do
    heading = {:heading, ctx.color, title}
    [heading, slider_row(ctx, heading, kind, range, value, opts)]
  end

  # The value under the finger (held by `:ha` until it's sent), or the
  # entity's own. Keyed by entity and kind, so moving from one entity's
  # detail to another's doesn't reuse this slider (and its drag) by
  # position; in an el of its own, as keyed siblings must all be keyed.
  defp slider_row(ctx, heading, kind, {min, max, step}, value, opts \\ []) do
    value = Map.get(Map.get(ctx.ha, :sliders) || %{}, {ctx.id, kind}, value)
    press = event(ctx.ha, :slide, {ctx.id, kind})
    track = Keyword.get(opts, :track, Theme.color(Theme.dim(ctx.color)))
    filled = Keyword.get(opts, :filled, Theme.color(ctx.color))

    slider =
      Input.slider(
        [
          key({:slider, ctx.id, kind}),
          width(fill()),
          height(px(@slider_h)),
          Slider.config(
            min: min,
            max: max,
            step: step,
            track: bar(track),
            filled_track: bar(filled),
            thumb:
              el(
                [
                  width(px(48)),
                  height(px(@slider_h)),
                  Background.color(Theme.color(:peach)),
                  Border.width(4),
                  Border.color(Theme.color(:black)),
                  Border.rounded(14)
                ],
                none()
              )
          ),
          Event.on_change(press)
        ],
        Kernel.max(min, Kernel.min(max, value))
      )

    {:row, @slider_h, [el([width(px(ctx.detail_w))], slider)], heading}
  end

  # a slider's track; nil: none drawn (a colour track shows its own)
  defp bar(nil), do: el([height(px(28)), center_y()], none())

  defp bar(color),
    do: el([height(px(28)), center_y(), Background.color(color), Border.rounded(14)], none())
end
