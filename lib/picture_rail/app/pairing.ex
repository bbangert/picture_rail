defmodule PictureRail.App.Pairing do
  @moduledoc """
  `:pairing` controller: the code the Setup page shows for pairing a phone
  with the settings web page (`PictureRail.Web.Pairing`), the QR code of
  its pairing link, the page's address by name, and "Forget devices"
  (`:forget`, through the `:forget` callback: `PictureRail.Web.Pairing.forget/1`),
  with whether that couldn't be saved.

  Exposes `%{code: code | nil, qr: runs | nil, address: url,
  forget_failed?: boolean}`. `qr` (`PictureRail.QR.encode/1` of
  `PictureRail.Web.pair_url/2`) is there while there's a code and the
  frame is connected (`:network` has its IP); it's encoded once per link,
  not on every render or network report.
  """
  use Solve.Controller, events: [:code, :forget]

  alias PictureRail.{QR, Web}
  alias PictureRail.Web.Pairing

  @impl Solve.Controller
  # A restarted controller asks the pairing process again.
  def init(_params, _dependencies) do
    code = if Process.whereis(Pairing), do: Pairing.code()
    # the hostname doesn't change while running
    %{code: code, forget_failed?: false, address: Web.local_url()}
  end

  def code(code, state), do: %{state | code: code}

  def forget(_payload, state, _deps, %{forget: forget}),
    do: %{state | forget_failed?: forget.() != :ok}

  @impl Solve.Controller
  def expose(state, deps, _params) do
    %{
      code: state.code,
      qr: qr(state.code, deps),
      address: state.address,
      forget_failed?: state.forget_failed?
    }
  end

  defp qr(code, %{network: %{status: :connected, ip: ip}})
       when is_binary(code) and is_binary(ip),
       do: memo_encode(Web.pair_url(ip, code))

  defp qr(_code, _deps), do: nil

  # The last link's code, kept in this process: expose runs on every
  # network report, and encoding is pure Elixir.
  defp memo_encode(url) do
    case Process.get(__MODULE__) do
      {^url, runs} ->
        runs

      _ ->
        runs = QR.encode(url)
        Process.put(__MODULE__, {url, runs})
        runs
    end
  end
end
