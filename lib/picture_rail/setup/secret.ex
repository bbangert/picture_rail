defmodule PictureRail.Setup.Secret do
  @moduledoc """
  A secret being typed on the Setup page (an API key, a token, a Wi-Fi
  password). `inspect/1` shows only its length, so it stays out of logs and
  crash reports while it sits in UI state.
  """
  defstruct value: ""

  @type t :: %__MODULE__{value: String.t()}

  defimpl Inspect do
    def inspect(%{value: value}, _opts),
      do: "#PictureRail.Setup.Secret<#{String.length(value)} chars>"
  end
end
