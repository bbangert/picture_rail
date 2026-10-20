defmodule PictureRail.HA.Supervisor do
  @moduledoc """
  The Home Assistant side: a dynamic supervisor for the hassock connection
  (started and replaced by `PictureRail.HA.Model` as the settings change),
  the model, and the energy poller (which asks the connection for
  statistics).

  `one_for_all`: the connection under the dynamic supervisor belongs to the
  model that started it (its events go to that model, under fixed names),
  so a new model starts with an empty one; and a new connection supervisor
  means the model's connection is gone. The poller holds nothing that
  outlives a fetch, so restarting it with them costs one fetch.

  Options: `:name`, `:conn_sup` (the dynamic supervisor's name), `:model`
  (options for the model) and `:energy` (`false` leaves the poller out).
  """
  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl Supervisor
  def init(opts) do
    conn_sup = Keyword.get(opts, :conn_sup, PictureRail.HA.ConnSup)
    model_opts = opts |> Keyword.get(:model, []) |> Keyword.put_new(:conn_sup, conn_sup)

    children =
      [
        {DynamicSupervisor, name: conn_sup, strategy: :one_for_one},
        {PictureRail.HA.Model, model_opts}
      ] ++ if(Keyword.get(opts, :energy, true), do: [PictureRail.HA.EnergyPoller], else: [])

    Supervisor.init(children, strategy: :one_for_all)
  end
end
