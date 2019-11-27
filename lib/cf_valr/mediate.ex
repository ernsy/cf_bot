defmodule CfValr.Mediate do
  require Logger

  def get_ticker(pair) do
    {:ok, ticker} = JsonUtils.retry_req(&CfValr.Api.get_ticker/1, [pair])
    ticker
  end

  def get_avail_bal(currency) do
    {:ok, balances} =
      JsonUtils.retry_req(&CfValr.Api.balances/0, [])
    %{"available" => avail_str} =
      Enum.find(balances, fn (%{"currency" => curr}) -> curr == currency end)
    {avail_bal, _rem_bin} = Float.parse(avail_str)
    Logger.info("Available #{currency} balance: #{avail_bal}")
    avail_bal
  end

  def get_maker_fee() do
    0.01
  end

  def get_orderbook(pair) do
    {:ok, %{"Bids" => bids, "Asks" => asks}} = JsonUtils.retry_req(&CfValr.Api.get_orderbook_top/1, [pair])
    mediated_bids = mediate_order_book(bids)
    mediated_asks = mediate_order_book(asks)
    %{"bids" => mediated_bids, "asks" => mediated_asks}
  end

  def post_order(pair, type, quantity, price, post_only) do
    q_str = :erlang.float_to_binary(quantity, [{:decimals, 6}])
    price_str = :erlang.float_to_binary(price, [{:decimals, 2}])
    side = if type == "ASK", do: "sell", else: "buy"
    Logger.info("Place limit #{type} for #{q_str} at #{price_str}")
    params = %{pair: pair, side: side, quantity: q_str, price: price_str, post_only: post_only}
    {:ok, %{"id" => new_order_id}} = JsonUtils.retry_req(&CfValr.Api.post_limit_order/1, [params])
    new_order_id
  end

  def stop_order(order_id, price) do
    Logger.info("Cancel limit order #{order_id} at #{price}")
    params = %{"orderId" => order_id, "pair" => "BTCZAR"} #TODO make pair variable
    JsonUtils.retry_req(&CfValr.Api.delete_order/1, [params])
  end

  def list_open_orders(pair) do
    {:ok, orders} = JsonUtils.retry_req(&CfValr.Api.list_orders/0, [])
    orders &&
      Enum.filter(orders, &(&1["currencyPair"] == pair))
      |> Enum.map(
           fn (%{"orderId" => id, "price" => price, "createdAt" => datetime_str}) ->
             {:ok, datetime, _} = DateTime.from_iso8601(datetime_str)
             ts = DateTime.to_unix(datetime)
             {pricef, _} = Float.parse(price)
             %{order_id: id, order_price: pricef, order_time: ts}
           end
         )
  end

  def sum_trades(pair, since, _order_id) do
    {:ok, trades} = JsonUtils.retry_req(&CfValr.Api.get_trade_history/2, [pair, "10"])
    get_traded_volume(trades, since)
  end

  #---------------------------------------------------------------------------------------------------------------------
  # helper functions
  #---------------------------------------------------------------------------------------------------------------------


  defp mediate_order_book(orders) do
    Enum.map(
      orders,
      fn (%{"quantity" => vol, "price" => price}) ->
        %{"volume" => vol, "price" => price}
      end
    )
  end

  defp get_traded_volume(nil, _), do: %{"ASK" => 0, "BID" => 0}
  defp get_traded_volume(trades, since) do
    [ask, bid] =
      Enum.filter(
        trades,
        fn (%{"tradedAt" => dt_str}) ->
          {:ok, dt, 0} = DateTime.from_iso8601(dt_str)
          ts = DateTime.to_unix(dt)
          ts >= since
        end
      )
      |> Enum.reduce(
           [0, 0],
           fn
             (%{"side" => "sell", "quantity" => volume}, [vol_ask, vol_bid]) ->
               {trade_vol, _rem_bin} = Float.parse(volume)
               [vol_ask + trade_vol, vol_bid]
             (%{"side" => "buy", "quantity" => volume}, [vol_ask, vol_bid]) ->
               {trade_vol, _rem_bin} = Float.parse(volume)
               [vol_ask, vol_bid + trade_vol]
           end
         )
    vol = %{"ASK" => ask, "BID" => bid}
    Logger.info("Traded vol: #{inspect vol}")
    vol
  end

end
