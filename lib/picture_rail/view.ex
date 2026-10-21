defmodule PictureRail.View do
  @moduledoc """
  The Emerge viewport.

  Layout (the arrangement the Emerge spike found reliable for touch): a
  black root with one rotated, stable (unkeyed) container in front of it.
  The container holds the photo layer, and the panel in front of that as a
  `Nearby.in_front` overlay, so the panel isn't re-mounted when a new
  photo fades in.

  The container is turned by the `:orientation` controller's rotation.
  Emerge rotates it during layout, so hit testing follows: for portrait
  the box is authored at the screen's height x width and turned 90 or 270
  degrees, which is why the viewport needs the screen size: from the
  hardware module (`screen_size/0`, DRM sends no resize event) or else from
  `:resize` events (a desktop window).

  The panel (`PictureRail.View.Panel`) sends its presses here. A pill's press
  is a tap unless the touch that made it was held for
  `panel.long_press_ms` (settings) without moving: Emerge has no
  long-press event, and pairing `on_mouse_down` with `on_press` on one
  element can lose the press, so holds are timed from the raw `:touch`
  events, which arrive before the press. Any touch while the panel is up
  restarts its idle timeout. Slider drags are sent to Home Assistant at
  most every 250 ms; the value under the finger is held here until it is
  sent, then by the `:ha` controller as an optimistic attribute until Home
  Assistant reports it. Page flips go to the `:panel` controller.

  Start options: `spike: true` shows the rotation test card instead of the
  normal UI (plan task 2.3); `stats: true` logs Emerge's frame statistics.
  """
  use Emerge
  use Solve.Lookup

  require Logger

  alias PictureRail.{App, Network}
  alias PictureRail.View.{Config, Panel, SetupPage, Status}
  alias PictureRail.Web.Pairing

  @slider_send_ms 250
  # how far a held finger may drift and still count as a long press
  @hold_slop_px 30

  @doc """
  Start the viewport (under `PictureRail.View.Supervisor`) by hand, over SSH,
  while it isn't started at boot.
  """
  @spec start(keyword()) :: Supervisor.on_start_child()
  def start(opts \\ []) do
    Supervisor.start_child(PictureRail.Supervisor, PictureRail.View.Supervisor.root_child(opts))
  end

  @doc "Stop a viewport started with `start/1`."
  @spec stop() :: :ok | {:error, :not_found}
  def stop, do: Supervisor.terminate_child(PictureRail.Supervisor, PictureRail.View.Supervisor)

  @doc "The running viewport's pid, or `nil` (also while it's being stopped)."
  @spec whereis() :: pid() | nil
  def whereis do
    with pid when is_pid(pid) <- Process.whereis(PictureRail.View.Supervisor) do
      Enum.find_value(Supervisor.which_children(pid), fn
        {__MODULE__, child, _, _} when is_pid(child) -> child
        _ -> nil
      end)
    end
  catch
    # The supervisor stopped during the call (it gave up, or was stopped).
    :exit, _ -> nil
  end

  @first_boot_ms 3_000

  @impl Viewport
  def mount(opts) do
    config = Config.build()
    config = %{config | input: add_events(config.input, [:resize])}

    config =
      if Keyword.get(opts, :stats, false),
        do: %{config | diagnostics: %Emerge.Config.Diagnostics{logs: [:stats]}},
        else: config

    state = %{
      size: PictureRail.Hardware.impl().screen_size(),
      spike?: Keyword.get(opts, :spike, false),
      last_tap: nil,
      taps: 0,
      touches: %{},
      last_release: nil,
      # slider values under the finger, not yet sent
      sliders: %{},
      slider_timers: %{}
    }

    # a frame with nothing set up opens Wi-Fi setup by itself
    Process.send_after(self(), :first_boot, @first_boot_ms)
    {:ok, state, config}
  end

  defp add_events(input, extra) when is_list(input),
    do: Keyword.update(input, :events, extra, &Enum.uniq(&1 ++ extra))

  defp add_events(%Emerge.Config.Input{} = input, extra),
    do: %{input | events: Enum.uniq(input.events ++ extra)}

  @orientation_fade_ms 400

  @impl Viewport
  def render(state) do
    orientation = solve(App, :orientation)
    panel = solve(App, :panel)
    slideshow = solve(App, :slideshow)

    el(
      [
        width(fill()),
        height(fill()),
        Background.color(color(:black)),
        Font.family("Antonio"),
        Nearby.in_front(container(state, orientation, panel, slideshow))
      ],
      none()
    )
  end

  # The container stays mounted while photos change (only a turn of the
  # frame re-mounts it, fading in from black): it is rotated to the
  # orientation, holds the photo that is fading out as its background, the
  # photo layer inside and the panel in front.
  defp container(state, orientation, panel, slideshow) do
    # Under the (opaque) panel the photos aren't drawn at all: every frame
    # would paint them for nothing. They fade back in on close.
    panel_up? = panel_up?(state, panel)
    overlay = overlay(state, orientation, panel, panel_up?)
    previous = if panel_up?, do: [], else: previous_photo(slideshow)

    el(
      [
        key({:orientation, orientation && orientation.orientation}),
        Animation.animate_enter(
          [[Transform.alpha(0.0)], [Transform.alpha(1.0)]],
          @orientation_fade_ms,
          :ease_out
        )
      ] ++ rotation_attrs(state.size, orientation) ++ previous ++ overlay,
      if(panel_up?,
        do: el([width(fill()), height(fill()), Background.color(color(:black))], none()),
        else: photo_layer(state, panel, slideshow)
      )
    )
  end

  defp panel_up?(%{spike?: true}, _panel), do: false
  defp panel_up?(_state, %{visible?: true}), do: true
  defp panel_up?(_state, _panel), do: false

  defp overlay(%{spike?: true} = state, orientation, _panel, _up?),
    do: [Nearby.in_front(spike_card(state, orientation))]

  defp overlay(state, orientation, panel, true),
    do: [Nearby.in_front(panel(state, orientation, panel))]

  defp overlay(_state, _orientation, _panel, false), do: []

  defp previous_photo(%{previous: %{path: path}}),
    do: [Background.image({:path, path}, fit: :contain)]

  defp previous_photo(_slideshow), do: []

  defp rotation_attrs({w, h}, %{portrait?: true, rotation: degrees}),
    do: [width(px(h)), height(px(w)), center_x(), center_y(), rotate(degrees)]

  defp rotation_attrs(_size, %{rotation: degrees}) when degrees != 0,
    do: [width(fill()), height(fill()), rotate(degrees)]

  defp rotation_attrs(_size, _orientation), do: [width(fill()), height(fill())]

  # Each photo fades in on its own black, keyed layer (so nothing of the
  # previous photo shows in the letterbox bars). A tap anywhere shows the
  # panel.
  defp photo_layer(state, panel, slideshow) do
    tap = if panel && !state.spike?, do: [Event.on_press(event(panel, :show))], else: []

    case slideshow do
      %{current: %{path: path}, index: index, fade_ms: fade_ms} ->
        el(
          [
            key({:photo, index}),
            width(fill()),
            height(fill()),
            Background.color(color(:black)),
            Animation.animate_enter(
              [[Transform.alpha(0.0)], [Transform.alpha(1.0)]],
              fade_ms,
              :ease_in_out
            )
          ],
          el(
            [width(fill()), height(fill()), Background.image({:path, path}, fit: :contain)] ++ tap,
            none()
          )
        )

      _ ->
        el(
          [width(fill()), height(fill()), Background.color(color(:black))] ++ tap,
          status_block()
        )
    end
  end

  # Nothing to show yet: a small status readout in the corner.
  defp status_block do
    message = Status.message(solve(App, :settings), solve(App, :photos), solve(App, :network))

    el(
      [align_bottom(), align_left(), padding(48)],
      row([spacing(12)], [
        el(
          [
            width(px(24)),
            height(px(56)),
            Border.rounded(12),
            Background.color(color_rgb(0xFF, 0x99, 0x00))
          ],
          none()
        ),
        el(
          [
            center_y(),
            Font.size(40),
            Font.color(color_rgb(0xFF, 0x99, 0x00))
          ],
          text(String.upcase(message))
        )
      ])
    )
  end

  defp panel(state, orientation, panel) do
    {w, h} = state.size || {1920, 1080}
    portrait? = orientation && orientation.portrait?

    ctx = %{
      size: if(portrait?, do: {h, w}, else: {w, h}),
      portrait?: portrait? || false,
      panel: panel,
      ha: solve(App, :ha) || %{status: :unconfigured, slice: nil, states: %{}},
      setup: solve(App, :setup),
      settings: solve(App, :settings),
      photos: solve(App, :photos),
      network: solve(App, :network),
      pairing: solve(App, :pairing),
      sliders: state.sliders
    }

    # the keyboard takes the whole screen while a Setup field is edited
    if Panel.setup_view?(panel.view) and match?(%{editing: id} when id != nil, ctx.setup),
      do: SetupPage.editor(ctx),
      else: Panel.render(ctx)
  end

  # Rotation spike: a target in each corner and the last one tapped, to
  # check that touch lands where it's drawn in every orientation.
  defp spike_card(state, orientation) do
    el(
      [width(fill()), height(fill()), Font.color(color(:white))],
      column([width(fill()), height(fill())], [
        row([width(fill())], [
          corner(:top_left, [align_left()]),
          corner(:top_right, [align_right()])
        ]),
        el(
          [center_x(), center_y(), Font.size(48)],
          text(
            "#{orientation.orientation} (#{orientation.rotation}°)  last: #{inspect(state.last_tap)}  taps: #{state.taps}"
          )
        ),
        row([width(fill()), align_bottom()], [
          corner(:bottom_left, [align_left()]),
          corner(:bottom_right, [align_right()])
        ])
      ])
    )
  end

  defp corner(name, align) do
    Input.button(
      [
        Event.on_press({:spike_tap, name}),
        width(px(320)),
        height(px(200)),
        Background.color(color_rgb(0xFF, 0x99, 0x00)),
        Font.color(color(:black)),
        Font.size(36)
      ] ++ align,
      el([center_x(), center_y()], text(name |> Atom.to_string() |> String.upcase()))
    )
  end

  @impl Viewport
  def handle_input({:resize, {w, h, _scale}}, state) do
    {:noreply, Viewport.rerender(%{state | size: {round(w), round(h)}})}
  end

  def handle_input({:touch, {id, :down, pos}}, state) do
    if panel_visible?(), do: send_event(:panel, :activity, nil)
    touch = %{at: now(), pos: pos, moved: 0.0}
    {:noreply, %{state | touches: Map.put(state.touches, id, touch)}}
  end

  def handle_input({:touch, {id, :move, pos}}, state) do
    case state.touches do
      %{^id => touch} ->
        moved = Kernel.max(touch.moved, distance(touch.pos, pos))
        {:noreply, %{state | touches: Map.put(state.touches, id, %{touch | moved: moved})}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_input({:touch, {id, phase, _pos}}, state) when phase in [:up, :cancel] do
    {touch, touches} = Map.pop(state.touches, id)

    release =
      if touch && phase == :up,
        do: %{held_ms: now() - touch.at, moved: touch.moved, at: now()}

    {:noreply, %{state | touches: touches, last_release: release}}
  end

  def handle_input(_event, state), do: {:noreply, state}

  defp distance({x0, y0}, {x1, y1}), do: :math.sqrt((x1 - x0) ** 2 + (y1 - y0) ** 2)
  defp now, do: System.monotonic_time(:millisecond)

  defp panel_visible? do
    match?(%{visible?: true}, solve(App, :panel))
  end

  defp send_event(controller, event, payload) do
    Solve.dispatch(App, controller, event, payload)
  end

  # -- Panel messages --

  @impl Viewport
  def handle_info({:pill, entity_id}, state) do
    es = (solve(App, :ha) || %{states: %{}}).states[entity_id]

    cond do
      long_press?(state) ->
        send_event(:panel, :open, {:entity, entity_id})

      request = Panel.tap_action(entity_id, es) ->
        send_event(:panel, :activity, nil)
        send_event(:ha, :call, request)

      Panel.detail?(entity_id) ->
        send_event(:panel, :open, {:entity, entity_id})

      true ->
        send_event(:panel, :activity, nil)
    end

    {:noreply, %{state | last_release: nil}}
  end

  def handle_info({:page, page}, state) do
    send_event(:panel, :page, page)
    {:noreply, state}
  end

  def handle_info({:nav_page, page}, state) do
    send_event(:panel, :nav_page, page)
    {:noreply, state}
  end

  def handle_info({:device, device_id}, state) do
    send_event(:panel, :open, {:device, device_id})
    {:noreply, state}
  end

  def handle_info({:detail, entity_id}, state) do
    send_event(:panel, :open, {:entity, entity_id})
    {:noreply, state}
  end

  def handle_info({:goto, view}, state) do
    send_event(:panel, :goto, view)
    {:noreply, state}
  end

  def handle_info(message, state) when message in [:back, :hide] do
    send_event(:panel, message, nil)
    {:noreply, state}
  end

  # The Setup page's "Forget devices": every web page session ends.
  def handle_info(:forget_paired, state) do
    send_event(:panel, :activity, nil)
    if Process.whereis(Pairing), do: Pairing.forget()
    {:noreply, state}
  end

  # The Setup page: open a section, or an edit in the open one.
  def handle_info({:setup_open, section}, state) do
    send_event(:setup, :open, section)
    send_event(:panel, :open, {:setup, section})
    {:noreply, state}
  end

  # the native field's text (Emerge appends the value to the message)
  def handle_info({:setup, :typed, id, value}, state) do
    send_event(:panel, :activity, nil)
    send_event(:setup, :set, {id, value})
    {:noreply, state}
  end

  def handle_info({:setup, event, payload}, state) do
    send_event(:panel, :activity, nil)
    send_event(:setup, event, payload)
    {:noreply, state}
  end

  def handle_info({:call, request}, state) do
    send_event(:panel, :activity, nil)
    send_event(:ha, :call, request)
    {:noreply, state}
  end

  # A slider moved: show the value at once, send it at most every
  # @slider_send_ms.
  # (Emerge appends the value to a tuple message.)
  def handle_info({:slider, entity_id, kind, value}, state) do
    key = {entity_id, kind}
    send_event(:panel, :activity, nil)

    timers =
      if Map.has_key?(state.slider_timers, key),
        do: state.slider_timers,
        else:
          Map.put(
            state.slider_timers,
            key,
            Process.send_after(self(), {:slider_send, key}, @slider_send_ms)
          )

    state = %{state | sliders: Map.put(state.sliders, key, value), slider_timers: timers}
    {:noreply, Viewport.rerender(state)}
  end

  # Sent: from here on the `:ha` controller holds the value (optimistic
  # attributes) until Home Assistant reports it.
  def handle_info({:slider_send, {entity_id, kind} = key}, state) do
    {value, sliders} = Map.pop(state.sliders, key)
    if value, do: send_event(:ha, :call, slider_request(entity_id, kind, value))
    {:noreply, %{state | sliders: sliders, slider_timers: Map.delete(state.slider_timers, key)}}
  end

  def handle_info(:first_boot, state) do
    backend = Network.Backend.impl()

    with %{configured: configured} <- solve(App, :settings),
         true <-
           Network.first_boot?(
             backend.configured_networks?(),
             backend.ethernet_up?(),
             configured
           ) do
      Logger.info("View: nothing set up; opening Wi-Fi setup")
      send_event(:setup, :open, :wifi)
      send_event(:panel, :goto, {:setup, :wifi})
    end

    {:noreply, state}
  end

  def handle_info({:spike_tap, name}, state) do
    Logger.info("View: spike tap #{name}")
    {:noreply, Viewport.rerender(%{state | last_tap: name, taps: state.taps + 1})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp long_press?(%{last_release: %{held_ms: held, moved: moved}}) do
    held >= long_press_ms() and moved <= @hold_slop_px
  end

  defp long_press?(_state), do: false

  defp long_press_ms do
    case solve(App, :settings) do
      %{settings: %{panel: %{long_press_ms: ms}}} -> ms
      _ -> PictureRail.Settings.defaults().panel.long_press_ms
    end
  end

  @doc false
  @spec slider_request(String.t(), atom(), number()) :: map()
  def slider_request(id, :brightness, v) do
    %{
      domain: "light",
      service: "turn_on",
      entity_id: id,
      data: %{brightness_pct: round(v)},
      optimistic: "on",
      optimistic_attrs: %{"brightness" => round(v * 255 / 100)}
    }
  end

  def slider_request(id, :color_temp, v),
    do: %{
      domain: "light",
      service: "turn_on",
      entity_id: id,
      data: %{color_temp_kelvin: round(v)},
      optimistic_attrs: %{"color_temp_kelvin" => round(v)}
    }

  def slider_request(id, :position, v),
    do: %{
      domain: "cover",
      service: "set_cover_position",
      entity_id: id,
      data: %{position: round(v)},
      optimistic_attrs: %{"current_position" => round(v)}
    }

  def slider_request(id, :volume, v),
    do: %{
      domain: "media_player",
      service: "volume_set",
      entity_id: id,
      data: %{volume_level: v / 100},
      optimistic_attrs: %{"volume_level" => v / 100}
    }

  @impl Solve.Lookup
  def handle_solve_updated(_updated, state), do: {:ok, Viewport.rerender(state)}
end
