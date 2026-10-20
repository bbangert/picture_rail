defmodule HomeFrame.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      HomeFrame.Hardware.impl().children() ++
        [
          {Task.Supervisor, name: HomeFrame.TaskSup}
        ]

    Supervisor.start_link(children, strategy: :one_for_one, name: HomeFrame.Supervisor)
  end
end
