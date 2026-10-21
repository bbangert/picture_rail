defmodule PictureRail.App.Setup do
  @moduledoc """
  `:setup` controller: the Setup page's editor, one section at a time (see
  `PictureRail.Setup` for the sections and drafts).

  Events from the view:

    * `:open` - start editing a section, from what's saved (a section with
      choices to pick from loads them when its source is set up)
    * `:set` - `{id, value}`
    * `:toggle` - flip a `:toggle` field (`id`)
    * `:step` - `{id, 1 | -1}`: an `:integer` or `:seconds` field by a step
    * `:toggle_choice` - `{id, value}`: pick or unpick a choice
    * `:set_type` - switch the photo source's type (a fresh draft for it)
    * `:load_choices` - (re)load a choices field's choices (`id`)
    * `:test` - check the photo source with the draft
    * `:save` - write the draft (`PictureRail.Settings.Watcher.update/2`);
      validation errors land on their fields
    * `:discard` - back to what's saved
    * `:close` - stop editing
    * `:edit` - open the keyboard on a text field (`id`); a secret starts
      empty (the stored one is never shown) and is held as a
      `PictureRail.Setup.Secret`
    * `:kb` - a keyboard key that's the app's (`PictureRail.View.Keyboard`):
      shift, layers, `:done` (keep the typed value), `:cancel` (put back
      the value from before), and every key of a masked secret
    * `:reveal` - show the secret being typed in clear (a native field),
      or mask it again
    * `:wifi_pick` - a listed network (`PictureRail.Network.networks/1`)
      to join; `:wifi_other` - one typed in by hand; `:wifi_list` - back to
      the list
    * `:join` - join the Wi-Fi draft's network (the `:join` callback,
      `PictureRail.Network.join/3`); how it goes is the `:network`
      controller's

  Opening Wi-Fi asks for scans while it's open (the `:wifi_watch`
  callback).

  While the keyboard is open, `:set` from the native field is cut to the
  field's `PictureRail.Setup.Field.max_length/1` (the field re-renders
  with the shorter value) and ends a one-shot shift.

  Loading choices, the check and saving run in tasks (the `:run`
  callback), each tagged with its ref: a result for an editor that has
  since moved on is dropped. The stored credentials only ever enter those
  tasks (the `:stored` callback), never this state.

  Exposes `%{section:, draft:, errors:, message:, choices:, check:,
  saving?:, joining?:, busy?:, editing:, keyboard:, reveal?:, edits:}`: `editing` the
  id the keyboard is open on, `keyboard` its layer and shift, `edits`
  counts keyboard openings (the field is keyed on it, so it mounts
  focused); `errors` by field id, `message` `{:ok | :error,
  text}` for the section, `choices` by field id (`:idle`, `:loading`,
  `{:ok, [{value, label}]}`, `{:error, text}`), `check` `nil`, `:running`,
  `:ok` or `{:error, text}`. `busy?` (unsaved changes, or a task running)
  keeps the panel up longer.
  """
  use Solve.Controller,
    events: [
      :open,
      :set,
      :toggle,
      :step,
      :toggle_choice,
      :set_type,
      :load_choices,
      :test,
      :save,
      :discard,
      :close,
      :edit,
      :kb,
      :reveal,
      :wifi_pick,
      :wifi_other,
      :wifi_list,
      :join
    ]

  require Logger

  alias PictureRail.Setup
  alias PictureRail.Setup.{Field, Secret}
  alias PictureRail.View.Keyboard

  @impl Solve.Controller
  def init(_params, _dependencies), do: closed()

  defp closed do
    %{
      section: nil,
      draft: %{},
      errors: %{},
      message: nil,
      choices: %{},
      check: nil,
      pending: %{},
      editing: nil,
      before: nil,
      keyboard: Keyboard.new(),
      reveal?: false,
      edits: 0
    }
  end

  def open(section, _state, deps, callbacks) do
    state = editor(section, Setup.draft(section, public(deps)))

    cond do
      section == :photo_source and configured?(deps, :photo_source) ->
        load_all_choices(state, callbacks)

      section == :wifi ->
        callbacks.wifi_watch.()
        state

      true ->
        state
    end
  end

  def wifi_pick(network, %{section: :wifi}, _deps, callbacks) do
    callbacks.wifi_watch.()
    editor(:wifi, Setup.wifi_draft(network))
  end

  def wifi_pick(_network, state, _deps, _callbacks), do: state

  def wifi_other(_payload, %{section: :wifi}), do: editor(:wifi, Setup.wifi_draft(nil))
  def wifi_other(_payload, state), do: state

  def wifi_list(_payload, %{section: :wifi}, _deps, callbacks) do
    callbacks.wifi_watch.()
    editor(:wifi, Setup.draft(:wifi, %{}))
  end

  def wifi_list(_payload, state, _deps, _callbacks), do: state

  def join(_payload, %{section: :wifi} = state, _deps, callbacks) do
    case Setup.wifi_join(state.draft) do
      {:ok, {ssid, password, hidden?}} ->
        fun = fn -> callbacks.join.(ssid, password, hidden?) end
        %{run(state, :join, fun, callbacks) | errors: %{}, message: nil}

      {:error, errors} ->
        %{state | errors: errors, message: {:error, "Check the fields marked"}}
    end
  end

  def join(_payload, state, _deps, _callbacks), do: state

  defp editor(section, draft), do: %{closed() | section: section, draft: draft}

  def close(_payload, _state), do: closed()

  def discard(_payload, %{section: nil} = state, _deps), do: state

  def discard(_payload, state, deps),
    do: %{
      editor(state.section, Setup.draft(state.section, public(deps)))
      | choices: state.choices
    }

  def set({id, value}, %{editing: id} = state) when is_binary(value) do
    field = Setup.field(state.section, state.draft, id)
    value = String.slice(value, 0, Field.max_length(field))
    longer? = String.length(value) > String.length(text_of(state.draft[id]))
    value = if field.type == :secret, do: %Secret{value: value}, else: value
    state = change(state, id, fn _old -> value end)
    if longer?, do: %{state | keyboard: Keyboard.typed(state.keyboard)}, else: state
  end

  def set({id, value}, state), do: change(state, id, fn _old -> value end)
  def toggle(id, state), do: change(state, id, &(!&1))

  def step({id, direction}, state) when direction in [1, -1] do
    case Setup.field(state.section, state.draft, id) do
      %Field{type: type} = field when type in [:integer, :seconds] ->
        change(state, id, &Setup.step(field, &1, direction))

      _ ->
        state
    end
  end

  def toggle_choice({id, choice}, state), do: change(state, id, &Setup.toggle_choice(&1, choice))

  def edit(id, %{section: section} = state) when section != nil do
    case Setup.field(section, state.draft, id) do
      %Field{type: type} when type in [:text, :url, :secret] ->
        before = Map.fetch(state.draft, id)

        draft =
          if type == :secret and not is_struct(state.draft[id], Secret),
            do: Map.put(state.draft, id, %Secret{}),
            else: state.draft

        %{
          state
          | draft: draft,
            editing: id,
            before: before,
            keyboard: Keyboard.new(),
            reveal?: false,
            edits: state.edits + 1
        }

      _ ->
        state
    end
  end

  def edit(_id, state), do: state

  def kb(_key, %{editing: nil} = state), do: state

  def kb(:shift, state),
    do: %{state | keyboard: Keyboard.press_shift(state.keyboard, now())}

  def kb({:layer, layer}, state), do: %{state | keyboard: Keyboard.layer(state.keyboard, layer)}

  def kb(:reveal, state), do: reveal(nil, state)

  def kb(:done, state), do: %{state | editing: nil, before: nil, reveal?: false}

  def kb(:cancel, %{editing: id} = state) do
    draft =
      case state.before do
        {:ok, value} -> Map.put(state.draft, id, value)
        :error -> Map.delete(state.draft, id)
      end

    %{state | draft: draft, editing: nil, before: nil, reveal?: false}
  end

  # a masked secret's keys
  def kb(key, %{editing: id, reveal?: false} = state) do
    case Setup.field(state.section, state.draft, id) do
      %Field{type: :secret} = field ->
        value = Keyboard.edit(text_of(state.draft[id]), key, Field.max_length(field))
        state = change(state, id, fn _old -> %Secret{value: value} end)
        typed? = match?({:char, _}, key) or key == :space
        if typed?, do: %{state | keyboard: Keyboard.typed(state.keyboard)}, else: state

      _ ->
        state
    end
  end

  def kb(_key, state), do: state

  def reveal(_payload, %{editing: id} = state) when id != nil,
    do: %{state | reveal?: not state.reveal?, edits: state.edits + 1}

  def reveal(_payload, state), do: state

  defp text_of(%Secret{value: value}), do: value
  defp text_of(value) when is_binary(value), do: value
  defp text_of(_value), do: ""

  defp now, do: System.monotonic_time(:millisecond)

  def set_type(type, %{section: :photo_source}, _deps, callbacks) do
    state = editor(:photo_source, Setup.draft(:photo_source, %{photo_source: %{"type" => type}}))
    load_all_choices(state, callbacks)
  end

  def set_type(_type, state, _deps, _callbacks), do: state

  def load_choices(id, %{section: section} = state, _deps, callbacks) when section != nil,
    do: start_choices(state, id, callbacks)

  def load_choices(_id, state, _deps, _callbacks), do: state

  def test(_payload, %{section: :photo_source} = state, _deps, callbacks) do
    case Setup.source(state.draft) do
      nil ->
        state

      module ->
        draft = state.draft

        fun = fn ->
          module.check(Setup.source_config(draft, callbacks.stored.("photo_source")))
        end

        %{run(state, :check, fun, callbacks) | check: :running}
    end
  end

  def test(_payload, state, _deps, _callbacks), do: state

  def save(_payload, %{section: nil} = state, _deps, _callbacks), do: state

  def save(_payload, state, _deps, callbacks) do
    values = Setup.values(state.section, state.draft)
    %{run(state, :save, fn -> callbacks.save.(values) end, callbacks) | message: nil}
  end

  def handle_info(message, state), do: task_reply(message, state)

  @doc false
  # A task's reply (or its crash); anything else is ignored.
  @spec task_reply(term(), map()) :: map()
  def task_reply({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case Map.pop(state.pending, ref) do
      {nil, _pending} -> state
      {job, pending} -> done(job, result, %{state | pending: pending})
    end
  end

  def task_reply({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.pending, ref) do
      {nil, _pending} ->
        state

      {job, pending} ->
        Logger.warning("Setup: #{inspect(job)} crashed: #{inspect(reason)}")
        done(job, {:error, "Something went wrong"}, %{state | pending: pending})
    end
  end

  def task_reply(_message, state), do: state

  # -- Edits --

  defp change(%{section: nil} = state, _id, _fun), do: state

  defp change(state, id, fun) do
    if Setup.field(state.section, state.draft, id) do
      draft = Map.update(state.draft, id, fun.(nil), fun)
      %{state | draft: draft, errors: Map.delete(state.errors, id), message: nil}
    else
      state
    end
  end

  # -- Tasks --

  defp load_all_choices(state, callbacks) do
    for {name, %Field{type: {:choices, _}} = f} <- Setup.fields(state.section, state.draft),
        reduce: state do
      state -> start_choices(state, {name, f.key}, callbacks)
    end
  end

  defp start_choices(%{section: :photo_source} = state, {_, key} = id, callbacks) do
    case Setup.source(state.draft) do
      nil ->
        state

      module ->
        draft = state.draft

        fun = fn ->
          module.choices(key, Setup.source_config(draft, callbacks.stored.("photo_source")))
        end

        state = run(state, {:choices, id}, fun, callbacks)
        %{state | choices: Map.put(state.choices, id, :loading)}
    end
  end

  defp start_choices(state, _id, _callbacks), do: state

  defp run(state, job, fun, callbacks) do
    %{ref: ref} = callbacks.run.(fun)
    # one of each job at a time: a newer one supersedes
    pending = state.pending |> Enum.reject(fn {_ref, j} -> j == job end) |> Map.new()
    %{state | pending: Map.put(pending, ref, job)}
  end

  defp done({:choices, id}, result, state) do
    choices =
      case result do
        {:ok, list} when is_list(list) -> {:ok, list}
        {:error, message} when is_binary(message) -> {:error, message}
        other -> {:error, "Unexpected: #{inspect(other)}"}
      end

    %{state | choices: Map.put(state.choices, id, choices)}
  end

  defp done(:check, result, state) do
    case result do
      :ok -> %{state | check: :ok}
      {:error, message} when is_binary(message) -> %{state | check: {:error, message}}
      other -> %{state | check: {:error, "Unexpected: #{inspect(other)}"}}
    end
  end

  defp done(:save, :ok, state) do
    # typed secrets are saved: they show as set from here on
    draft = Map.reject(state.draft, fn {_id, value} -> is_struct(value, Setup.Secret) end)
    %{state | draft: draft, errors: %{}, message: {:ok, "Saved"}}
  end

  defp done(:save, {:error, messages}, state) when is_list(messages) do
    {errors, rest} = Setup.field_errors(state.section, state.draft, messages)

    message =
      case rest do
        [] -> "Check the fields marked"
        rest -> Enum.join(rest, "; ")
      end

    %{state | errors: errors, message: {:error, message}}
  end

  # The network is on trial: the `:network` controller tells how it goes.
  # The typed password isn't needed any more.
  defp done(:join, :ok, state), do: %{state | draft: Setup.draft(:wifi, %{})}

  defp done(:join, {:error, message}, state),
    do: %{state | message: {:error, to_string(message)}}

  defp done(:save, {:error, message}, state),
    do: %{state | message: {:error, to_string(message)}}

  # -- Exposed --

  defp public(%{settings: %{settings: public}}), do: public
  defp public(_deps), do: PictureRail.Settings.public(PictureRail.Settings.defaults())

  defp configured?(%{settings: %{configured: configured}}, key),
    do: Map.get(configured, key, false)

  defp configured?(_deps, _key), do: false

  # Joining, or not connected yet: Wi-Fi setup stays up.
  defp wifi_busy?(%{section: :wifi}, %{network: network}),
    do: network.trial != nil or network.status != :connected

  defp wifi_busy?(_state, _deps), do: false

  @impl Solve.Controller
  def expose(state, deps, _params) do
    busy? =
      state.section != nil and
        (state.editing != nil or state.pending != %{} or wifi_busy?(state, deps) or
           state.draft != Setup.draft(state.section, public(deps)))

    %{
      section: state.section,
      draft: state.draft,
      errors: state.errors,
      message: state.message,
      choices: state.choices,
      check: state.check,
      saving?: :save in Map.values(state.pending),
      joining?: :join in Map.values(state.pending),
      busy?: busy?,
      editing: state.editing,
      keyboard: state.keyboard,
      reveal?: state.reveal?,
      edits: state.edits
    }
  end
end
