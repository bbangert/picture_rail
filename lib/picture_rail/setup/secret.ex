defmodule PictureRail.Setup.Secret do
  @moduledoc """
  A secret being typed on the Setup page (an API key, a token, a Wi-Fi
  password), or anything holding secrets on its way to a process (a call
  message is in the caller's exit reason on a timeout, and in a crash
  report). `inspect/1` shows only a string's length, so it stays out of
  logs and crash reports.
  """
  defstruct value: ""

  @type t :: %__MODULE__{value: term()}

  defimpl Inspect do
    def inspect(%{value: value}, _opts) when is_binary(value),
      do: "#PictureRail.Setup.Secret<#{String.length(value)} chars>"

    def inspect(_secret, _opts), do: "#PictureRail.Setup.Secret<redacted>"
  end
end
