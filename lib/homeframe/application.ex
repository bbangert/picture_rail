defmodule HomeFrame.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      HomeFrame.Hardware.impl().children() ++
        [
          {Task.Supervisor, name: HomeFrame.TaskSup},
          HomeFrame.Settings.Watcher,
          {HomeFrame.App, name: HomeFrame.App}
        ] ++ view()

    Supervisor.start_link(children, strategy: :one_for_one, name: HomeFrame.Supervisor)
  end

  # Started last, once the state it renders exists. Devices can leave it to
  # be started by hand (`HomeFrame.View.start/1`) while a new viewport is
  # being tried out, so a native crash can't reboot-loop validated firmware.
  defp view do
    if Application.get_env(:homeframe, :start_view, true), do: [HomeFrame.View], else: []
  end
end
