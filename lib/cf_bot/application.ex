defmodule CfBot.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  def start(_type, _args) do
    children = [
      #      {
      #        CfBot.Statem,
      #        %{med_mod: CfLuno.Mediate, pair: "XBTZAR", oracle_pair: "BTC-USD", min_increment: 1, review_time: 2000}
      #      },
      #      {
      #        CfBot.Statem,
      #        %{med_mod: CfCb.Mediate, pair: "BTC-GBP", oracle_pair: "BTC-USD", min_increment: 0.01, review_time: 50}
      #      },
      {DynamicSupervisor, strategy: :one_for_one, name: CfBot.DynSup},
      {DynamicSupervisor, strategy: :one_for_one, name: CfBot.WsSup},
      %{
        id: CfCbWsClientBtc,
        start: {CfCb.WsClient, :start_link, [["BTC-USD"], &CfBot.Statem.oracle_update/2, [CfCb, CfLuno, CfValr]]}
      },
      %{
        id: CfCbWsClientEth,
        start: {CfCb.WsClient, :start_link, [["ETH-USD"], &CfBot.Statem.oracle_update/2, [CfLunoEth]]}
      }
    ]

    opts = [strategy: :one_for_one, name: CfBot.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
