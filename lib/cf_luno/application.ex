defmodule CfLuno.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  def start(_type, _args) do
    children = [
      # Starts a worker by calling: CfLuno.Worker.start_link(arg)
      # {CfLuno.Worker, arg}
      {CfLuno.Statem, ["XBTZAR"]},
      {CfCb.WsClient, {["BTC-USD"], &CfLuno.Statem.oracle_update/1}}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: CfLuno.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
