defmodule CfCb.WsClient do
  use WebSockex
  require Logger

  @url "wss://ws-feed.pro.coinbase.com"

  def start_link([products, cb_fun, cb_names]) do
    {:ok, pid} = WebSockex.start_link(@url, __MODULE__, %{products: products, cb_fun: cb_fun, cb_names: cb_names})
    subscribe(pid, products)
    {:ok, pid}
  end

  def handle_connect(_conn, state) do
    Logger.info("CB WS connected!")
    {:ok, state}
  end

  def handle_disconnect(_conn, state) do
    IO.puts("CB WS disconnected")
    {:ok, state}
  end

  def handle_frame({:text, msg}, state) do
    handle_msg(Jason.decode!(msg), state)
  end

  def handle_msg( %{"type" => "ticker"} = msg, %{cb_fun: cb_fun, cb_names: names} = state) do
    Enum.each(names,&(cb_fun.(&1, msg)))
    {:ok, state}
  end

  def handle_msg(_, state), do: {:ok, state}

  def subscribe(pid, products) do
    frame = subscription_frame(products)
    WebSockex.send_frame(pid, frame)
  end

  defp subscription_frame(products) do
    subscription_json =
      %{
        type: "subscribe",
        product_ids: products,
        channels: ["ticker"]
      }
      |> Jason.encode!()

    {:text, subscription_json}
  end
end