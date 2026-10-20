defmodule HomeFrame.Hardware do
  @moduledoc """
  What differs between the devices HomeFrame runs on.

  Each supported device has a module implementing this behaviour, chosen
  with `config :homeframe, hardware: Module` in the target's config file
  (`config/<target>.exs`). `HomeFrame.Hardware.Host` is used for
  development on a laptop.

  A hardware module that can sense its orientation reports it with
  `HomeFrame.Orientation.report/1`; one that can't simply doesn't, and the
  UI stays in its configured default orientation.
  """

  @doc """
  Processes the device needs (sensors, boot-time tweaks), started before
  the rest of the app.
  """
  @callback children() :: [Supervisor.child_spec() | {module(), term()} | module()]

  @doc """
  Emerge settings for this device's screen: `:output`, `:renderer` and
  `:input` fields of `Emerge.Config`. Fields left out keep Emerge's
  defaults.
  """
  @callback emerge_config() :: keyword()

  @doc """
  The screen's size in pixels, `{width, height}`, or `nil` to learn it from
  Emerge's `:resize` events (a desktop window). DRM output sends no resize
  event, and a portrait UI needs the size to lay itself out.
  """
  @callback screen_size() :: {pos_integer(), pos_integer()} | nil

  @doc """
  Which way up the display is now, from the device's sensor, or `:unknown`
  (no sensor, or no reading yet). The UI starts from this, since sensors
  report only changes.
  """
  @callback orientation() :: HomeFrame.Orientation.reading() | :unknown

  @doc """
  The mode of the first connected connector on a DRM card, read from
  sysfs (`/sys/class/drm/<card>-*/modes`), or `nil`.
  """
  @spec drm_screen_size(String.t(), Path.t()) :: {pos_integer(), pos_integer()} | nil
  def drm_screen_size(card \\ "card0", sysfs \\ "/sys/class/drm") do
    Path.join(sysfs, "#{card}-*")
    |> Path.wildcard()
    |> Enum.find_value(fn connector ->
      with {:ok, "connected" <> _} <- File.read(Path.join(connector, "status")),
           {:ok, modes} <- File.read(Path.join(connector, "modes")),
           [mode | _] <- String.split(modes, "\n", trim: true),
           [w, h] <- String.split(mode, "x"),
           {w, ""} <- Integer.parse(w),
           {h, _} <- Integer.parse(h) do
        {w, h}
      else
        _ -> nil
      end
    end)
  end

  @doc "The configured hardware module."
  @spec impl() :: module()
  def impl, do: Application.get_env(:homeframe, :hardware, HomeFrame.Hardware.Host)
end
