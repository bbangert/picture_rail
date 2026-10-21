defmodule PictureRail.Web.Page do
  @moduledoc """
  The settings web page's HTML: the pairing form, the list of sections,
  and a section's form (from `PictureRail.Web.Form.inputs/5`). Plain
  server-rendered pages, no JavaScript.

  Templates escape everything they print with `h/1`; nothing is printed
  without it except the output of another template here.
  """
  require EEx

  alias PictureRail.Setup
  alias PictureRail.Web.Form

  @doc "Escape text for HTML (content and attribute values)."
  @spec h(term()) :: String.t()
  def h(nil), do: ""
  def h(value), do: value |> to_string() |> Plug.HTML.html_escape()

  @doc """
  The pairing form. `error` is `nil`, `:wrong` or `:locked`; `code` fills
  it in (from the frame's QR code).
  """
  @spec pair(String.t(), :wrong | :locked | nil, String.t() | nil) :: String.t()
  def pair(csrf, error, code \\ nil), do: layout("Pair", pair_body(csrf, error, code))

  @doc "The sections, with the log-out button."
  @spec index(String.t()) :: String.t()
  def index(csrf) do
    sections = for s <- Form.sections(), do: {Form.slug(s), Setup.label(s)}
    layout("Settings", index_body(csrf, sections))
  end

  @doc """
  A section's form. `assigns`: `:section`, `:inputs`, `:types` (`[{type,
  label}]`, more than one shows a picker), `:type`, `:message` (`{:ok |
  :error, text}` or `nil`).
  """
  @spec section(String.t(), map()) :: String.t()
  def section(csrf, assigns) do
    title = Setup.label(assigns.section)
    layout(title, section_body(csrf, Map.put(assigns, :title, title)))
  end

  @doc "A plain page with a message (not found, and the like)."
  @spec message(String.t(), String.t()) :: String.t()
  def message(title, text), do: layout(title, message_body(title, text))

  # -- Inputs --

  defp input(%{field: %{type: :toggle}} = i) do
    checked = if i.value == true, do: " checked", else: ""

    ~s{<label class="toggle"><input type="checkbox" name="#{name(i.id)}" value="true"#{checked}> #{h(i.field.label)}</label>} <>
      shown(i.id)
  end

  defp input(%{field: %{type: {:choices, _}}} = i) do
    case i.choices do
      {:ok, []} ->
        ~s{<p class="note">Nothing to choose from.</p>}

      {:ok, list} ->
        boxes = Enum.map_join(list, &choice(i, &1))
        ~s{<div class="choices">#{boxes}</div>} <> shown(i.id)

      {:error, text} ->
        ~s{<p class="note">#{h(text)}</p>}
    end
  end

  defp input(%{field: %{type: :secret}} = i) do
    placeholder = if i.set?, do: "Set. Leave empty to keep it", else: "Not set"

    ~s{<input type="password" id="#{dom_id(i.id)}" name="#{name(i.id)}" placeholder="#{placeholder}" autocomplete="off" autocapitalize="none" spellcheck="false" maxlength="#{max_length(i.field)}">} <>
      shown(i.id)
  end

  defp input(%{field: %{type: type} = f} = i) when type in [:integer, :seconds] do
    # the field's step is the frame's button increment, not a constraint:
    # a browser would refuse values off it (25 with min 1, step 5)
    {min, max, step, unit} =
      if type == :seconds,
        do: {seconds(f.min), seconds(f.max), "any", " s"},
        else: {f.min, f.max, 1, ""}

    attrs = for {k, v} <- [min: min, max: max, step: step], v != nil, do: ~s{ #{k}="#{h(v)}"}

    ~s{<span class="number"><input type="number" inputmode="decimal" id="#{dom_id(i.id)}" name="#{name(i.id)}" value="#{h(i.value)}"#{Enum.join(attrs)}>#{unit}</span>} <>
      shown(i.id)
  end

  defp input(%{field: f} = i) do
    type = if f.type == :url, do: "url", else: "text"

    ~s{<input type="#{type}" id="#{dom_id(i.id)}" name="#{name(i.id)}" value="#{h(i.value)}" autocapitalize="none" autocorrect="off" spellcheck="false" maxlength="#{max_length(f)}">} <>
      shown(i.id)
  end

  defp choice(i, {value, label}) do
    checked = if value in i.value, do: " checked", else: ""

    ~s{<label class="choice"><input type="checkbox" name="#{name(i.id)}[]" value="#{h(value)}"#{checked}> #{h(label)}</label>}
  end

  defp seconds(nil), do: nil
  defp seconds(ms), do: Form.seconds(ms)

  defp max_length(field), do: Setup.Field.max_length(field)
  defp name({section, key}), do: "f[#{h(section)}][#{h(key)}]"
  defp dom_id({section, key}), do: h("f-#{section}-#{key}")
  defp shown(id), do: ~s{<input type="hidden" name="shown[]" value="#{h(Form.shown_id(id))}">}

  defp labelled?(%{field: %{type: type}}), do: type not in [:toggle, {:choices, :multi}]

  # -- Templates --

  EEx.function_from_string(
    :defp,
    :layout,
    ~S"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="referrer" content="no-referrer">
    <title><%= h(title) %> · Picture Rail</title>
    <style>
    :root { color-scheme: dark; --orange: #ff9900; --peach: #ff9966; --lilac: #cc99cc; --sky: #99ccff; --bluey: #8899ff; --red: #ff5555; }
    * { box-sizing: border-box; }
    body { margin: 0; background: #000; color: #fff; font: 17px/1.4 "Antonio", "Arial Narrow", system-ui, sans-serif; }
    header { display: flex; align-items: center; gap: 12px; padding: 16px; }
    header .cap { width: 36px; height: 36px; border-radius: 18px 0 0 18px; background: var(--orange); }
    header .bar { flex: 1; height: 10px; background: var(--orange); border-radius: 0 5px 5px 0; }
    header a { color: var(--orange); text-decoration: none; font-size: 24px; letter-spacing: 1px; text-transform: uppercase; }
    main { padding: 0 16px 48px; max-width: 640px; margin: 0 auto; }
    h1 { color: var(--peach); text-transform: uppercase; letter-spacing: 1px; font-weight: 600; }
    .field { margin: 0 0 22px; }
    .field > label { display: block; color: var(--peach); text-transform: uppercase; margin-bottom: 6px; }
    input[type=text], input[type=url], input[type=password], input[type=number] { width: 100%; padding: 12px 14px; font-size: 17px; color: #fff; background: #1a1a24; border: 2px solid var(--orange); border-radius: 12px; }
    .number { display: flex; align-items: center; gap: 8px; } .number input { width: 9em; }
    .help, .note { color: #bbb; font-size: 15px; margin: 6px 0 0; }
    .error { color: var(--red); margin: 6px 0 0; }
    .toggle, .choice { display: flex; align-items: center; gap: 10px; padding: 8px 0; }
    .toggle input, .choice input { width: 24px; height: 24px; accent-color: var(--orange); }
    .choices { max-height: 50vh; overflow: auto; border: 2px solid #333; border-radius: 12px; padding: 4px 12px; }
    .buttons { display: flex; flex-wrap: wrap; gap: 12px; margin-top: 28px; }
    button, .pill { min-width: 9em; padding: 14px 24px; border: 0; border-radius: 999px; font: inherit; font-size: 18px; text-transform: uppercase; letter-spacing: 1px; color: #000; background: var(--orange); text-align: right; text-decoration: none; display: inline-block; }
    button.second { background: var(--lilac); }
    .pill.back { background: var(--bluey); }
    .pills { display: flex; flex-direction: column; gap: 12px; }
    .pills .pill { background: var(--sky); text-align: left; }
    .message { padding: 12px 16px; border-radius: 12px; background: #1a1a24; }
    .message.ok { color: var(--sky); } .message.error { color: var(--red); }
    .code { width: 9em; font-size: 28px; letter-spacing: 6px; text-align: center; }
    </style>
    </head>
    <body>
    <header><span class="cap"></span><a href="/">Picture Rail</a><span class="bar"></span></header>
    <main>
    <%= body %>
    </main>
    </body>
    </html>
    """,
    [:title, :body]
  )

  EEx.function_from_string(
    :defp,
    :pair_body,
    ~S"""
    <h1>Pair this device</h1>
    <%= if code do %><p>Tap <b>Pair</b> to pair this device with the frame.</p><% else %><p>Open <b>Setup</b> on the frame and enter the code it shows under “Settings on your phone”, or scan its QR code.</p><% end %>
    <%= if error == :wrong do %><p class="error">That code isn't right. Check the frame; the code changes after five wrong tries.</p><% end %>
    <%= if error == :locked do %><p class="error">Too many wrong codes. Wait a while, or tap Forget devices on the frame, then try the code it shows.</p><% end %>
    <form method="post" action="/pair">
    <input type="hidden" name="_csrf_token" value="<%= h(csrf) %>">
    <div class="field"><label for="code">Code</label>
    <input class="code" type="text" id="code" name="code" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9 ]*" maxlength="9"<%= if code do %> value="<%= h(code) %>"<% else %> autofocus<% end %>></div>
    <div class="buttons"><button type="submit"<%= if code, do: " autofocus" %>>Pair</button></div>
    </form>
    """,
    [:csrf, :error, :code]
  )

  EEx.function_from_string(
    :defp,
    :index_body,
    ~S"""
    <h1>Settings</h1>
    <div class="pills">
    <%= for {slug, label} <- sections do %><a class="pill" href="/settings/<%= h(slug) %>"><%= h(label) %></a>
    <% end %></div>
    <p class="note">Wi-Fi is set on the frame itself.</p>
    <form method="post" action="/logout">
    <input type="hidden" name="_csrf_token" value="<%= h(csrf) %>">
    <div class="buttons"><button class="second" type="submit">Log out</button></div>
    </form>
    """,
    [:csrf, :sections]
  )

  EEx.function_from_string(
    :defp,
    :section_body,
    ~S"""
    <h1><%= h(a.title) %></h1>
    <%= case a.message do %><% {kind, text} -> %><p class="message <%= h(kind) %>"><%= h(text) %></p><% nil -> %><% end %>
    <form method="post" action="/settings/<%= h(Form.slug(a.section)) %>">
    <input type="hidden" name="_csrf_token" value="<%= h(csrf) %>">
    <%= if length(a.types) > 1 do %><div class="field"><label for="type">Source</label>
    <select id="type" name="type"><%= for {type, label} <- a.types do %><option value="<%= h(type) %>"<%= if type == a.type, do: " selected" %>><%= h(label) %></option><% end %></select>
    <p class="help">Changing it starts that source afresh when you save.</p></div>
    <% else %><input type="hidden" name="type" value="<%= h(a.type) %>"><% end %>
    <%= for i <- a.inputs do %><div class="field">
    <%= if labelled?(i) do %><label for="<%= dom_id(i.id) %>"><%= h(i.field.label) %></label><% end %>
    <%= if i.field.type == {:choices, :multi} do %><label><%= h(i.field.label) %></label><% end %>
    <%= input(i) %>
    <%= if i.field.help do %><p class="help"><%= h(i.field.help) %></p><% end %>
    <%= if i.error do %><p class="error"><%= h(i.error) %></p><% end %>
    </div>
    <% end %>
    <div class="buttons">
    <button type="submit" name="action" value="save">Save</button>
    <%= if a.section == :photo_source do %><button class="second" type="submit" name="action" value="test">Test</button><% end %>
    <a class="pill back" href="/">Back</a>
    </div>
    </form>
    """,
    [:csrf, :a]
  )

  EEx.function_from_string(
    :defp,
    :message_body,
    ~S"""
    <h1><%= h(title) %></h1>
    <p><%= h(text) %></p>
    <p><a class="pill" href="/">Back</a></p>
    """,
    [:title, :text]
  )
end
