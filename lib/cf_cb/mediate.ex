defmodule CfCb.Mediate do
  require Logger

  def get_ticker(product_id) do
    {:ok, ticker} = JsonUtils.retry_req(&CfCb.Api.get_ticker/1, [product_id])
    ticker
  end

  def get_avail_bal(currency) do
    {:ok, accounts} = JsonUtils.retry_req(&CfCb.Api.get_accounts/0, [])
    %{"available" => avail_str} =
      Enum.find(accounts, fn (%{"currency" => acc_curr}) -> acc_curr == currency end)
    {avail_bal, _rem_bin} = Float.parse(avail_str)
    Logger.info("Available #{currency} balance: #{avail_bal}")
    avail_bal
  end

  def get_maker_fee() do
    {:ok, fees} = JsonUtils.retry_req(&CfCb.Api.get_fees/0, [])
    {maker_fee, _} = fees["maker_fee_rate"]
                     |> Float.parse()
    maker_fee
  end

  def get_orderbook(product_id) do
    {:ok, %{"bids" => bids, "asks" => asks}} = JsonUtils.retry_req(&CfCb.Api.get_orderbook_top/1, [product_id])
    mediated_bids = mediate_order_book(bids)
    mediated_asks = mediate_order_book(asks)
    %{"bids" => mediated_bids, "asks" => mediated_asks}
  end

  def post_order(product_id, type, size, price, post_only) do
    size_str = :erlang.float_to_binary(size, [{:decimals, 6}])
    price_str = :erlang.float_to_binary(price, [{:decimals, 2}])
    side = if type == "ASK", do: "sell", else: "buy"
    Logger.info("Place limit #{type} for #{size_str} at #{price_str}")
    params = %{product_id: product_id, side: side, size: size_str, price: price_str, post_only: post_only}
    {:ok, %{"id" => new_order_id}} = JsonUtils.retry_req(&CfCb.Api.place_order/1, [params])
    new_order_id
  end

  def stop_order(order_id, price) do
    Logger.info("Cancel limit order #{order_id} at #{price}")
    JsonUtils.retry_req(&CfCb.Api.cancel_order/1, [order_id])
    Process.sleep(100)
  end

  def list_open_orders(product_id) do
    {:ok, orders} = JsonUtils.retry_req(&CfCb.Api.list_orders/1, [[product_id: product_id, status: "open"]])
    orders && Enum.map(
      orders,
      fn (%{"id" => id, "price" => price, "created_at" => datetime_str}) ->
        ts = JsonUtils.convert_date_time(datetime_str)
        {pricef, _} = Float.parse(price)
        %{order_id: id, order_price: pricef, order_time: ts}
      end
    )
  end

  def sum_trades(_product_id, _since, nil, _), do: %{"ASK" => 0, "BID" => 0}
  def sum_trades(_product_id, _since, _, true), do: %{"ASK" => 0, "BID" => 0}
  def sum_trades(_product_id, since, order_id, false) do
    {:ok, fills} = JsonUtils.retry_req(&CfCb.Api.get_fills/1, [[order_id: order_id]])
    get_traded_volume(fills, since)
  end

  def handle_ws_msg(%{"type" => "match", "time" => date_time_str, "size" => vol_str, "side" => side} = msg, state) do
    Logger.warn("New CB trade #{inspect msg}")
    ts = JsonUtils.convert_date_time(date_time_str)
    {vol, _rem_bin} = Float.parse(vol_str)
    med_data = %{"msg_type" => "new_trade", "volume" => vol, "timestamp" => ts, "side" => side}
    CfBot.Statem.ws_update(CfCb, med_data)
    {:ok, state}
  end

  #  {
  #"type": "match",
  #"trade_id": 10,
  #"sequence": 50,
  #         "maker_order_id": "ac928c66-ca53-498f-9c13-a110027a60e8",
  #                            "taker_order_id": "132fb6ae-456b-4654-b4e0-d681ac05cea1",
  #                                                                                   "time": "2014-11-07T08:19:27.028459Z",
  #"product_id": "BTC-USD",
  #"size": "5.23512",
  #"price": "400.23",
  #"side": "sell"
  # }

  def handle_ws_msg(msg, state) do
    Logger.warn("Unhandled CB WS msg #{inspect msg}")
    {:ok, state}
  end

  #---------------------------------------------------------------------------------------------------------------------
  # helper functions
  #---------------------------------------------------------------------------------------------------------------------


  defp mediate_order_book(orders) do
    Enum.map(
      orders,
      fn ([price, size, _num_orders]) ->
        %{"volume" => size, "price" => price}
      end
    )
  end

  defp get_traded_volume([], _), do: %{"ASK" => 0, "BID" => 0}
  defp get_traded_volume([%{"created_at" => latest_ts_str} | _] = fills, since) do
    [ask, bid] =
      Enum.filter(
        fills,
        fn (%{"created_at" => dt_str}) ->
          ts = JsonUtils.convert_date_time(dt_str)
          ts > since
        end
      )
      |> Enum.reduce(
           [0, 0],
           fn
             (%{"side" => "sell", "size" => volume}, [vol_ask, vol_bid]) ->
               {trade_vol, _rem_bin} = Float.parse(volume)
               [vol_ask + trade_vol, vol_bid]
             (%{"side" => "buy", "size" => volume}, [vol_ask, vol_bid]) ->
               {trade_vol, _rem_bin} = Float.parse(volume)
               [vol_ask, vol_bid + trade_vol]
             (_, [vol_ask, vol_bid]) ->
               [vol_ask, vol_bid]
           end
         )
    latest_ts = JsonUtils.convert_date_time(latest_ts_str)
    vol = %{"ASK" => ask, "BID" => bid, "latest_ts" => latest_ts}
    Logger.info("Traded vol: #{inspect vol}")
    vol
  end
end
