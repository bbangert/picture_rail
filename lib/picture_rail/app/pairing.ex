defmodule PictureRail.App.Pairing do
  @moduledoc """
  `:pairing` controller: the code the Setup page shows for pairing a phone
  with the settings web page (`PictureRail.Web.Pairing`), and whether the
  last "Forget devices" couldn't be saved. Exposes `%{code: code | nil,
  forget_failed?: boolean}`.
  """
  use Solve.Controller, events: [:code, :forgot]

  alias PictureRail.Web.Pairing

  @impl Solve.Controller
  # A restarted controller asks the pairing process again.
  def init(_params, _dependencies) do
    code = if Process.whereis(Pairing), do: Pairing.code()
    %{code: code, forget_failed?: false}
  end

  def code(code, state), do: %{state | code: code}

  @doc "What `PictureRail.Web.Pairing.forget/1` returned."
  def forgot(result, state), do: %{state | forget_failed?: result != :ok}
end
