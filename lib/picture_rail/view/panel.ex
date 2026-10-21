defmodule PictureRail.View.Panel do
  @moduledoc """
  The Home Assistant panel, LCARS-style, drawn over the slideshow.

  Landscape: a sidebar under the top elbow (Overview, floors as dividers
  with their areas, Media, Devices), a header with the view's title and,
  on the overview, the summary pills, and scrolling content of 4 columns.
  Portrait: the elbow and title on top, the navigation as a horizontally
  scrolling row, 2 columns.

  Everything it draws sends a message to the viewport (`PictureRail.View`),
  which turns it into controller events: `{:goto, view}`, `:back`, `:hide`,
  `{:pill, entity_id}` (a tap or, timed by the viewport, a long press),
  `{:detail, entity_id}`, `{:call, request}` and `{:slider, entity_id, kind}`.

  While Home Assistant isn't connected, the frame turns red with a slowly
  blinking alert bar and every pill is greyed out and inert.
  """
  use Emerge.UI

  import PictureRail.App.Panel, only: [is_setup_view: 1]

  alias PictureRail.HA.{Index, Overview}
  alias PictureRail.Setup
  alias PictureRail.View.{EnergyPage, Format, LCARS, SetupPage, Theme}

  @toggle ~w(light switch fan input_boolean)
  @run %{
    "scene" => "turn_on",
    "script" => "turn_on",
    "button" => "press",
    "input_button" => "press"
  }
  @details ~w(light climate cover media_player)

  @doc "Whether tapping an entity's pill toggles or runs it."
  @spec tap_action(String.t(), Hassock.EntityState.t() | nil) :: map() | nil
  def tap_action(entity_id, es) do
    domain = Index.domain(entity_id)

    cond do
      not Overview.available?(es) ->
        nil

      domain in @toggle ->
        on? = es.state == "on"

        %{
          domain: domain,
          service: if(on?, do: "turn_off", else: "turn_on"),
          entity_id: entity_id,
          optimistic: if(on?, do: "off", else: "on")
        }

      Map.has_key?(@run, domain) ->
        %{domain: domain, service: @run[domain], entity_id: entity_id}

      true ->
        nil
    end
  end

  @doc """
  What the panel says while it has nothing from Home Assistant yet (no
  model since boot): loading while connecting or connected, otherwise why
  nothing will come.
  """
  @spec waiting_message(PictureRail.HA.Model.status()) :: String.t()
  def waiting_message(:disconnected), do: "Can't reach Home Assistant"
  def waiting_message({:auth_failed, _}), do: "Home Assistant refused the token"
  def waiting_message(:unconfigured), do: "Home Assistant isn't set up"
  def waiting_message(_connecting), do: "Loading"

  @doc "Whether a panel view is one of the Setup pages."
  @spec setup_view?(term()) :: boolean()
  def setup_view?(view), do: is_setup_view(view)

  @doc "Whether an entity has a detail view (a chevron on its pill)."
  @spec detail?(String.t()) :: boolean()
  def detail?(entity_id), do: Index.domain(entity_id) in @details

  @doc """
  The panel for the oriented screen `size`. `ha` and `panel` are the
  controllers' exposed maps (and `setup`, `settings` and `photos` for the
  Setup pages); `sliders` holds slider values being dragged
  (`%{{entity_id, kind} => value}`).
  """
  @spec render(map()) :: term()
  def render(%{size: {w, h}} = ctx) do
    # the Setup pages work whatever Home Assistant is doing
    live? = ctx.ha.status == :connected or setup_view?(ctx.panel.view)
    ctx = Map.merge(ctx, %{w: w, h: h, live?: live?, frame: if(live?, do: :orange, else: :red)})

    el(
      [
        key(:panel),
        width(fill()),
        height(fill()),
        Background.color(Theme.color(:black)),
        Font.family("Antonio"),
        padding(16),
        Animation.animate_enter([[Transform.alpha(0.0)], [Transform.alpha(1.0)]], 250, :ease_out),
        Animation.animate_exit([[Transform.alpha(1.0)], [Transform.alpha(0.0)]], 250, :ease_in)
      ],
      if(ctx.portrait?, do: portrait(ctx), else: landscape(ctx))
    )
  end

  # -- Frames --

  defp landscape(ctx) do
    sidebar = Theme.size(:sidebar)
    gap = Theme.size(:gap)
    content_w = ctx.w - 32 - sidebar - gap - Theme.size(:gutter) * 2
    middle_h = ctx.h - 32 - Theme.size(:top) - Theme.size(:bottom) - 2 * gap
    {page, swipes, pager} = content(ctx, content_w, 4, middle_h - 16)

    column([width(fill()), height(fill()), spacing(gap)], [
      row([width(fill()), height(px(Theme.size(:top))), spacing(gap)], [
        LCARS.elbow(
          corner: :top,
          color: Theme.hex(ctx.frame),
          width: sidebar,
          arm: Theme.size(:elbow_arm),
          height: Theme.size(:top),
          bar: Theme.size(:top_bar),
          label: elbow_label("PICTURE RAIL")
        ),
        header(ctx)
      ]),
      row([width(fill()), height(fill()), spacing(gap)], [
        sidebar_nav(ctx, middle_h),
        el([width(fill()), height(fill()), padding_xy(Theme.size(:gutter), 8)] ++ swipes, page)
      ]),
      row([width(fill()), height(px(Theme.size(:bottom))), spacing(gap)], [
        LCARS.elbow(
          corner: :bottom,
          color: Theme.hex(ctx.frame),
          width: sidebar,
          arm: Theme.size(:elbow_arm),
          height: Theme.size(:bottom),
          bar: Theme.size(:bottom_bar),
          label: none()
        ),
        column([width(fill()), height(fill())], [
          el([width(fill()), height(fill())], pager_row(pager)),
          bottom_bar(ctx)
        ])
      ])
    ])
  end

  defp portrait(ctx) do
    gap = Theme.size(:gap)
    content_w = ctx.w - 32
    nav_h = Theme.size(:nav) + 8
    bottom_h = Theme.size(:bottom_bar) + 64
    content_h = ctx.h - 32 - Theme.size(:top) - nav_h - bottom_h - 3 * gap - 16
    {page, swipes, pager} = content(ctx, content_w, 2, content_h)

    column([width(fill()), height(fill()), spacing(gap)], [
      row([width(fill()), height(px(Theme.size(:top))), spacing(gap)], [
        LCARS.elbow(
          corner: :top,
          color: Theme.hex(ctx.frame),
          width: 180,
          arm: Theme.size(:elbow_arm),
          height: Theme.size(:top),
          bar: Theme.size(:top_bar),
          label: elbow_label("PICTURE RAIL")
        ),
        header(ctx)
      ]),
      el([width(fill()), height(px(nav_h))], nav_row(ctx)),
      el([width(fill()), height(fill()), padding_xy(0, 8)] ++ swipes, page),
      column([width(fill()), height(px(bottom_h))], [
        el([width(fill()), height(fill())], pager_row(pager)),
        row([width(fill()), height(px(Theme.size(:bottom_bar))), spacing(gap)], [
          LCARS.cap(Theme.hex(ctx.frame), Theme.size(:bottom_bar), :left),
          bottom_bar(ctx)
        ])
      ])
    ])
  end

  defp elbow_label(label) do
    el(
      [
        align_right(),
        align_bottom(),
        padding_each(0, 18, 12, 0),
        Font.size(Theme.size(:small)),
        Font.color(Theme.color(:black))
      ],
      text(label)
    )
  end

  # The bar along the top, then the title, summaries and controls.
  defp header(ctx) do
    alert = if ctx.live?, do: [], else: [alert_attrs()]

    column([width(fill()), height(fill()), spacing(14)], [
      row([width(fill()), height(px(Theme.size(:top_bar))), spacing(Theme.size(:gap))], [
        LCARS.bar(Theme.hex(ctx.frame), [width(fill()), height(fill())] ++ alert),
        LCARS.bar(Theme.hex(:lilac), [width(px(140)), height(fill())]),
        LCARS.bar(Theme.hex(:peach), [
          width(px(60)),
          height(fill()),
          Border.rounded_each(0, 18, 18, 0)
        ])
      ]),
      row([width(fill()), spacing(12), padding_each(0, 0, 0, 12)], [
        el(
          [
            center_y(),
            width(fill()),
            Font.size(Theme.size(:title)),
            Font.color(Theme.color(if(ctx.live?, do: :peach, else: :red)))
          ],
          text(String.upcase(title(ctx)))
        )
        | header_controls(ctx)
      ])
    ])
  end

  defp alert_attrs do
    Animation.animate(
      [[Transform.alpha(1.0)], [Transform.alpha(0.35)], [Transform.alpha(1.0)]],
      2_000,
      :ease_in_out,
      :loop
    )
  end

  defp header_controls(ctx) do
    summaries =
      case ctx.ha.slice do
        %{summaries: summaries} when not ctx.portrait? ->
          Enum.map(summaries, &summary_pill(ctx, &1))

        _ ->
          []
      end

    back =
      if ctx.panel.depth > 0,
        do: [control_pill("BACK", :bluey, :back)],
        else: []

    summaries ++ energy_pill(ctx) ++ back ++ [control_pill("CLOSE", :orange, :hide)]
  end

  # Home Assistant's energy summary: today's home use, to the Energy page.
  defp energy_pill(
         %{portrait?: false, panel: %{view: :overview}, ha: %{energy: %{} = energy}} = ctx
       ) do
    [
      LCARS.pill(
        label: EnergyPage.label(energy),
        fill: pill_fill(Theme.hex(:gold), true, ctx.live?),
        height: 64,
        font: Theme.size(:small) + 3,
        attrs: [Event.on_press({:goto, :energy})]
      )
    ]
  end

  defp energy_pill(_ctx), do: []

  defp control_pill(label, color, message) do
    LCARS.pill(
      color: Theme.hex(color),
      label: label,
      height: 64,
      width: px(140),
      attrs: [Event.on_press(message)]
    )
  end

  @summary_labels %{
    light: "Lights",
    climate: "Climate",
    security: "Security",
    media_players: "Media",
    maintenance: "Batteries",
    persons: "People"
  }

  defp summary_pill(ctx, %{kind: kind, active: active}) do
    color = Theme.kind(kind)

    LCARS.pill(
      label: String.upcase("#{@summary_labels[kind]} #{active}"),
      fill: pill_fill(color, active > 0, ctx.live?),
      height: 64,
      font: Theme.size(:small) + 3,
      attrs: [Event.on_press({:goto, {:summary, kind}})]
    )
  end

  defp bottom_bar(ctx) do
    status =
      case ctx.ha.status do
        :connected -> "HA ONLINE"
        :connecting -> "HA CONNECTING"
        :disconnected -> "HA OFFLINE"
        {:auth_failed, _} -> "HA TOKEN REFUSED"
        _ -> "HA NOT SET UP"
      end

    row(
      [
        width(fill()),
        height(px(Theme.size(:bottom_bar))),
        align_bottom(),
        spacing(Theme.size(:gap))
      ],
      [
        LCARS.bar(Theme.hex(ctx.frame), [width(px(240)), height(fill())]),
        el(
          [
            center_y(),
            padding_xy(12, 0),
            Font.size(Theme.size(:small)),
            Font.color(Theme.color(ctx.frame))
          ],
          text(status)
        ),
        LCARS.bar(Theme.hex(:mauve), [width(fill()), height(fill())]),
        LCARS.bar(Theme.hex(:lilac), [
          width(px(60)),
          height(fill()),
          Border.rounded_each(0, 13, 13, 0)
        ])
      ]
    )
  end

  # Page number and PREV/NEXT, when the content has more than one page.
  defp pager_row(%{count: count}) when count <= 1, do: none()

  defp pager_row(%{page: page, count: count}) do
    step = fn label, target, ok? ->
      LCARS.pill(
        label: label,
        fill: Theme.color(if(ok?, do: Theme.hex(:bluey), else: Theme.dim(Theme.hex(:bluey)))),
        height: 52,
        width: px(130),
        attrs: if(ok?, do: [Event.on_press({:page, target})], else: [])
      )
    end

    row([align_right(), center_y(), spacing(10)], [
      el(
        [
          center_y(),
          padding_xy(12, 0),
          Font.size(Theme.size(:label)),
          Font.color(Theme.color(:peach))
        ],
        text("PAGE #{page + 1} / #{count}")
      ),
      step.("PREV", page - 1, page > 0),
      step.("NEXT", page + 1, page + 1 < count)
    ])
  end

  # -- Navigation --

  @doc false
  # From the `:ha` controller (`PictureRail.HA.Overview.nav/1`), then Setup,
  # which is there whether or not Home Assistant is.
  @spec nav_items(map()) :: [tuple()]
  def nav_items(ctx), do: (Map.get(ctx.ha, :nav) || []) ++ [{:view, :setup, "Setup"}]

  @nav_colors [:lilac, :bluey, :mauve, :peach, :sky, :almond]

  @divider_h 40
  @step_h 56

  # The sidebar: navigation blocks, cut into pages with UP/DOWN blocks when
  # they don't fit (swiping flips them too), the rest filled with the frame
  # colour.
  defp sidebar_nav(ctx, avail) do
    gap = Theme.size(:gap)
    items = ctx |> nav_items() |> Enum.with_index()

    height_of = fn
      {{:divider, _}, _} -> @divider_h + gap
      _ -> Theme.size(:nav) + gap
    end

    total = items |> Enum.map(height_of) |> Enum.sum()

    {shown, controls, swipes} =
      if total <= avail do
        {items, {[], []}, []}
      else
        pages = nav_pages(items, avail - 2 * (@step_h + gap), height_of)

        count = length(pages)
        page = ctx.panel |> Map.get(:nav_page, 0) |> Kernel.max(0) |> Kernel.min(count - 1)
        up? = page > 0
        down? = page + 1 < count

        {Enum.at(pages, page),
         {[nav_step("UP", {:nav_page, page - 1}, up?)],
          [nav_step("DOWN", {:nav_page, page + 1}, down?)]},
         swipes(:on_swipe_up, down?, {:nav_page, page + 1}) ++
           swipes(:on_swipe_down, up?, {:nav_page, page - 1})}
      end

    {top, bottom} = controls
    used = (shown |> Enum.map(height_of) |> Enum.sum()) + length(top ++ bottom) * (@step_h + gap)

    filler =
      LCARS.bar(Theme.hex(ctx.frame), [width(fill()), height(px(Kernel.max(0, avail - used)))])

    column(
      [width(px(Theme.size(:sidebar))), height(fill()), spacing(gap)] ++ swipes,
      top ++ Enum.map(shown, &nav_block(ctx, &1)) ++ [filler] ++ bottom
    )
  end

  defp nav_block(_ctx, {{:divider, name}, _i}) do
    el(
      [
        width(fill()),
        height(px(@divider_h)),
        padding_each(0, 14, 4, 0),
        Font.size(Theme.size(:small)),
        Font.color(Theme.color(:peach))
      ],
      el([align_right(), align_bottom()], text(String.upcase(name)))
    )
  end

  defp nav_block(ctx, {{:view, view, label}, i}) do
    LCARS.block(
      Theme.hex(Enum.at(@nav_colors, rem(i, length(@nav_colors)))),
      LCARS.fit(label, 16),
      active?: nav_active?(view, ctx.panel.view),
      attrs: [Event.on_press({:goto, view})]
    )
  end

  # A Setup section is under Setup in the navigation.
  defp nav_active?(:setup, current), do: setup_view?(current)
  defp nav_active?(view, current), do: view == current

  defp nav_step(label, message, enabled?) do
    LCARS.block(Theme.hex(:orange), label,
      height: @step_h,
      active?: false,
      dim?: not enabled?,
      attrs: if(enabled?, do: [Event.on_press(message)], else: [])
    )
  end

  @doc false
  # The navigation in pages of at most `limit` px; a floor divider stays
  # with the area after it, so it never ends a page.
  @spec nav_pages([term()], number(), (term() -> number())) :: [[term()]]
  def nav_pages(items, limit, height_of) do
    items
    |> nav_units()
    |> chunk_by_height(limit, &(&1 |> Enum.map(height_of) |> Enum.sum()))
    |> Enum.map(&Enum.concat/1)
  end

  defp nav_units([{{:divider, _}, _} = divider, next | rest]),
    do: [[divider, next] | nav_units(rest)]

  defp nav_units([item | rest]), do: [[item] | nav_units(rest)]
  defp nav_units([]), do: []

  # Split `items` into runs whose heights (`height_of`) fit `limit`.
  defp chunk_by_height(items, limit, height_of) do
    items
    |> Enum.chunk_while(
      {[], 0},
      fn item, {acc, used} ->
        h = height_of.(item)

        if acc != [] and used + h > limit,
          do: {:cont, Enum.reverse(acc), {[item], h}},
          else: {:cont, {[item | acc], used + h}}
      end,
      fn
        {[], _} -> {:cont, {[], 0}}
        {acc, _} -> {:cont, Enum.reverse(acc), {[], 0}}
      end
    )
  end

  # Portrait navigation: one row of pills, cut into pages with ‹ › pills.
  defp nav_row(ctx) do
    views = for {{:view, _, _}, _i} = item <- Enum.with_index(nav_items(ctx)), do: item
    label = fn {{:view, _, label}, _} -> String.upcase(LCARS.fit(label, 14)) end
    # Antonio is condensed: ~0.5 em per capital, plus the pill's padding
    width_of = fn item -> String.length(label.(item)) * Theme.size(:label) * 0.5 + 54 end
    step_w = 70
    pages = chunk_by_height(views, ctx.w - 32 - 2 * (step_w + 10), width_of)
    count = length(pages)
    page = ctx.panel |> Map.get(:nav_page, 0) |> Kernel.max(0) |> Kernel.min(count - 1)

    pills =
      for {{:view, view, _}, i} = item <- Enum.at(pages, page, []) do
        color = Theme.hex(Enum.at(@nav_colors, rem(i, length(@nav_colors))))

        LCARS.pill(
          label: label.(item),
          fill:
            Theme.color(if(nav_active?(view, ctx.panel.view), do: Theme.hex(:white), else: color)),
          height: Theme.size(:nav),
          attrs: [Event.on_press({:goto, view})]
        )
      end

    swipes =
      swipes(:on_swipe_left, page + 1 < count, {:nav_page, page + 1}) ++
        swipes(:on_swipe_right, page > 0, {:nav_page, page - 1})

    {before, after_} =
      if count > 1,
        do:
          {[nav_row_step("‹", page - 1, page > 0, step_w)],
           [nav_row_step("›", page + 1, page + 1 < count, step_w)]},
        else: {[], []}

    row(
      [width(fill()), spacing(10), padding_xy(0, 4)] ++ swipes,
      before ++ pills ++ [el([width(fill())], none())] ++ after_
    )
  end

  defp nav_row_step(label, target, enabled?, width) do
    LCARS.pill(
      label: label,
      font: 40,
      fill:
        Theme.color(if(enabled?, do: Theme.hex(:orange), else: Theme.dim(Theme.hex(:orange)))),
      height: Theme.size(:nav),
      width: px(width),
      attrs: if(enabled?, do: [Event.on_press({:nav_page, target})], else: [])
    )
  end

  # A swipe handler when it leads somewhere.
  defp swipes(_event, false, _message), do: []
  defp swipes(:on_swipe_up, true, message), do: [Event.on_swipe_up(message)]
  defp swipes(:on_swipe_down, true, message), do: [Event.on_swipe_down(message)]
  defp swipes(:on_swipe_left, true, message), do: [Event.on_swipe_left(message)]
  defp swipes(:on_swipe_right, true, message), do: [Event.on_swipe_right(message)]

  defp title(ctx), do: title(ctx.panel.view, ctx.ha)

  defp title(:overview, _ha), do: "Home"
  defp title(:media, _ha), do: "Media"
  defp title(:devices, _ha), do: "Devices"
  defp title(:energy, _ha), do: "Energy"
  defp title(:setup, _ha), do: "Setup"
  defp title({:setup, section}, _ha), do: Setup.label(section)
  defp title({:summary, kind}, _ha), do: @summary_labels[kind]
  defp title({:area, _}, %{slice: %{area: area}}), do: area.name
  defp title({:entity, id}, ha), do: name(ha, id, :full)
  defp title({:device, _}, %{slice: %{name: name}}), do: name || "Device"
  defp title(_view, _ha), do: ""

  # -- Content --
  #
  # Content is laid out as blocks (section headings, rows of pills of a known
  # height, whole elements) and cut into pages that fit the content area.
  # Only the current page is in the tree, and it doesn't scroll: on this CPU
  # Emerge needs ~0.1 s per scroll step for a long page, while a page flip is
  # one small redraw. Swiping up/down (or PREV/NEXT) flips pages.

  @section_gap 28
  @heading_gap 14
  @row_gap 12
  @heading_h 38

  # The current page and the pager for the bottom bar.
  defp content(ctx, content_w, cols, avail_h) do
    pill_w = Float.floor((content_w - (cols - 1) * @row_gap) / cols)
    ctx = Map.merge(ctx, %{pill_w: pill_w, cols: cols, content_w: content_w, content_h: avail_h})

    pages = ctx |> blocks(ctx.panel.view, ctx.ha.slice) |> paginate(avail_h)
    count = length(pages)
    page = ctx.panel |> Map.get(:page, 0) |> Kernel.max(0) |> Kernel.min(count - 1)

    swipes =
      swipes(:on_swipe_up, page + 1 < count, {:page, page + 1}) ++
        swipes(:on_swipe_down, page > 0, {:page, page - 1})

    {render_page(Enum.at(pages, page, [])), swipes, %{page: page, count: count}}
  end

  @doc false
  # Pack blocks into pages of at most `avail` px. A heading stays with its
  # first row; a section cut by a page repeats its heading on the next page.
  @spec paginate([tuple()], number()) :: [[tuple()]]
  def paginate([], _avail), do: [[]]

  def paginate(blocks, avail) do
    {pages, current, _used} =
      blocks
      |> units()
      |> Enum.reduce({[], [], 0}, fn unit, {pages, current, used} ->
        prev = List.first(current)
        needed = unit_height(unit, prev)

        if current == [] or used + needed <= avail do
          {pages, Enum.reverse(unit) ++ current, used + needed}
        else
          unit = continued(unit)
          {[Enum.reverse(current) | pages], Enum.reverse(unit), unit_height(unit, nil)}
        end
      end)

    Enum.reverse([Enum.reverse(current) | pages])
  end

  # Headings stick to the row after them.
  defp units(blocks) do
    {units, pending} =
      Enum.reduce(blocks, {[], []}, fn
        {kind, _, _} = heading, {units, pending} when kind in [:heading, :subheading] ->
          {units, pending ++ [heading]}

        block, {units, pending} ->
          {[pending ++ [block] | units], []}
      end)

    Enum.reverse(if pending == [], do: units, else: [pending | units])
  end

  # A row at the top of a page brings its headings along (a section's, or a
  # floor's and an area's).
  defp continued([{:row, _, _, headings} | _] = unit), do: List.wrap(headings) ++ unit

  # an area heading at the top of a page brings its floor's heading
  defp continued([{:subheading, _, _}, {:row, _, _, [heading | _]} | _] = unit),
    do: [heading | unit]

  defp continued(unit), do: unit

  defp unit_height(unit, prev) do
    {height, _} =
      Enum.reduce(unit, {0, prev}, fn block, {sum, prev} ->
        {sum + gap(prev, block) + block_height(block), block}
      end)

    height
  end

  defp gap(nil, _block), do: 0
  defp gap({:heading, _, _}, {:row, _, _, _}), do: @heading_gap
  defp gap({:row, _, _, _}, {:row, _, _, _}), do: @row_gap
  defp gap({:heading, _, _}, {:subheading, _, _}), do: 10
  defp gap({:subheading, _, _}, {:row, _, _, _}), do: 8
  defp gap({:row, _, _, _}, {:subheading, _, _}), do: 20
  defp gap(_prev, _block), do: @section_gap

  defp block_height({:heading, _, _}), do: @heading_h
  defp block_height({:subheading, _, _}), do: 30
  defp block_height({:row, h, _, _}), do: h
  defp block_height({:block, h, _}), do: h

  defp render_page(blocks) do
    {children, _} =
      Enum.flat_map_reduce(blocks, nil, fn block, prev ->
        spacer =
          if gap(prev, block) > 0, do: [el([height(px(gap(prev, block)))], none())], else: []

        {spacer ++ [block_element(block)], block}
      end)

    column([width(fill())], children)
  end

  defp block_element({:heading, color, title}), do: LCARS.heading(color, title)
  defp block_element({:subheading, color, title}), do: LCARS.subheading(color, title)
  defp block_element({:row, _h, items, _heading}), do: row([spacing(@row_gap)], items)
  defp block_element({:block, _h, element}), do: element

  # A section as blocks: a heading, then rows of `per_row` items `item_h` tall.
  defp section(color, title, items, per_row, item_h) do
    heading = {:heading, color, title}
    rows = items |> Enum.chunk_every(per_row) |> Enum.map(&{:row, item_h, &1, heading})
    [heading | rows]
  end

  defp blocks(ctx, :energy, nil), do: empty(ctx, "No energy dashboard in Home Assistant")

  # Page 1: the distribution schematic; then the gauges and the hourly chart.
  defp blocks(ctx, :energy, summary) do
    power = summary.power_entity && ctx.ha.states[summary.power_entity]
    gauge_w = Float.floor((ctx.content_w - @row_gap) / 2)
    today = {:heading, Theme.hex(:peach), "Today"}
    hourly = {:heading, Theme.hex(:gold), "Hourly use"}

    gauges =
      case EnergyPage.gauges(summary, gauge_w) do
        [] -> []
        gauges -> [today, {:row, 84, gauges, today}]
      end

    [
      {:block, ctx.content_h,
       EnergyPage.schematic(summary, power, ctx.content_w, ctx.content_h, ctx.live?)}
    ] ++
      gauges ++
      [hourly, {:row, 300, [EnergyPage.chart(summary, ctx.content_w, 300)], hourly}]
  end

  defp blocks(ctx, view, _slice) when is_setup_view(view), do: SetupPage.blocks(ctx, view)

  defp blocks(ctx, _view, slice) when slice in [nil, :loading],
    do: empty(ctx, waiting_message(ctx.ha.status))

  defp blocks(ctx, _view, :gone), do: empty(ctx, "Not in Home Assistant any more")

  defp blocks(ctx, :overview, %{floors: floors, other_areas: others, devices?: devices?}) do
    tile_cols = Kernel.max(ctx.cols - 1, 2)
    tile_w = Float.floor((ctx.content_w - (tile_cols - 1) * @row_gap) / tile_cols)
    tiles = &Enum.map(&1, fn area -> area_tile(area, tile_w) end)

    floor_sections =
      for {%{floor: floor, areas: areas}, i} <- Enum.with_index(floors) do
        section(
          Theme.hex(Enum.at(@nav_colors, rem(i, length(@nav_colors)))),
          floor.name,
          tiles.(areas),
          tile_cols,
          110
        )
      end

    other =
      case others do
        [] -> []
        areas -> [section(Theme.hex(:almond), "Areas", tiles.(areas), tile_cols, 110)]
      end

    devices =
      if devices?,
        do: [
          section(
            Theme.hex(:lilac),
            "Other",
            [
              LCARS.pill(
                label: "DEVICES",
                color: Theme.hex(:lilac),
                width: px(tile_w),
                height: 110,
                attrs: [Event.on_press({:goto, :devices})]
              )
            ],
            tile_cols,
            110
          )
        ],
        else: []

    case floor_sections ++ other ++ devices do
      [] -> empty(ctx, "No areas")
      sections -> List.flatten(sections)
    end
  end

  defp blocks(ctx, {:area, _}, %{sections: sections}) do
    case sections do
      [] -> empty(ctx, "Nothing here")
      sections -> with_device_pills(ctx, sections)
    end
  end

  defp blocks(ctx, {:device, _}, %{kind: :device} = section),
    do: entity_section(ctx, %{section | name: "Entities"})

  defp blocks(ctx, {:summary, kind}, %{sections: sections}),
    do: summary_blocks(ctx, kind, sections)

  defp blocks(ctx, :media, groups) when is_list(groups) do
    case groups do
      [] ->
        empty(ctx, "No media players")

      groups ->
        Enum.flat_map(groups, fn %{area: area, entity_ids: ids} ->
          entity_section(ctx, %{
            kind: :media_players,
            name: (area && area.name) || "No area",
            entity_ids: ids
          })
        end)
    end
  end

  defp blocks(ctx, :devices, groups) when is_list(groups) do
    case groups do
      [] -> empty(ctx, "All organised")
      groups -> with_device_pills(ctx, groups)
    end
  end

  defp blocks(ctx, {:entity, id}, _slice), do: [{:block, 0, detail(ctx, id)}]
  defp blocks(ctx, _view, _slice), do: empty(ctx, "")

  defp empty(_ctx, message) do
    [
      {:block, 80,
       el(
         [padding(24), Font.size(Theme.size(:heading)), Font.color(Theme.color(:peach))],
         text(String.upcase(message))
       )}
    ]
  end

  # A summary's page, laid out like Home Assistant's light/climate/security/
  # maintenance pages (research/ha-maintenance-page.md): a section per
  # floor (titled "Areas" when there's only one), an area heading inside it
  # for each area with entities, then areas without a floor ("Other areas"),
  # then entities without an area ("Other devices"; "Other lights").
  # Batteries go by their device's name and are coloured by level.
  defp summary_blocks(ctx, kind, sections) do
    color = Theme.kind(kind)

    Enum.flat_map(sections, fn %{title: title, groups: groups} ->
      heading = {:heading, color, title}

      [
        heading
        | Enum.flat_map(groups, fn
            %{title: nil, entity_ids: ids} ->
              summary_rows(ctx, kind, ids, heading)

            %{title: area, entity_ids: ids} ->
              sub = {:subheading, color, area}
              [sub | summary_rows(ctx, kind, ids, [heading, sub])]
          end)
      ]
    end)
  end

  defp summary_rows(ctx, kind, ids, headings) do
    ids
    |> Enum.map(&summary_pill_for(ctx, kind, &1))
    |> Enum.chunk_every(ctx.cols)
    |> Enum.map(&{:row, Theme.size(:pill), &1, headings})
  end

  defp summary_pill_for(ctx, :maintenance, id),
    do: entity_pill(ctx, id, :device, color: battery_color(ctx.ha.states[id]))

  defp summary_pill_for(ctx, _kind, id), do: entity_pill(ctx, id, :full)

  # HA's battery icon colours: high at 70 % and over, medium at 30 %, low
  # below; a low-battery binary sensor that's on is low.
  defp battery_color(%{entity_id: "binary_sensor." <> _, state: "on"}), do: Theme.hex(:red)
  defp battery_color(%{entity_id: "binary_sensor." <> _}), do: Theme.hex(:sky)

  defp battery_color(%{state: state}) do
    case Float.parse(state) do
      {level, _} when level >= 70 -> Theme.hex(:sky)
      {level, _} when level >= 30 -> Theme.hex(:gold)
      {_level, _} -> Theme.hex(:red)
      :error -> nil
    end
  end

  defp battery_color(_es), do: nil

  @kind_titles %{
    light: "Light",
    climate: "Climate",
    security: "Security",
    media_players: "Media",
    scenes: "Scenes",
    automations: "Automations"
  }

  defp entity_section(ctx, %{kind: :device} = s) do
    title = s.name || "Other"

    title =
      case Map.get(s, :battery) && ctx.ha.states[s.battery] do
        %{} = battery -> "#{title}   ·   battery #{Format.state(battery)}"
        _ -> title
      end

    # under a device heading, entities go by their own name
    section(
      Theme.kind(:device),
      title,
      Enum.map(s.entity_ids, &entity_pill(ctx, &1, :own)),
      ctx.cols,
      Theme.size(:pill)
    )
  end

  defp entity_section(ctx, %{kind: kind} = s) do
    title = Map.get(s, :name) || @kind_titles[kind] || ""

    section(
      Theme.kind(kind),
      title,
      Enum.map(s.entity_ids, &entity_pill(ctx, &1, :full)),
      ctx.cols,
      Theme.size(:pill)
    )
  end

  # Devices show as one pill each (their entities are on the device's own
  # page), gathered into one section where the first device group was. A
  # room with hundreds of entities would otherwise make a page too long to
  # scroll smoothly: Emerge re-walks the whole tree on every scroll step.
  defp with_device_pills(ctx, sections) do
    {devices, others} =
      Enum.split_with(sections, &match?(%{kind: :device, device_id: id} when is_binary(id), &1))

    at = Enum.find_index(sections, &(&1 in devices))

    others = Enum.map(others, &entity_section(ctx, &1))

    case devices do
      [] ->
        List.flatten(others)

      devices ->
        pills =
          section(
            Theme.kind(:device),
            "Devices",
            Enum.map(devices, &device_pill(ctx, &1)),
            ctx.cols,
            Theme.size(:pill)
          )

        others |> List.insert_at(Kernel.min(at, length(others)), pills) |> List.flatten()
    end
  end

  defp device_pill(ctx, %{device_id: id, name: name} = s) do
    battery =
      case Map.get(s, :battery) && ctx.ha.states[s.battery] do
        %{} = es -> "  ·  BATTERY #{Format.state(es)}"
        _ -> ""
      end

    count = length(s.entity_ids)
    chars = trunc((ctx.pill_w - 60) / (Theme.size(:label) * 0.42))

    LCARS.pill(
      label: String.upcase(LCARS.fit(name || "Unnamed device", chars)),
      sub: "#{count} #{if count == 1, do: "ENTITY", else: "ENTITIES"}#{battery}",
      color: Theme.kind(:device),
      width: px(ctx.pill_w),
      attrs: [Event.on_press({:device, id})]
    )
  end

  defp area_tile(%{area: area, temperature: temperature}, tile_w) do
    # always two lines, so tiles with and without a reading line up
    sub = if temperature, do: Format.state(temperature), else: ""

    LCARS.pill(
      label: String.upcase(LCARS.fit(area.name, 22)),
      sub: sub,
      fill: pill_fill(Theme.hex(:bluey), true, true),
      width: px(tile_w),
      height: 110,
      font: Theme.size(:heading),
      # the model is kept while disconnected, so areas still open
      attrs: [Event.on_press({:goto, {:area, area.area_id}})]
    )
  end

  # -- Pills --

  defp entity_pill(ctx, entity_id, name_form, opts \\ []) do
    es = ctx.ha.states[entity_id]
    usable? = ctx.live? and Overview.available?(es)

    fill =
      case opts[:color] do
        nil -> pill_fill(Theme.domain(Index.domain(entity_id)), Format.on?(es), usable?)
        color -> pill_fill(color, true, usable?)
      end

    chevron? = detail?(entity_id) and usable?
    chars = trunc((ctx.pill_w - if(chevron?, do: 110, else: 60)) / (Theme.size(:label) * 0.42))

    main =
      LCARS.pill(
        label: String.upcase(LCARS.fit(name(ctx.ha, entity_id, name_form), chars)),
        sub: LCARS.fit(Format.state(es), chars + 6),
        fill: fill,
        width: fill(),
        rounded: if(chevron?, do: :left, else: :both),
        attrs: if(usable?, do: [Event.on_press({:pill, entity_id})], else: [])
      )

    children =
      if chevron?,
        do: [
          main,
          Input.button(
            [
              width(px(58)),
              height(fill()),
              Background.color(fill),
              Border.rounded_each(0, 42, 42, 0),
              Font.size(44),
              Font.color(Theme.color(:black)),
              Event.on_press({:detail, entity_id})
            ],
            el([center_x(), center_y()], text("›"))
          )
        ],
        else: [main]

    row([width(px(ctx.pill_w)), height(px(Theme.size(:pill))), spacing(4)], children)
  end

  # From the `:ha` controller (it reads the model; the view doesn't)
  defp name(ha, entity_id, form), do: Map.get(ha.names || %{}, {entity_id, form}, entity_id)

  defp pill_fill(_color, _on?, false), do: Theme.color(:grey, 0.5)
  defp pill_fill(color, true, true), do: Theme.color(color)
  defp pill_fill(color, false, true), do: Theme.color(Theme.dim(color))

  # -- Detail views --

  defp detail(ctx, entity_id) do
    es = ctx.ha.states[entity_id]
    domain = Index.domain(entity_id)
    usable? = ctx.live? and Overview.available?(es)
    color = Theme.domain(domain)

    controls = if usable?, do: detail_controls(ctx, domain, entity_id, es, color), else: []

    column([width(fill()), spacing(24)], [
      LCARS.heading(color, Format.state(es)),
      column([width(px(Kernel.min(ctx.content_w, 1100))), spacing(24)], controls)
    ])
  end

  defp detail_controls(ctx, "light", id, es, color) do
    attrs = es.attributes
    modes = attrs["supported_color_modes"] || []
    on? = es.state == "on"

    brightness =
      if modes != ["onoff"] and modes != [],
        do: [
          labelled(
            "Brightness",
            slider(
              ctx,
              id,
              :brightness,
              color,
              1,
              100,
              1,
              round((attrs["brightness"] || 0) / 255 * 100)
            )
          )
        ],
        else: []

    temp =
      if ("color_temp" in modes and attrs["min_color_temp_kelvin"]) &&
           attrs["max_color_temp_kelvin"],
         do: [
           labelled(
             "Colour temperature",
             slider(
               ctx,
               id,
               :color_temp,
               Theme.hex(:peach),
               attrs["min_color_temp_kelvin"],
               attrs["max_color_temp_kelvin"],
               50,
               attrs["color_temp_kelvin"] || attrs["min_color_temp_kelvin"]
             )
           )
         ],
         else: []

    [
      action_row([
        action(
          "On",
          color,
          %{domain: "light", service: "turn_on", entity_id: id, optimistic: "on"},
          on?
        ),
        action(
          "Off",
          color,
          %{domain: "light", service: "turn_off", entity_id: id, optimistic: "off"},
          not on?
        )
      ])
    ] ++ brightness ++ temp
  end

  defp detail_controls(_ctx, "climate", id, es, color) do
    attrs = es.attributes
    step = attrs["target_temp_step"] || 0.5
    target = attrs["temperature"]

    setpoint =
      if is_number(target),
        do: [
          action_row([
            action("−", color, set_temperature(id, target - step), false),
            el(
              [width(px(220)), center_y(), Font.size(64), Font.color(Theme.color(color))],
              el([center_x()], text("#{target}°"))
            ),
            action("+", color, set_temperature(id, target + step), false)
          ])
        ],
        else: []

    modes =
      for mode <- attrs["hvac_modes"] || [] do
        action(
          String.replace(mode, "_", " "),
          color,
          %{
            domain: "climate",
            service: "set_hvac_mode",
            entity_id: id,
            data: %{hvac_mode: mode},
            optimistic: mode
          },
          es.state == mode
        )
      end

    setpoint ++ [labelled("Mode", action_row(modes))]
  end

  defp detail_controls(ctx, "cover", id, es, color) do
    buttons =
      action_row([
        action(
          "Open",
          color,
          %{domain: "cover", service: "open_cover", entity_id: id},
          es.state == "open"
        ),
        action("Stop", color, %{domain: "cover", service: "stop_cover", entity_id: id}, false),
        action(
          "Close",
          color,
          %{domain: "cover", service: "close_cover", entity_id: id},
          es.state == "closed"
        )
      ])

    position =
      case es.attributes["current_position"] do
        p when is_number(p) ->
          [labelled("Position", slider(ctx, id, :position, color, 0, 100, 1, p))]

        _ ->
          []
      end

    [buttons | position]
  end

  defp detail_controls(ctx, "media_player", id, es, color) do
    attrs = es.attributes
    call = fn service -> %{domain: "media_player", service: service, entity_id: id} end

    transport =
      action_row([
        action("‹‹", color, call.("media_previous_track"), false),
        action(
          if(es.state == "playing", do: "Pause", else: "Play"),
          color,
          call.("media_play_pause"),
          true
        ),
        action("››", color, call.("media_next_track"), false)
      ])

    volume =
      case attrs["volume_level"] do
        v when is_number(v) ->
          [labelled("Volume", slider(ctx, id, :volume, color, 0, 100, 1, round(v * 100)))]

        _ ->
          []
      end

    sources =
      case attrs["source_list"] do
        [_ | _] = list ->
          [
            labelled(
              "Source",
              action_row(
                for source <- Enum.take(list, 8) do
                  action(
                    source,
                    color,
                    %{
                      domain: "media_player",
                      service: "select_source",
                      entity_id: id,
                      data: %{source: source}
                    },
                    attrs["source"] == source
                  )
                end
              )
            )
          ]

        _ ->
          []
      end

    [transport] ++ volume ++ sources
  end

  defp detail_controls(_ctx, _domain, id, es, color) do
    case tap_action(id, es) do
      nil ->
        []

      request ->
        [
          action_row([
            action(if(request[:optimistic], do: "Toggle", else: "Run"), color, request, true)
          ])
        ]
    end
  end

  defp set_temperature(id, value),
    do: %{
      domain: "climate",
      service: "set_temperature",
      entity_id: id,
      data: %{temperature: value}
    }

  defp action_row(children), do: wrapped_row([width(fill()), spacing_xy(12, 12)], children)

  defp action(label, color, request, active?) do
    LCARS.pill(
      label: String.upcase(label),
      fill: Theme.color(if(active?, do: color, else: Theme.dim(color))),
      width: px(200),
      attrs: [Event.on_press({:call, request})]
    )
  end

  defp labelled(label, child) do
    column([width(fill()), spacing(10)], [
      el(
        [Font.size(Theme.size(:label)), Font.color(Theme.color(:peach))],
        text(String.upcase(label))
      ),
      child
    ])
  end

  # Keyed by entity and kind, so moving from one entity's detail to
  # another's doesn't reuse this slider (and its drag) by position; in an
  # el of its own, as keyed siblings must all be keyed.
  defp slider(ctx, id, kind, color, min, max, step, value) do
    value = Map.get(ctx.sliders, {id, kind}, value)

    el([width(fill())], slider_input(id, kind, color, min, max, step, value))
  end

  defp slider_input(id, kind, color, min, max, step, value) do
    Input.slider(
      [
        key({:slider, id, kind}),
        width(fill()),
        height(px(80)),
        Slider.config(
          min: min,
          max: max,
          step: step,
          track:
            el(
              [
                height(px(28)),
                center_y(),
                Background.color(Theme.color(Theme.dim(color))),
                Border.rounded(14)
              ],
              none()
            ),
          filled_track:
            el(
              [
                height(px(28)),
                center_y(),
                Background.color(Theme.color(color)),
                Border.rounded(14)
              ],
              none()
            ),
          thumb:
            el(
              [
                width(px(48)),
                height(px(80)),
                Background.color(Theme.color(:peach)),
                Border.rounded(14)
              ],
              none()
            )
        ),
        Event.on_change({:slider, id, kind})
      ],
      Kernel.max(min, Kernel.min(max, value))
    )
  end
end
