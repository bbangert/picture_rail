defmodule HomeFrame.Paths do
  @moduledoc """
  Where HomeFrame keeps its settings and caches.

  Everything lives under the data directory (`config :homeframe,
  data_dir: ...`): `/root` on Nerves devices (the writable application
  partition), `tmp/data` in the project when running on the host.
  """

  @doc "The data directory."
  @spec data_dir() :: Path.t()
  def data_dir, do: Application.get_env(:homeframe, :data_dir, "/root")

  @doc "The settings file, edited over SSH."
  @spec settings_file() :: Path.t()
  def settings_file, do: Path.join(data_dir(), "homeframe.json")

  @doc "Downloaded photos and Live Photo clips."
  @spec photo_cache_dir() :: Path.t()
  def photo_cache_dir, do: Path.join([data_dir(), "cache", "photos"])
end
