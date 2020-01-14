defmodule CfCb.WsUserClient do
  use WebSockex
  require Logger

  @url Application.get_env(:cf_bot, :cb_ws_uri, "wss://ws-feed-public.sandbox.pro.coinbase.com")

  def start_link([cb_fun, pair]) do
    {:ok, pid} = WebSockex.start_link(@url, __MODULE__, %{cb_fun: cb_fun, pair: pair})
    subscribe(pid, pair)
    {:ok, pid}
  end

  def handle_connect(_conn, state) do
    Logger.info("CB User WS connected!")
    {:ok, state}
  end

  def handle_disconnect(_conn, state) do
    Logger.info("CB User WS disconnected")
    {:ok, state}
  end

  def handle_frame({:text, body}, %{cb_fun: cb_fun} = state) do
    Jason.decode!(body)
    |> cb_fun.handle_ws_msg(state)
  end

  def subscribe(pid, pair) do
    frame = subscription_frame(pair)
    WebSockex.send_frame(pid, frame)
  end

  defp subscription_frame(pair) do
    {key, sign, ts, passphrase} = CfCb.Api.get_auth_params("GET", "/users/self/verify", "")
    subscription_json = %{
                          type: "subscribe",
                          product_ids: [pair],
                          channels: ["user"],
                          signature: sign,
                          key: key,
                          passphrase: passphrase,
                          timestamp: ts
                        }
                        |> Jason.encode!()
    {:text, subscription_json}
  end
end