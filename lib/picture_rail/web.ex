defmodule PictureRail.Web do
  @moduledoc """
  The settings web page (`PictureRail.Web.Router`), served by Bandit on
  `config :picture_rail, web_port:` (80 on the frame, 4080 on a laptop),
  and pairing for it (`PictureRail.Web.Pairing`).

  Plain HTTP on the LAN: what's pasted crosses it unencrypted. HTTP/2 and
  WebSockets are off (the page needs neither, and Bandit 1.12.5's
  EEF-CVE-2026-105659 is in HTTP/2).
  """

  alias PictureRail.Web.{Pairing, Router}

  @doc "The children to start (none with `start_web: false`, as in tests)."
  @spec children() :: [Supervisor.child_spec() | module() | {module(), keyword()}]
  def children do
    if Application.get_env(:picture_rail, :start_web, true) do
      [
        Pairing,
        {Bandit,
         plug: Router,
         scheme: :http,
         port: port(),
         startup_log: false,
         http_2_options: [enabled: false],
         websocket_options: [enabled: false]}
      ]
    else
      []
    end
  end

  @doc "The port the page is served on."
  @spec port() :: :inet.port_number()
  def port, do: Application.get_env(:picture_rail, :web_port, 4080)

  @doc "The link in the frame's QR code: the page at `ip`, with the code."
  @spec pair_url(String.t(), String.t()) :: String.t()
  def pair_url(ip, code), do: "http://#{ip}#{port_part()}/pair?code=#{code}"

  @doc "The page's address by name (mDNS: `<hostname>.local`)."
  @spec local_url() :: String.t()
  def local_url do
    {:ok, hostname} = :inet.gethostname()
    "http://#{hostname}.local#{port_part()}"
  end

  defp port_part do
    case port() do
      80 -> ""
      port -> ":#{port}"
    end
  end
end
