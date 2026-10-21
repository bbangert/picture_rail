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

  alias PictureRail.{PhotoSource, Setup}
  alias PictureRail.Setup.{Field, Secret}
  alias PictureRail.View.{LCARS, Theme}

  @colors %{photo_source: :sky, home_assistant: :lilac, display: :peach}
  @row_h 84
  @error_h 30
  @choice_h 72

  # -- What to show --

  @doc """
  The overview line for a section: what it's set to, or "Not set up".
  `settings` is the `:settings` controller's exposed map.
  """
  @spec section_summary(Setup.section(), map() | nil, map() | nil) :: String.t()
  def section_summary(section, settings, photos \\ nil)

  def section_summary(:photo_source, %{settings: %{photo_source: %{} = source}}, photos) do
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

  def section_summary(:home_assistant, %{settings: %{home_assistant: %{"url" => url}}}, _photos),
    do: URI.parse(url).host || url

  def section_summary(:display, %{settings: %{slideshow: slideshow}}, _photos),
    do: "Every #{seconds(slideshow.interval_ms)} · fade #{seconds(slideshow.fade_ms)}"

  def section_summary(_section, _settings, _photos), do: "Not set up"

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

    rows =
      for section <- Setup.sections() do
        pill =
          LCARS.pill(
            label: String.upcase(Setup.label(section)),
            sub: section_summary(section, ctx.settings, ctx.photos),
            color: Theme.hex(@colors[section]),
            height: 96,
            attrs: [Event.on_press({:setup_open, section})]
          )

        {:row, 96, [pill], heading}
      end

    [heading | rows]
  end

  def blocks(ctx, {:setup, section}) do
    setup = ctx.setup

    if setup == nil or setup.section != section do
      # the editor opens with the view; until its state arrives
      [{:block, 80, message_element("Loading", :peach)}]
    else
      public = ctx.settings.settings
      color = Theme.hex(@colors[section])

      source_picker(ctx, setup, color) ++
        Enum.flat_map(field_rows(setup, public, ctx.photos), &field_blocks(ctx, &1, color)) ++
        footer(ctx, setup)
    end
  end

  # A row of the known sources, when there's more than one to choose from.
  defp source_picker(_ctx, %{section: :photo_source, draft: draft}, color) do
    case PhotoSource.sources() do
      [_only] ->
        []

      sources ->
        heading = {:heading, color, "Source"}
        current = Setup.source(draft)

        pills =
          for module <- sources do
            LCARS.pill(
              label: String.upcase(module.label()),
              fill: choice_fill(color, module == current),
              height: @choice_h,
              attrs: [Event.on_press({:setup, :set_type, module.type()})]
            )
          end

        [heading, {:row, @choice_h, pills, heading}]
    end
  end

  defp source_picker(_ctx, _setup, _color), do: []

  defp field_blocks(_ctx, {:toggle, id, label, on?, error}, color) do
    control =
      LCARS.pill(
        label: if(on?, do: "ON", else: "OFF"),
        fill: choice_fill(color, on?),
        height: 64,
        width: px(160),
        attrs: [Event.on_press({:setup, :toggle, id})]
      )

    [field_row_block(label, [control], error)]
  end

  defp field_blocks(_ctx, {:stepper, id, label, shown, down?, up?, error}, color) do
    controls = [
      step_pill("−", {:setup, :step, {id, -1}}, down?, color),
      el(
        [
          width(px(170)),
          center_y(),
          Font.size(Theme.size(:heading)),
          Font.color(Theme.color(:white))
        ],
        el([center_x()], text(shown))
      ),
      step_pill("+", {:setup, :step, {id, 1}}, up?, color)
    ]

    [field_row_block(label, controls, error)]
  end

  defp field_blocks(_ctx, {:text, _id, label, shown, _set?, error}, color) do
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

    # the keyboard that edits it comes with the next step of setup
    edit =
      LCARS.pill(label: "EDIT", fill: Theme.color(Theme.dim(color)), height: 64, width: px(140))

    [field_row_block(label, [value, edit], error)]
  end

  defp field_blocks(ctx, {:choices, id, label, choices, selected, error}, color) do
    heading = {:heading, color, label}

    rows =
      choices
      |> choice_pills(id, selected, color)
      |> Enum.chunk_every(Kernel.max(ctx.cols - 1, 1))
      |> Enum.map(&{:row, @choice_h, &1, heading})

    status =
      field_row_block(
        choices_status(choices, selected),
        [reload_pill(id, choices, color)],
        error,
        :sky
      )

    [heading] ++ rows ++ [status]
  end

  defp choice_pills({:ok, list}, id, selected, color) do
    for {value, label} <- list do
      LCARS.pill(
        label: LCARS.fit(label, 30),
        fill: choice_fill(color, value in selected),
        height: @choice_h,
        attrs: [Event.on_press({:setup, :toggle_choice, {id, value}})]
      )
    end
  end

  defp choice_pills(_choices, _id, _selected, _color), do: []

  defp choices_status(:loading, _selected), do: "Loading..."
  defp choices_status({:error, message}, _selected), do: message
  defp choices_status({:ok, []}, _selected), do: "Nothing to choose from"
  defp choices_status(_choices, selected), do: "#{length(selected)} selected"

  defp reload_pill(_id, :loading, color),
    do: LCARS.pill(label: "LOAD", fill: Theme.color(Theme.dim(color)), height: 64, width: px(160))

  defp reload_pill(id, choices, color) do
    LCARS.pill(
      label: if(match?({:ok, _}, choices), do: "RELOAD", else: "LOAD"),
      fill: Theme.color(color),
      height: 64,
      width: px(160),
      attrs: [Event.on_press({:setup, :load_choices, id})]
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
        width: px(180),
        attrs: if(setup.saving?, do: [], else: [Event.on_press({:setup, :save, nil})])
      )

    test =
      if setup.section == :photo_source do
        [
          LCARS.pill(
            label: if(setup.check == :running, do: "TESTING", else: "TEST"),
            color: Theme.hex(:bluey),
            height: 72,
            width: px(180),
            attrs: [Event.on_press({:setup, :test, nil})]
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
        width: px(180),
        attrs: [Event.on_press({:setup, :discard, nil})]
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

  defp step_pill(label, message, enabled?, color) do
    LCARS.pill(
      label: label,
      font: 40,
      fill: Theme.color(if(enabled?, do: color, else: Theme.dim(color))),
      height: 64,
      width: px(90),
      attrs: if(enabled?, do: [Event.on_press(message)], else: [])
    )
  end

  defp choice_fill(color, true), do: Theme.color(color)
  defp choice_fill(color, false), do: Theme.color(Theme.dim(color))

  defp message_element(message, color) do
    el(
      [padding_xy(12, 8), Font.size(Theme.size(:label)), Font.color(Theme.color(color))],
      text(message)
    )
  end
end
