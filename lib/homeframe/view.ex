defmodule HomeFrame.View do
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

  Start options: `spike: true` shows the rotation test card instead of the
  normal UI (plan task 2.3).
  """
  use Emerge
  use Solve.Lookup

  require Logger

  alias HomeFrame.App
  alias HomeFrame.View.Config

  @doc """
  Start the viewport under the app's supervisor (for starting it by hand
  over SSH while it isn't started at boot).
  """
  @spec start(keyword()) :: Supervisor.on_start_child()
  def start(opts \\ []) do
    Supervisor.start_child(HomeFrame.Supervisor, {__MODULE__, opts})
  end

  @doc "Stop a viewport started with `start/1`."
  @spec stop() :: :ok | {:error, :not_found}
  def stop do
    with :ok <- Supervisor.terminate_child(HomeFrame.Supervisor, __MODULE__) do
      Supervisor.delete_child(HomeFrame.Supervisor, __MODULE__)
    end
  end

  @impl Viewport
  def mount(opts) do
    config = Config.build()
    config = %{config | input: add_events(config.input, [:resize])}

    state = %{
      size: HomeFrame.Hardware.impl().screen_size(),
      spike?: Keyword.get(opts, :spike, false),
      last_tap: nil,
      taps: 0
    }

    {:ok, state, config}
  end

  defp add_events(input, extra) when is_list(input),
    do: Keyword.update(input, :events, extra, &Enum.uniq(&1 ++ extra))

  defp add_events(%Emerge.Config.Input{} = input, extra),
    do: %{input | events: Enum.uniq(input.events ++ extra)}

  @impl Viewport
  def render(state) do
    orientation = solve(App, :orientation)
    panel = solve(App, :panel)

    el(
      [
        width(fill()),
        height(fill()),
        Background.color(color(:black)),
        Font.family("Antonio"),
        Nearby.in_front(container(state, orientation, panel))
      ],
      none()
    )
  end

  # The stable container: rotated to the orientation, photos inside, the
  # panel in front.
  defp container(state, orientation, panel) do
    overlay =
      cond do
        state.spike? -> [Nearby.in_front(spike_card(state, orientation))]
        panel && panel.visible? -> [Nearby.in_front(panel_placeholder(panel))]
        true -> []
      end

    el(
      rotation_attrs(state.size, orientation) ++ overlay,
      photo_layer(state, panel)
    )
  end

  defp rotation_attrs({w, h}, %{portrait?: true, rotation: degrees}),
    do: [width(px(h)), height(px(w)), center_x(), center_y(), rotate(degrees)]

  defp rotation_attrs(_size, %{rotation: degrees}) when degrees != 0,
    do: [width(fill()), height(fill()), rotate(degrees)]

  defp rotation_attrs(_size, _orientation), do: [width(fill()), height(fill())]

  defp photo_layer(state, panel) do
    photo =
      case sample_photo() do
        nil -> []
        path -> [Background.image({:path, path}, fit: :contain)]
      end

    tap = if panel && !state.spike?, do: [Event.on_press(event(panel, :show))], else: []

    el([width(fill()), height(fill()), Background.color(color(:black))] ++ photo ++ tap, none())
  end

  # Until the slideshow exists (phase 5): the first cached photo, if any.
  defp sample_photo do
    HomeFrame.Paths.photo_cache_dir() |> Path.join("*.jpg") |> Path.wildcard() |> List.first()
  end

  defp panel_placeholder(panel) do
    el(
      [
        width(fill()),
        height(fill()),
        padding(48),
        Background.color(color(:black)),
        Font.color(color_rgb(0xFF, 0x99, 0x00)),
        Event.on_press(event(panel, :activity))
      ],
      column([spacing(24)], [
        el([Font.size(64), Font.weight(700)], text("HOME")),
        el([Font.size(32)], text("Panel coming in phase 7. View: #{inspect(panel.view)}")),
        Input.button(
          [
            Event.on_press(event(panel, :hide)),
            padding(24),
            Border.rounded(36),
            Background.color(color_rgb(0xFF, 0x99, 0x00)),
            Font.color(color(:black)),
            Font.size(32)
          ],
          text("CLOSE")
        )
      ])
    )
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

  def handle_input(_event, state), do: {:noreply, state}

  @impl Viewport
  def handle_info({:spike_tap, name}, state) do
    Logger.info("View: spike tap #{name}")
    {:noreply, Viewport.rerender(%{state | last_tap: name, taps: state.taps + 1})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl Solve.Lookup
  def handle_solve_updated(_updated, state), do: {:ok, Viewport.rerender(state)}
end
