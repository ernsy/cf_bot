defmodule CfValr.Mediate do
  require Logger

  def get_ticker(pair) do
    {:ok, %{"askPrice" => ask, "bidPrice" => bid}} = JsonUtils.retry_req(&CfValr.Api.get_ticker/1, [pair], 61000)
    %{"ask" => ask, "bid" => bid}
  end

  def get_avail_bal(currency) do
    {:ok, balances} =
      JsonUtils.retry_req(&CfValr.Api.balances/0, [], 61000)
    %{"available" => avail_str, "reserved" => res_str} =
      Enum.find(balances, fn (%{"currency" => curr}) -> curr == currency end)
    {avail_bal, _rem_bin} = Float.parse(avail_str)
    {res_bal, _rem_bin} = Float.parse(res_str)
    total_avail = avail_bal + res_bal
    Logger.info("Available #{currency} balance: #{total_avail}")
    total_avail
  end

  def get_maker_fee() do
    0.01
  end

  def get_orderbook(pair) do
    {:ok, %{"Bids" => bids, "Asks" => asks}} = JsonUtils.retry_req(&CfValr.Api.get_orderbook_top/1, [pair], 61000)
    mediated_bids = mediate_order_book(bids)
    mediated_asks = mediate_order_book(asks)
    %{"bids" => mediated_bids, "asks" => mediated_asks}
  end

  def post_order(pair, type, quantity, price, post_only) do
    q_str = :erlang.float_to_binary(quantity, [{:decimals, 6}])
    price_str = trunc(price)
    side = if type == "ASK", do: "sell", else: "buy"
    Logger.info("Place limit #{type} for #{q_str} at #{price_str}")
    params = %{pair: pair, side: side, quantity: q_str, price: price_str, post_only: post_only}
    {:ok, %{"id" => new_order_id}} = JsonUtils.retry_req(&CfValr.Api.post_limit_order/1, [params], 61000)
    new_order_id
  end

  def stop_order(order_id, price) do
    Logger.info("Cancel limit order #{order_id} at #{price}")
    params = %{"orderId" => order_id, "pair" => "BTCZAR"} #TODO make pair variable
    JsonUtils.retry_req(&CfValr.Api.delete_order/1, [params], 61000)
  end

  def list_open_orders(pair) do
    {:ok, orders} = JsonUtils.retry_req(&CfValr.Api.list_orders/0, [], 61000)
    orders &&
      Enum.filter(orders, &(&1["currencyPair"] == pair))
      |> Enum.map(
           fn (%{"orderId" => id, "price" => price, "createdAt" => datetime_str}) ->
             ts = JsonUtils.convert_date_time(datetime_str)
             {pricef, _} = Float.parse(price)
             %{order_id: id, order_price: pricef, order_time: ts}
           end
         )
  end

  def sum_trades(_product_id, _since, _, true), do: %{"ASK" => 0, "BID" => 0}
  def sum_trades(pair, since, _order_id, _) do
    {:ok, trades} = JsonUtils.retry_req(&CfValr.Api.get_trade_history/2, [pair, "10"], 61000)
    get_traded_volume(trades, since)
  end

  def handle_ws_msg(%{"type" => "NEW_ACCOUNT_TRADE", "data" => data} = msg, state) do
    Logger.warn("New Valr trade #{inspect msg}")
    %{"quantity" => vol_str, "tradedAt" => date_time_str, "side" => side} = data
    ts = JsonUtils.convert_date_time(date_time_str)
    {vol, _rem_bin} = Float.parse(vol_str)
    med_data = %{"msg_type" => "new_trade", "volume" => vol, "timestamp" => ts, "side" => side}
    CfBot.Statem.ws_update(CfValr, med_data)
    {:ok, state}
  end

  def handle_ws_msg(msg, state) do
    Logger.debug("Unhandled Valr WS msg #{inspect msg}")
    {:ok, state}
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
  defp get_traded_volume([%{"tradedAt" => latest_ts_str} | _] = trades, since) do
    [ask, bid] =
      Enum.filter(
        trades,
        fn (%{"tradedAt" => dt_str}) ->
          ts = JsonUtils.convert_date_time(dt_str)
          ts > since
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
    latest_ts = JsonUtils.convert_date_time(latest_ts_str)
    vol = %{"ASK" => ask, "BID" => bid, "latest_ts" => latest_ts}
    Logger.info("Traded vol: #{inspect vol}")
    vol
  end

end
