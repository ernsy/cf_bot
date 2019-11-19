defmodule CfLuno.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  def start(_type, _args) do
    children = [
      # Starts a worker by calling: CfLuno.Worker.start_link(arg)
      # {CfLuno.Worker, arg}
#      {
#        CfLuno.Statem,
#        %{med_mod: CfLuno.Mediate, pair: "XBTZAR", oracle_pair: "BTC-USD", min_increment: 1, review_time: 2000}
#      },
      {
        CfLuno.Statem,
        %{med_mod: CfCb.Mediate, pair: "BTC-USD", oracle_pair: "BTC-USD", min_increment: 0.01, review_time: 400}
      },
      {CfCb.WsClient, {["BTC-USD"], &CfLuno.Statem.oracle_update/1}}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: CfLuno.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
