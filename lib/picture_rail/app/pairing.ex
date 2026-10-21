defmodule PictureRail.App.Pairing do
  @moduledoc """
  `:pairing` controller: the code the Setup page shows for pairing a phone
  with the settings web page (`PictureRail.Web.Pairing`). Exposes
  `%{code: code | nil}`.
  """
  use Solve.Controller, events: [:code]

  alias PictureRail.Web.Pairing

  @impl Solve.Controller
  # A restarted controller asks the pairing process again.
  def init(_params, _dependencies) do
    if Process.whereis(Pairing), do: %{code: Pairing.code()}, else: %{code: nil}
  end

  def code(code, state), do: %{state | code: code}
end
