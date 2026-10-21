defmodule PictureRail.MixProject do
  use Mix.Project

  @app :picture_rail
  @version "0.1.0"
  # Devices this app has a Nerves system and a PictureRail.Hardware module
  # for. To support another touch display, add its system below and its
  # hardware module in lib/picture_rail/hardware/ (see README).
  @all_targets [:frame156]

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.20",
      archives: [nerves_bootstrap: "~> 1.17"],
      listeners: listeners(Mix.target(), Mix.env()),
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      # One deps directory per target: Emerge downloads its NIF into its
      # priv/, which the host and the device would otherwise share.
      deps_path: "deps/#{Mix.target()}",
      deps: deps(),
      releases: [{@app, release()}]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :runtime_tools],
      mod: {PictureRail.Application, []}
    ]
  end

  def cli do
    [preferred_targets: [run: :host, test: :host]]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Dependencies for all targets
      {:nerves, "~> 1.13", runtime: false},
      {:shoehorn, "~> 0.9.1"},
      {:logger_backends, "~> 1.0"},
      {:ring_logger, "~> 0.11.0"},
      {:toolshed, "~> 0.5.0"},

      # Allow Nerves.Runtime on host to support development, testing and CI.
      # See config/host.exs for usage.
      {:nerves_runtime, "~> 0.13.12"},

      # UI, state, Home Assistant and Immich
      {:emerge, "~> 0.5.0"},
      {:solve, "~> 0.3.1"},
      {:hassock, "~> 0.3.0"},
      {:req, "~> 0.7.5"},
      {:jason, "~> 1.4"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},

      # The settings web page (paired from the frame's Setup page)
      {:plug, "~> 1.18"},
      # 1.12.5's advisories (EEF-CVE-2026-105659/105660) don't apply with
      # HTTP/2 off and conn.host unused (PictureRail.Web); move to 1.13
      # (and thousand_island 1.6) once they're two weeks old.
      {:bandit, "~> 1.12.5"},
      {:thousand_island, "~> 1.5.0"},
      {:eqrcode, "~> 0.2.1"},

      # Dependencies for all targets except :host
      {:nerves_pack, "~> 0.7.2", targets: @all_targets},

      # FRAME156 accelerometer (also builds on the host, so the hardware
      # modules compile and test there)
      {:circuits_i2c, "~> 2.1"},

      # Dependencies for specific targets
      frame156_system()
    ]
  end

  # Until the system publishes release artifacts, build against a local
  # checkout of it (its compiled artifact is reused). Point
  # FRAME156_SYSTEM_PATH somewhere else if your checkout lives elsewhere.
  defp frame156_system do
    path = System.get_env("FRAME156_SYSTEM_PATH", "../nerves_system_rk3326_frame156")

    {:nerves_system_rk3326_frame156,
     path: path, runtime: false, targets: :frame156, nerves: [compile: true]}
  end

  def release do
    [
      overwrite: true,
      # Erlang distribution is not started automatically.
      # See https://nerves-pack.hexdocs.pm/readme.html#erlang-distribution
      cookie: "#{@app}_cookie",
      include_erts: &Nerves.Release.erts/0,
      steps: [&Nerves.Release.init/1, :assemble],
      strip_beams: Mix.env() == :prod or [keep: ["Docs"]]
    ]
  end

  # Uncomment the following line if using Phoenix > 1.8.
  # defp listeners(:host, :dev), do: [Phoenix.CodeReloader]
  defp listeners(_, _), do: []
end
