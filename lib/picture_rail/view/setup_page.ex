defmodule PictureRail.View.SetupPage do
  @moduledoc """
  The Setup page in the panel: the overview (a row per section, with what
  it's set to) and a section's editor (a row per field), as the panel's
  content blocks (`PictureRail.View.Panel` pages them).

  What a section shows is worked out by `field_rows/3` and
  `section_summary/3`, pure functions over the `:setup`, `:settings` and
  `:photos` controllers' exposed maps; the rest draws them. Everything sends
  `{:setup_open, section}` or `{:setup, event, payload}` to the viewport,
  which hands it to the `:setup` controller.
  """
  use Emerge.UI
  use Solve.Lookup, :helpers

  alias PictureRail.{PhotoSource, Setup}
  alias PictureRail.Setup.{Field, Secret}
  alias PictureRail.View.{Keyboard, LCARS, QR, Theme}

  @colors %{wifi: :bluey, photo_source: :sky, home_assistant: :lilac, display: :peach}
  @row_h 84
  @error_h 30
  @choice_h 72
  # Every control pill on a Setup page is this wide (the widest label,
  # "NEXT: PHOTOS", fits), and list pills are a column wide, so pills
  # line up as LCARS panels do.
  @control_w 200
  @row_gap 12
  # The overview's section pills: the widest summary ("Immich · 12 albums
  # · 12345 photos") fits.
  @section_w 480
  @section_h 96
  # LCARS.heading/2's height
  @heading_h 38
  # the pairing column beside the QR code
  @about_h 400
  @phone_title "Settings on your phone"

  # -- What to show --

  @doc """
  The overview line for a section: what it's set to, or "Not set up".
  `settings` is the `:settings` controller's exposed map.
  """
  @spec section_summary(Setup.section(), map() | nil, map() | nil, map() | nil) :: String.t()
  def section_summary(section, settings, photos \\ nil, network \\ nil)

  def section_summary(:wifi, _settings, _photos, %{status: :connected} = network),
    do: Enum.join(Enum.reject([network.ssid, network.ip], &is_nil/1), " · ")

  def section_summary(:wifi, _settings, _photos, _network), do: "Not connected"

  def section_summary(:photo_source, %{settings: %{photo_source: %{} = source}}, photos, _) do
    label =
      case PhotoSource.module_for(source["type"] || "") do
        {:ok, module} -> module.label()
        :error -> source["type"]
      end

    albums =
      case Map.get(source, "album_ids", []) do
        [one] when is_binary(one) -> "1 album"
        ids -> "#{length(ids)} albums"
      end

    Enum.join([label, albums] ++ photo_count(photos), " · ")
  end

  def section_summary(:home_assistant, %{settings: %{home_assistant: %{"url" => url}}}, _, _),
    do: URI.parse(url).host || url

  def section_summary(:display, %{settings: %{slideshow: slideshow}}, _photos, _network),
    do: "Every #{seconds(slideshow.interval_ms)} · fade #{seconds(slideshow.fade_ms)}"

  def section_summary(_section, _settings, _photos, _network), do: "Not set up"

  defp photo_count(%{status: :online, photos: n}) when n > 0, do: ["#{n} photos"]
  defp photo_count(%{status: :offline}), do: ["offline"]
  defp photo_count(_photos), do: []

  @doc ~s(A duration in ms as the page shows it: `"6 s"`, `"1.5 s"`.)
  @spec seconds(integer()) :: String.t()
  def seconds(ms) when rem(ms, 1000) == 0, do: "#{div(ms, 1000)} s"
  def seconds(ms), do: "#{:erlang.float_to_binary(ms / 1000, [:compact, decimals: 2])} s"

  @doc """
  The rows of the section being edited, from the `:setup` controller's
  exposed map and the public settings (for which secrets are set):

    * `{:toggle, id, label, on?, error}`
    * `{:stepper, id, label, text, down?, up?, error}`
    * `{:text, id, label, text, set?, error}` - `text` is the value, a
      masked secret, or `nil` when there's nothing
    * `{:choices, id, label, choices, selected, error}` - `choices` as the
      controller has them (`:idle`, `:loading`, `{:ok, list}`, `{:error, text}`)
  """
  @spec field_rows(map(), map(), map()) :: [tuple()]
  def field_rows(%{section: section, draft: draft} = setup, public, _photos) do
    for {name, %Field{} = f} <- Setup.fields(section, draft) do
      id = {name, f.key}
      value = Map.get(draft, id)
      error = Map.get(setup.errors, id)
      field_row(f, id, value, error, setup, draft, public)
    end
  end

  defp field_row(%Field{type: :toggle} = f, id, value, error, _setup, _draft, _public),
    do: {:toggle, id, f.label, value == true, error}

  defp field_row(%Field{type: type} = f, id, value, error, _setup, _draft, _public)
       when type in [:integer, :seconds] do
    text = if type == :seconds, do: seconds(value || 0), else: to_string(value)
    down? = f.min == nil or (value || 0) > f.min
    up? = f.max == nil or (value || 0) < f.max
    {:stepper, id, f.label, text, down?, up?, error}
  end

  defp field_row(%Field{type: :secret} = f, id, value, error, _setup, draft, public) do
    set? = Setup.secret_set?(id, draft, public)

    text =
      case value do
        %Secret{value: typed} when typed != "" -> String.duplicate("•", String.length(typed))
        _ when set? -> "•••• set"
        _ -> nil
      end

    {:text, id, f.label, text, set?, error}
  end

  defp field_row(%Field{type: {:choices, _}} = f, id, value, error, setup, _draft, _public),
    do: {:choices, id, f.label, Map.get(setup.choices, id, :idle), value || [], error}

  defp field_row(%Field{} = f, id, value, error, _setup, _draft, _public) do
    text = if value in [nil, ""], do: nil, else: value
    {:text, id, f.label, text, text != nil, error}
  end

  # -- Blocks --

  @doc "The content blocks for a Setup view (`:setup` or `{:setup, section}`)."
  @spec blocks(map(), :setup | {:setup, Setup.section()}) :: [tuple()]
  def blocks(ctx, :setup) do
    heading = {:heading, Theme.hex(:orange), "Settings"}

    case phone(ctx) do
      {phone_h, about} when not ctx.portrait? ->
        # beside the pills, on the first page: the pills shrink to fit
        pill_h =
          Kernel.min(@section_h, Float.floor((ctx.content_h - @heading_h - 4 * @row_gap) / 4))

        pills =
          column(
            [width(px(section_w(ctx))), spacing(@row_gap)],
            [LCARS.heading(Theme.hex(:orange), "Settings") | section_pills(ctx, pill_h)]
          )

        phone =
          column([width(fill()), spacing(@row_gap)], [
            LCARS.heading(Theme.hex(:sky), @phone_title),
            about
          ])

        h = Kernel.max(@heading_h + 4 * (pill_h + @row_gap), @heading_h + @row_gap + phone_h)
        [{:block, h, row([spacing(48)], [pills, phone])}]

      phone ->
        rows = for pill <- section_pills(ctx, @section_h), do: {:row, @section_h, [pill], heading}

        phone_blocks =
          case phone do
            {phone_h, about} ->
              [{:heading, Theme.hex(:sky), @phone_title}, {:block, phone_h, about}]

            nil ->
              []
          end

        [heading | rows] ++ phone_blocks
    end
  end

  def blocks(ctx, {:setup, section}) do
    setup = ctx.setup

    cond do
      setup == nil or setup.section != section ->
        # the editor opens with the view; until its state arrives
        [{:block, 80, message_element("Loading", :peach)}]

      section == :wifi ->
        wifi_blocks(ctx, setup, Map.get(ctx, :network) || %{})

      true ->
        section_blocks(ctx, setup, section)
    end
  end

  defp section_pills(ctx, h) do
    for section <- Setup.sections() do
      LCARS.pill(
        label: String.upcase(Setup.label(section)),
        sub: section_summary(section, ctx.settings, ctx.photos, Map.get(ctx, :network)),
        color: Theme.hex(@colors[section]),
        height: h,
        width: px(section_w(ctx)),
        attrs: [Event.on_press(event(ctx.panel, :open, {:setup, section}))]
      )
    end
  end

  defp section_w(ctx), do: Kernel.min(@section_w, ctx.content_w)

  defp section_blocks(ctx, setup, section) do
    public = ctx.settings.settings
    color = Theme.hex(@colors[section])

    source_picker(ctx, setup, color) ++
      Enum.flat_map(field_rows(setup, public, ctx.photos), &field_blocks(ctx, &1, color)) ++
      footer(ctx, setup)
  end

  # -- Settings on your phone --

  @doc ~s{A pairing code as the frame shows it, in two halves: `"1234 5678"`.}
  @spec code(String.t()) :: String.t()
  def code(code) do
    {first, second} = String.split_at(code, div(String.length(code), 2))
    first <> " " <> second
  end

  # While connected (the `:pairing` controller has a QR code then): the QR
  # code of the web page's pairing link, its address by name and the code
  # to type there, and forgetting the devices paired so far, as
  # `{height, element}`; `nil` otherwise.
  defp phone(ctx) do
    case Map.get(ctx, :pairing) do
      %{code: code, qr: runs} = pairing when is_binary(code) and is_list(runs) ->
        phone(pairing, code, runs)

      _ ->
        nil
    end
  end

  defp phone(pairing, code, runs) do
    {side, qr} = QR.render(runs, 7)

    small = fn text ->
      el(
        [
          Font.family("Noto Sans"),
          Font.size(Theme.size(:small)),
          Font.color(Theme.color(:almond))
        ],
        text(text)
      )
    end

    forget =
      LCARS.pill(
        label: "FORGET DEVICES",
        color: Theme.hex(:mauve),
        height: 64,
        width: px(@control_w),
        attrs: [Event.on_press(event(pairing, :forget))]
      )

    about =
      column([spacing(10), center_y()], [
        small.("Scan the code with your phone, or open"),
        el(
          [
            Font.family("Noto Sans"),
            Font.size(Theme.size(:label)),
            Font.color(Theme.color(:white))
          ],
          text(pairing.address)
        ),
        small.("and enter"),
        el([Font.size(72), Font.color(Theme.color(:sky))], text(code(code))),
        small.("For pasting keys and tokens. Wi-Fi is set here."),
        forget
        | forget_failed(pairing)
      ])

    {Kernel.max(side, @about_h), row([spacing(32)], [qr, about])}
  end

  defp forget_failed(%{forget_failed?: true}),
    do: [message_element("Couldn't save that: they're paired again after a restart", :red)]

  defp forget_failed(_pairing), do: []

  # -- Wi-Fi --

  @doc """
  What the Wi-Fi page says about the network: connected, a join on
  trial, or how the last one went. `network` is the `:network`
  controller's exposed map.
  """
  @spec wifi_status(map()) :: {String.t(), atom()}
  def wifi_status(%{trial: %{ssid: ssid}}), do: {"Connecting to #{ssid}...", :gold}

  def wifi_status(%{result: {:failed, reason, ssid}} = network) do
    back = if network[:status] == :connected, do: ", back on #{network.ssid}", else: ""

    case reason do
      :wrong_password -> {"Wrong password for #{ssid}#{back}", :red}
      :timeout -> {"Couldn't connect to #{ssid}#{back}", :red}
    end
  end

  def wifi_status(%{status: :connected, ssid: ssid, ip: ip}),
    do: {"Connected to #{ssid} · #{ip}", :sky}

  def wifi_status(_network), do: {"Not connected", :peach}

  @doc "A listed network's second line: its security and signal."
  @spec network_line(map()) :: String.t()
  def network_line(%{security: security, signal: signal}) do
    kind =
      case security do
        :open -> "Open"
        :wpa2 -> "WPA2"
        :wpa3_only -> "WPA3 only, may not work"
        :eap -> "Enterprise, not supported"
        :wep -> "WEP, not supported"
      end

    "#{kind} · #{signal}%"
  end

  defp wifi_blocks(ctx, setup, network) do
    color = Theme.hex(@colors[:wifi])
    {status, status_color} = wifi_status(network)
    status_block = {:block, 60, message_element(status, status_color)}
    next = next_step(ctx, network)

    case setup.draft[Setup.wifi_id("mode")] do
      :list ->
        [status_block | next] ++ network_list(ctx, network, color)

      _mode ->
        public = ctx.settings.settings
        ssid = setup.draft[Setup.wifi_id("ssid")]
        heading = {:heading, color, if(ssid in [nil, ""], do: "Other network", else: ssid)}

        [status_block, heading] ++
          Enum.flat_map(field_rows(setup, public, nil), &field_blocks(ctx, &1, color)) ++
          join_footer(setup, network)
    end
  end

  # Once connected with nothing else set up: on to the photos.
  defp next_step(ctx, %{status: :connected, trial: nil}) do
    if match?(%{configured: %{photo_source: false}}, ctx.settings) do
      [
        {:row, 72,
         [
           LCARS.pill(
             label: "NEXT: PHOTOS",
             color: Theme.hex(:orange),
             height: 72,
             width: px(@control_w),
             attrs: [Event.on_press(event(ctx.panel, :replace, {:setup, :photo_source}))]
           )
         ], nil}
      ]
    else
      []
    end
  end

  defp next_step(_ctx, _network), do: []

  defp network_list(ctx, network, color) do
    heading =
      {:heading, color, if(network[:scanning?], do: "Networks (scanning)", else: "Networks")}

    joining? = network[:trial] != nil
    per_row = Kernel.max(ctx.cols - 2, 1)
    w = column_w(ctx, per_row)

    pills =
      for n <- network[:networks] || [] do
        usable? = n.security in [:open, :wpa2, :wpa3_only] and not joining?

        LCARS.pill(
          label: LCARS.fit(n.ssid, 28),
          sub: network_line(n),
          fill: choice_fill(color, usable?),
          height: 96,
          width: px(w),
          attrs: if(usable?, do: [Event.on_press(event(ctx.setup, :wifi_pick, n))], else: [])
        )
      end

    other =
      LCARS.pill(
        label: "OTHER NETWORK...",
        sub: "A hidden one",
        color: Theme.hex(:lilac),
        height: 96,
        width: px(w),
        attrs: if(joining?, do: [], else: [Event.on_press(event(ctx.setup, :wifi_other))])
      )

    rows =
      (pills ++ [other])
      |> Enum.chunk_every(per_row)
      |> Enum.map(&{:row, 96, &1, heading})

    [heading | rows]
  end

  defp join_footer(setup, network) do
    heading = {:heading, Theme.hex(:orange), "Join"}
    busy? = setup.joining? or network[:trial] != nil

    join =
      LCARS.pill(
        label: if(network[:trial], do: "JOINING", else: "JOIN"),
        fill: Theme.color(if(busy?, do: Theme.dim(Theme.hex(:orange)), else: Theme.hex(:orange))),
        height: 72,
        width: px(@control_w),
        attrs: if(busy?, do: [], else: [Event.on_press(event(setup, :join))])
      )

    back =
      LCARS.pill(
        label: "NETWORKS",
        color: Theme.hex(:mauve),
        height: 72,
        width: px(@control_w),
        attrs: [Event.on_press(event(setup, :wifi_list))]
      )

    message =
      case setup.message do
        {:error, text} -> [{:block, 50, message_element(text, :red)}]
        _ -> []
      end

    [heading, {:row, 72, [join, back], heading}] ++ message
  end

  # A row of the known sources, when there's more than one to choose from.
  defp source_picker(ctx, %{section: :photo_source, draft: draft}, color) do
    case PhotoSource.sources() do
      [_only] ->
        []

      sources ->
        heading = {:heading, color, "Source"}
        current = Setup.source(draft)
        per_row = Kernel.max(ctx.cols - 1, 1)

        pills =
          for module <- sources do
            LCARS.pill(
              label: String.upcase(module.label()),
              fill: choice_fill(color, module == current),
              height: @choice_h,
              width: px(column_w(ctx, per_row)),
              attrs: [Event.on_press(event(ctx.setup, :set_type, module.type()))]
            )
          end

        rows = pills |> Enum.chunk_every(per_row) |> Enum.map(&{:row, @choice_h, &1, heading})
        [heading | rows]
    end
  end

  defp source_picker(_ctx, _setup, _color), do: []

  defp field_blocks(ctx, {:toggle, id, label, on?, error}, color) do
    control =
      LCARS.pill(
        label: if(on?, do: "ON", else: "OFF"),
        fill: choice_fill(color, on?),
        height: 64,
        width: px(@control_w),
        attrs: [Event.on_press(event(ctx.setup, :toggle, id))]
      )

    [field_row_block(label, [control], error)]
  end

  defp field_blocks(ctx, {:stepper, id, label, shown, down?, up?, error}, color) do
    controls = [
      step_pill("−", event(ctx.setup, :step, {id, -1}), down?, color),
      el(
        [
          width(px(170)),
          center_y(),
          Font.size(Theme.size(:heading)),
          Font.color(Theme.color(:white))
        ],
        el([center_x()], text(shown))
      ),
      step_pill("+", event(ctx.setup, :step, {id, 1}), up?, color)
    ]

    [field_row_block(label, controls, error)]
  end

  defp field_blocks(ctx, {:text, id, label, shown, _set?, error}, color) do
    value =
      el(
        [
          center_y(),
          Font.family("Noto Sans"),
          Font.size(Theme.size(:label)),
          Font.color(Theme.color(if(shown, do: :white, else: :grey)))
        ],
        text(LCARS.fit(shown || "not set", 40))
      )

    edit =
      LCARS.pill(
        label: "EDIT",
        color: color,
        height: 64,
        width: px(@control_w),
        attrs: [Event.on_press(event(ctx.setup, :edit, id))]
      )

    [field_row_block(label, [value, edit], error)]
  end

  defp field_blocks(ctx, {:choices, id, label, choices, selected, error}, color) do
    heading = {:heading, color, label}
    per_row = Kernel.max(ctx.cols - 1, 1)

    rows =
      choices
      |> choice_pills(ctx.setup, id, selected, color, column_w(ctx, per_row))
      |> Enum.chunk_every(per_row)
      |> Enum.map(&{:row, @choice_h, &1, heading})

    status =
      field_row_block(
        choices_status(choices, selected),
        [reload_pill(ctx.setup, id, choices, color)],
        error,
        :sky
      )

    [heading] ++ rows ++ [status]
  end

  defp choice_pills({:ok, list}, setup, id, selected, color, w) do
    for {value, label} <- list do
      LCARS.pill(
        label: LCARS.fit(label, 30),
        fill: choice_fill(color, value in selected),
        height: @choice_h,
        width: px(w),
        attrs: [Event.on_press(event(setup, :toggle_choice, {id, value}))]
      )
    end
  end

  defp choice_pills(_choices, _setup, _id, _selected, _color, _w), do: []

  defp choices_status(:loading, _selected), do: "Loading..."
  defp choices_status({:error, message}, _selected), do: message
  defp choices_status({:ok, []}, _selected), do: "Nothing to choose from"
  defp choices_status(_choices, selected), do: "#{length(selected)} selected"

  defp reload_pill(_setup, _id, :loading, color),
    do:
      LCARS.pill(
        label: "LOAD",
        fill: Theme.color(Theme.dim(color)),
        height: 64,
        width: px(@control_w)
      )

  defp reload_pill(setup, id, choices, color) do
    LCARS.pill(
      label: if(match?({:ok, _}, choices), do: "RELOAD", else: "LOAD"),
      fill: Theme.color(color),
      height: 64,
      width: px(@control_w),
      attrs: [Event.on_press(event(setup, :load_choices, id))]
    )
  end

  defp footer(_ctx, setup) do
    heading = {:heading, Theme.hex(:orange), "Done?"}

    save =
      LCARS.pill(
        label: if(setup.saving?, do: "SAVING", else: "SAVE"),
        fill:
          Theme.color(
            if(setup.saving?, do: Theme.dim(Theme.hex(:orange)), else: Theme.hex(:orange))
          ),
        height: 72,
        width: px(@control_w),
        attrs: if(setup.saving?, do: [], else: [Event.on_press(event(setup, :save))])
      )

    test =
      if setup.section == :photo_source do
        [
          LCARS.pill(
            label: if(setup.check == :running, do: "TESTING", else: "TEST"),
            color: Theme.hex(:bluey),
            height: 72,
            width: px(@control_w),
            attrs: [Event.on_press(event(setup, :test))]
          )
        ]
      else
        []
      end

    discard =
      LCARS.pill(
        label: "DISCARD",
        color: Theme.hex(:mauve),
        height: 72,
        width: px(@control_w),
        attrs: [Event.on_press(event(setup, :discard))]
      )

    [heading, {:row, 72, [save] ++ test ++ [discard], heading}] ++ status_blocks(setup)
  end

  defp status_blocks(setup) do
    check =
      case setup.check do
        :ok -> [{:block, 50, message_element("Connection works", :sky)}]
        {:error, message} -> [{:block, 50, message_element(message, :red)}]
        _ -> []
      end

    message =
      case setup.message do
        {:ok, text} -> [{:block, 50, message_element(text, :sky)}]
        {:error, text} -> [{:block, 50, message_element(text, :red)}]
        nil -> []
      end

    check ++ message
  end

  # -- The field editor --

  @doc """
  The full-screen editor for the field the keyboard is open on
  (`setup.editing`): its label, the field, and the keyboard, sized for the
  oriented screen `size`.

  A plain field (or a secret shown in clear) is Emerge's `Input.text`,
  keyed on `setup.edits` so it mounts focused each time the editor opens;
  a masked secret is drawn as bullets, typed through app events.
  """
  @spec editor(map()) :: term()
  def editor(%{size: {w, h}, setup: setup} = ctx) do
    id = setup.editing
    field = Setup.field(setup.section, setup.draft, id)
    secret? = field.type == :secret
    mode = if secret? and not setup.reveal?, do: :masked, else: :native

    pad = 16
    gap = 14
    header_h = 64
    field_h = 88
    inner_w = w - 2 * pad
    rows = length(Keyboard.layout(setup.keyboard.layer, setup.keyboard.shift, field.type, mode))
    avail = h - 2 * pad - header_h - field_h - 2 * gap - (rows - 1) * 8
    key_h = Kernel.min(110, Float.floor(avail / rows))

    reveal =
      if secret?,
        do: [
          Keyboard.key(
            :reveal,
            if(setup.reveal?, do: "HIDE", else: "SHOW"),
            160,
            56,
            Theme.hex(:bluey),
            &event(setup, :kb, &1)
          )
        ],
        else: []

    header =
      row([width(fill()), height(px(header_h)), spacing(16)], [
        column([width(fill()), center_y(), spacing(2)], [
          el(
            [Font.size(Theme.size(:heading) + 6), Font.color(Theme.color(:peach))],
            text(String.upcase(field.label))
          ),
          el(
            [
              Font.family("Noto Sans"),
              Font.size(Theme.size(:small) - 3),
              Font.color(Theme.color(:almond))
            ],
            text(field.help || "")
          )
        ])
        | reveal
      ])

    el(
      [
        key(:setup_editor),
        width(fill()),
        height(fill()),
        padding(pad),
        Background.color(Theme.color(:black)),
        Font.family("Antonio")
      ],
      column([width(fill()), spacing(gap)], [
        header,
        field_box(setup, id, set?(ctx, id), mode, field_h),
        Keyboard.render(setup.keyboard, field.type, mode, inner_w, key_h, &event(setup, :kb, &1))
      ])
    )
  end

  defp set?(%{settings: %{settings: public}, setup: setup}, id),
    do: Setup.secret_set?(id, setup.draft, public)

  defp set?(_ctx, _id), do: false

  defp field_box(setup, id, _set?, :native, field_h) do
    value =
      case setup.draft[id] do
        %Secret{value: v} -> v
        v when is_binary(v) -> v
        _ -> ""
      end

    el(
      [width(fill())],
      Input.text(
        [
          key({:field, setup.edits}),
          focus_on_mount(),
          width(fill()),
          height(px(field_h)),
          padding_xy(24, 0),
          Background.color(Theme.color(0x1A1A24)),
          Border.rounded(14),
          Border.width(3),
          Border.color(Theme.color(:orange)),
          Font.family("Noto Sans"),
          Font.size(36),
          Font.color(Theme.color(:white)),
          Event.on_change(event(setup, :set, id))
        ],
        value
      )
    )
  end

  defp field_box(setup, id, set?, :masked, field_h) do
    typed =
      case setup.draft[id] do
        %Secret{value: v} -> v
        _ -> ""
      end

    {shown, color} =
      cond do
        typed != "" -> {String.duplicate("•", String.length(typed)) <> "|", :white}
        set? -> {"•••• set, type to replace", :grey}
        true -> {"type it", :grey}
      end

    el(
      [
        width(fill()),
        height(px(field_h)),
        padding_xy(24, 0),
        Background.color(Theme.color(0x1A1A24)),
        Border.rounded(14),
        Border.width(3),
        Border.color(Theme.color(:orange)),
        Font.family("Noto Sans"),
        Font.size(36),
        Font.color(Theme.color(color))
      ],
      el([center_y()], text(shown))
    )
  end

  # -- Pieces --

  defp field_row_block(label, controls, error, label_color \\ :peach) do
    label_el =
      el(
        [
          width(fill()),
          center_y(),
          Font.size(Theme.size(:label)),
          Font.color(Theme.color(label_color))
        ],
        text(String.upcase(label))
      )

    line = row([width(fill()), height(px(@row_h)), spacing(16)], [label_el | controls])

    case error do
      nil ->
        {:block, @row_h, line}

      error ->
        {:block, @row_h + @error_h,
         column([width(fill())], [
           line,
           el(
             [height(px(@error_h)), Font.size(Theme.size(:small)), Font.color(Theme.color(:red))],
             text(error)
           )
         ])}
    end
  end

  defp step_pill(label, press, enabled?, color) do
    LCARS.pill(
      label: label,
      font: 40,
      fill: Theme.color(if(enabled?, do: color, else: Theme.dim(color))),
      height: 64,
      width: px(@control_w),
      attrs: if(enabled?, do: [Event.on_press(press)], else: [])
    )
  end

  # A list pill's width: a column of `per_row`, so a short last row
  # doesn't stretch.
  defp column_w(ctx, per_row),
    do: Float.floor((ctx.content_w - (per_row - 1) * @row_gap) / per_row)

  defp choice_fill(color, true), do: Theme.color(color)
  defp choice_fill(color, false), do: Theme.color(Theme.dim(color))

  defp message_element(message, color) do
    el(
      [padding_xy(12, 8), Font.size(Theme.size(:label)), Font.color(Theme.color(color))],
      text(message)
    )
  end
end
