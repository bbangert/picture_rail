defmodule PictureRail.View.EnergyPage do
  @moduledoc """
  The Energy page's drawings, LCARS-style:

    * `schematic/4` - Home Assistant's energy distribution card as an
      engineering power schematic: a readout per system (solar, grid, home,
      battery, gas, water) joined by conduits carrying today's kWh, with a
      pulse running the way the energy flowed
    * `gauges/2` - self-sufficiency and solar self-use as bar gauges
    * `chart/3` - today's hourly use (from the grid, from solar) above the
      axis and what went back to the grid below it

  Systems are placed on a fixed canvas from its size, so the same drawing
  works landscape and portrait.
  """
  use Emerge.UI

  alias PictureRail.HA.Energy
  alias PictureRail.View.Theme

  @conduit 14
  @active 0.01

  @doc "The summary pill's label."
  @spec label(Energy.t()) :: String.t()
  def label(%{totals: %{home: home}}), do: "ENERGY #{round(home)} KWH"
  def label(_summary), do: "ENERGY"

  # -- Schematic --

  @doc """
  The distribution schematic, `w` x `h`. `power` is the grid power
  sensor's state (or `nil`); `live?` false greys the conduits.
  """
  @spec schematic(Energy.t(), Hassock.EntityState.t() | nil, number(), number(), boolean()) ::
          term()
  def schematic(summary, power, w, h, live?) do
    t = summary.totals
    f = summary.flows
    solar? = Map.has_key?(t, :solar)
    battery? = Map.has_key?(t, :battery_out) or Map.has_key?(t, :battery_in)
    utilities = Enum.filter([:gas, :water], &Map.has_key?(t, &1))

    nw = Kernel.min(w * 0.22, 330.0) |> Float.round()
    nh = 196.0
    gap_y = Kernel.max((h - nh * 3) / 2, 40.0)

    home =
      {(w - nw) / 2,
       if(solar?, do: nh + gap_y, else: (h - nh) / 2 - if(battery?, do: nh / 2, else: 0))}

    grid = {w * 0.04, elem(home, 1)}
    {hx, hy} = home
    {gx, gy} = grid

    pieces =
      [
        # grid -> home
        hconduit(gx + nw, hy + nh / 2, hx - (gx + nw), :orange, f.grid_to_home, :right, live?),
        label_box(gx + nw + (hx - gx - nw) / 2, hy + nh / 2 - 46, kwh(f.grid_to_home), :orange)
      ] ++
        if(solar?, do: solar_pieces(summary, home, grid, nw, nh, live?), else: []) ++
        if(battery?, do: battery_pieces(summary, home, nw, nh, h, live?), else: []) ++
        utility_pieces(summary, utilities, home, nw, nh, w, live?) ++
        [
          place(gx, gy, system(:orange, "Grid", kwh(t[:grid_in]), grid_subs(t, power), nw, nh)),
          place(hx, hy, system(:peach, "Home", kwh(t[:home]), home_subs(summary), nw, nh))
        ]

    el([width(px(w)), height(px(h))] ++ Enum.map(pieces, &Nearby.in_front/1), none())
  end

  defp solar_pieces(summary, {hx, hy}, {gx, gy}, nw, nh, live?) do
    f = summary.flows
    sx = hx
    mid_x = gx + nw / 2

    [
      # solar -> home, down
      vconduit(sx + nw / 2, nh, hy - nh, :gold, f.solar_to_home, :down, live?),
      label_box(sx + nw / 2 + 24, nh + (hy - nh) / 2 - 18, kwh(f.solar_to_home), :gold),
      # solar -> grid: an elbow from solar's left side down to the grid
      elbow(
        mid_x - @conduit / 2,
        nh / 2 - @conduit / 2,
        sx - mid_x + @conduit / 2,
        gy - nh / 2 + @conduit / 2,
        :bluey,
        f.solar_to_grid,
        live?
      ),
      label_box(mid_x + (sx - mid_x) / 2, nh / 2 - 50, kwh(f.solar_to_grid), :bluey),
      place(sx, 0, system(:gold, "Solar", kwh(summary.totals.solar), solar_subs(summary), nw, nh))
    ]
  end

  defp battery_pieces(summary, {hx, hy}, nw, nh, h, live?) do
    t = summary.totals
    f = summary.flows
    by = h - nh

    [
      vconduit(hx + nw / 2, hy + nh, by - hy - nh, :mauve, f.battery_to_home, :up, live?),
      label_box(
        hx + nw / 2 + 24,
        hy + nh + (by - hy - nh) / 2 - 18,
        kwh(f.battery_to_home),
        :mauve
      ),
      place(
        hx,
        by,
        system(
          :mauve,
          "Battery",
          "OUT #{kwh(t[:battery_out])}",
          [
            "IN #{kwh(t[:battery_in])}",
            "FROM SOLAR #{kwh(f.solar_to_battery)}",
            "FROM GRID #{kwh(f.grid_to_battery)}"
          ],
          nw,
          nh
        )
      )
    ]
  end

  # Gas and water hang off a bus on the home's right.
  defp utility_pieces(_summary, [], _home, _nw, _nh, _w, _live?), do: []

  defp utility_pieces(summary, kinds, {hx, hy}, nw, nh, w, live?) do
    t = summary.totals
    ux = w - w * 0.04 - nw
    bus_x = hx + nw + (ux - hx - nw) / 2
    cy = hy + nh / 2
    n = length(kinds)
    ys = for i <- 0..(n - 1), do: cy + (i - (n - 1) / 2) * (nh + 24) - nh / 2
    centers = Enum.map(ys, &(&1 + nh / 2))
    top = Enum.min([cy | centers])
    bottom = Enum.max([cy | centers])

    [
      hconduit(hx + nw, cy, bus_x - hx - nw, :lilac, 0.0, :right, live?),
      vconduit(bus_x, top - @conduit / 2, bottom - top + @conduit, :lilac, 0.0, :down, live?)
    ] ++
      Enum.flat_map(Enum.zip(kinds, ys), fn {kind, y} ->
        color = if kind == :gas, do: :almond, else: :sky
        cost = t[if(kind == :gas, do: :gas_cost, else: :water_cost)]
        unit = Map.get(summary.units, kind, "")
        subs = if cost, do: ["COST #{money(cost)}"], else: []

        [
          hconduit(bus_x, y + nh / 2, ux - bus_x, color, t[kind], :left, live?),
          place(
            ux,
            y,
            system(color, title(kind), "#{volume(t[kind])} #{String.upcase(unit)}", subs, nw, nh)
          )
        ]
      end)
  end

  defp title(:gas), do: "Gas"
  defp title(:water), do: "Water"

  defp grid_subs(t, power) do
    returned = if Map.has_key?(t, :grid_out), do: ["RETURNED #{kwh(t.grid_out)}"], else: []

    cost =
      if t[:grid_cost],
        do: ["COST #{money(t.grid_cost - Map.get(t, :compensation, 0.0))}"],
        else: []

    now =
      case power do
        %{state: state, attributes: attrs} ->
          ["NOW #{state} #{String.upcase(attrs["unit_of_measurement"] || "")}" |> String.trim()]

        _ ->
          []
      end

    now ++ returned ++ cost
  end

  defp home_subs(%{self_sufficiency: s, solar_self_use: u}) do
    Enum.reject(
      [s && "SELF-SUFFICIENT #{percent(s)}", u && "SOLAR USED #{percent(u)}"],
      &is_nil/1
    )
  end

  defp solar_subs(%{flows: f}),
    do: ["TO HOME #{kwh(f.solar_to_home)}", "TO GRID #{kwh(f.solar_to_grid)}"]

  # A system readout: a coloured band with the name, a big figure, notes.
  defp system(color, name, value, subs, w, h) do
    c = Theme.color(color)

    column(
      [
        width(px(w)),
        height(px(h)),
        Background.color(Theme.color(:black)),
        Border.width(4),
        Border.color(c),
        Border.rounded(28)
      ],
      [
        el(
          [
            width(fill()),
            height(px(44)),
            Background.color(c),
            Border.rounded_each(24, 24, 0, 0),
            padding_xy(22, 0),
            Font.size(Theme.size(:label)),
            Font.color(Theme.color(:black))
          ],
          el([center_y(), align_right()], text(String.upcase(name)))
        ),
        el([padding_each(4, 22, 0, 22), Font.size(50), Font.color(c)], text(value))
        | Enum.map(
            subs,
            &el(
              [padding_xy(22, 1), Font.size(Theme.size(:small)), Font.color(Theme.color(:peach))],
              text(&1)
            )
          )
      ]
    )
  end

  defp place(x, y, child) do
    el(
      [width(fill()), height(fill()), padding_each(round(y), 0, 0, round(x))],
      child
    )
  end

  # A conduit, dim when nothing flowed; a pulse runs along a live one.
  defp hconduit(x, y, len, color, flow, dir, live?),
    do: conduit({x, y - @conduit / 2}, {len, @conduit}, color, flow, {:x, dir}, live?)

  defp vconduit(x, y, len, color, flow, dir, live?),
    do: conduit({x - @conduit / 2, y}, {@conduit, len}, color, flow, {:y, dir}, live?)

  defp conduit({x, y}, {w, h}, color, flow, {axis, dir}, live?) do
    active? = live? and flow > @active
    hex = if active?, do: Theme.hex(color), else: Theme.dim(Theme.hex(color))
    pulse = if active?, do: [Nearby.in_front(pulse(axis, dir, w, h))], else: []

    place(
      x,
      y,
      el(
        [
          width(px(Kernel.max(w, 1))),
          height(px(Kernel.max(h, 1))),
          Background.color(Theme.color(hex)),
          Border.rounded(@conduit / 2)
        ] ++
          pulse,
        none()
      )
    )
  end

  defp pulse(axis, dir, w, h) do
    {len, size} = if axis == :x, do: {w, {36, h}}, else: {h, {w, 36}}
    travel = Kernel.max(len - 36, 0)
    {from, to} = if dir in [:right, :down], do: {0.0, travel * 1.0}, else: {travel * 1.0, 0.0}
    move = if axis == :x, do: &Transform.move_x/1, else: &Transform.move_y/1
    {pw, ph} = size

    el(
      [
        width(px(pw)),
        height(px(ph)),
        Background.color(Theme.color(:white, 0.85)),
        Border.rounded(@conduit / 2),
        Animation.animate([[move.(from)], [move.(to)]], 1_800, :linear, :loop)
      ],
      none()
    )
  end

  # An elbow conduit: down the left side, along the top, rounded corner.
  defp elbow(x, y, w, h, color, flow, live?) do
    active? = live? and flow > @active
    hex = if active?, do: Theme.hex(color), else: Theme.dim(Theme.hex(color))

    place(
      x,
      y,
      el(
        [
          width(px(Kernel.max(w, 1))),
          height(px(Kernel.max(h, 1))),
          Border.width_each(@conduit, 0, 0, @conduit),
          Border.color(Theme.color(hex)),
          Border.rounded_each(@conduit * 3, 0, 0, 0)
        ],
        none()
      )
    )
  end

  defp label_box(cx, y, label, color) do
    place(
      cx - 70,
      y,
      el(
        [
          width(px(140)),
          height(px(36)),
          Background.color(Theme.color(:black)),
          Font.size(Theme.size(:label)),
          Font.color(Theme.color(color))
        ],
        el([center_x(), center_y()], text(label))
      )
    )
  end

  # -- Gauges --

  @doc "Self-sufficiency and solar self-use as bar gauges, each `w` wide."
  @spec gauges(Energy.t(), number()) :: [term()]
  def gauges(summary, w) do
    [
      {"Self-sufficiency", summary.self_sufficiency, :peach},
      {"Solar used at home", summary.solar_self_use, :gold}
    ]
    |> Enum.reject(fn {_label, value, _color} -> is_nil(value) end)
    |> Enum.map(fn {label, value, color} -> gauge(label, value, color, w) end)
  end

  defp gauge(label, value, color, w) do
    c = Theme.hex(color)

    column([width(px(w)), height(px(84)), spacing(10)], [
      row([width(fill())], [
        el(
          [Font.size(Theme.size(:label)), Font.color(Theme.color(c))],
          text(String.upcase(label))
        ),
        el(
          [align_right(), Font.size(Theme.size(:label)), Font.color(Theme.color(c))],
          text(percent(value))
        )
      ]),
      el(
        [
          width(fill()),
          height(px(36)),
          Background.color(Theme.color(Theme.dim(c))),
          Border.rounded(18)
        ],
        el(
          [
            width(px(Kernel.max(36, round(w * value)))),
            height(fill()),
            Background.color(Theme.color(c)),
            Border.rounded(18)
          ],
          none()
        )
      )
    ])
  end

  # -- Chart --

  @doc """
  Hourly use as bars, `w` x `h`: from the grid (orange) on top of solar
  used at home (gold), and returned to the grid (blue) below the axis.
  """
  @spec chart(Energy.t(), number(), number()) :: term()
  def chart(%{hourly: hours, day_start: day_start}, w, h) do
    slots = 24
    gap = 4
    slot_w = Float.floor((w - (slots - 1) * gap) / slots)
    h = h - 40
    up_h = h * 0.68
    down_h = h * 0.2
    label_h = h - up_h - down_h - 7
    used = fn hour -> Kernel.max(0.0, hour.solar - hour.grid_out) end

    max_up =
      hours |> Enum.map(&(&1.grid_in + used.(&1))) |> Enum.max(fn -> 0.0 end) |> Kernel.max(0.1)

    max_down = hours |> Enum.map(& &1.grid_out) |> Enum.max(fn -> 0.0 end) |> Kernel.max(0.1)
    by_slot = Map.new(hours, &{div(&1.start - (day_start || &1.start), 3_600_000), &1})

    bars =
      for slot <- 0..(slots - 1) do
        hour = Map.get(by_slot, slot, %{grid_in: 0.0, grid_out: 0.0, solar: 0.0})
        grid = up_h * hour.grid_in / max_up
        solar = up_h * used.(hour) / max_up
        back = down_h * hour.grid_out / max_down

        column([width(px(slot_w)), height(px(h))], [
          el([height(px(Kernel.max(0.0, up_h - grid - solar)))], none()),
          bar(:orange, slot_w, grid),
          # a black seam keeps grid and solar apart (their colours are close)
          if(grid >= 0.5 and solar >= 0.5, do: el([height(px(3))], none()), else: none()),
          bar(:gold, slot_w, solar),
          el([width(fill()), height(px(4)), Background.color(Theme.color(:lilac))], none()),
          bar(:bluey, slot_w, back),
          el([height(px(down_h - back))], none()),
          el(
            [
              width(fill()),
              height(px(label_h)),
              Font.size(Theme.size(:small)),
              Font.color(Theme.color(:peach))
            ],
            if(rem(slot, 3) == 0,
              do: el([center_x(), align_bottom()], text(String.pad_leading("#{slot}", 2, "0"))),
              else: none()
            )
          )
        ])
      end

    column([width(px(w)), spacing(8)], [
      row([align_right(), spacing(18)], [
        legend(:orange, "From grid"),
        legend(:gold, "Solar"),
        legend(:bluey, "Returned")
      ]),
      row([width(px(w)), height(px(h)), spacing(gap)], bars)
    ])
  end

  defp legend(color, label) do
    row([spacing(8)], [
      el(
        [
          width(px(18)),
          height(px(18)),
          center_y(),
          Background.color(Theme.color(color)),
          Border.rounded(4)
        ],
        none()
      ),
      el(
        [center_y(), Font.size(Theme.size(:small)), Font.color(Theme.color(:peach))],
        text(String.upcase(label))
      )
    ])
  end

  defp bar(_color, _w, h) when h < 0.5, do: none()

  defp bar(color, w, h),
    do: el([width(px(w)), height(px(h)), Background.color(Theme.color(color))], none())

  # -- Numbers --

  defp kwh(nil), do: "—"
  defp kwh(value), do: "#{:erlang.float_to_binary(value * 1.0, decimals: 1)} KWH"

  defp volume(nil), do: "—"
  defp volume(v) when v >= 100, do: Integer.to_string(round(v))
  defp volume(v), do: :erlang.float_to_binary(v * 1.0, decimals: 1)

  defp money(value), do: :erlang.float_to_binary(value * 1.0, decimals: 2)

  defp percent(value), do: "#{round(value * 100)}%"
end
