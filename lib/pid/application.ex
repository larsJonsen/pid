defmodule Pid.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Pid.Store,
      Pid.Co2Controller,
      Pid.MqttClient
    ]

    opts = [strategy: :one_for_one, name: Pid.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
