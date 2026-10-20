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

  @doc "The configured hardware module."
  @spec impl() :: module()
  def impl, do: Application.get_env(:homeframe, :hardware, HomeFrame.Hardware.Host)
end
