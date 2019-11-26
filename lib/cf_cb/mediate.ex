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
  end

  def list_open_orders(product_id) do
    {:ok, orders} = JsonUtils.retry_req(&CfCb.Api.list_orders/1, [[product_id: product_id, status: "open"]])
    orders && Enum.map(
      orders,
      fn (%{"id" => id, "price" => price, "created_at" => datetime_str}) ->
        {:ok, datetime, _} = DateTime.from_iso8601(datetime_str)
        ts = DateTime.to_unix(datetime)
        {pricef, _} = Float.parse(price)
        %{order_id: id, order_price: pricef, order_time: ts}
      end
    )
  end

  def sum_trades(_product_id, _since, nil), do: %{"ASK" => 0, "BID" => 0}
  def sum_trades(_product_id, since, order_id) do
    {:ok, fills} = JsonUtils.retry_req(&CfCb.Api.get_fills/1, [[order_id: order_id]])
    get_traded_volume(fills, since)
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

  defp get_traded_volume(nil, _), do: %{"ASK" => 0, "BID" => 0}
  defp get_traded_volume(fills, since) do
    [ask, bid] =
      Enum.map(
        fills,
        fn (%{"created_at" => dt_str} = fill) ->
          {:ok, dt, 0} = DateTime.from_iso8601(dt_str)
          ts = DateTime.to_unix(dt)
          Map.put(fill, :order_time, ts)
        end
      )
      |> Enum.reduce(
           [0, 0],
           fn
             (%{"side" => "sell", "size" => volume, :order_time => ts}, [vol_ask, vol_bid]) when ts >= since ->
               {trade_vol, _rem_bin} = Float.parse(volume)
               [vol_ask + trade_vol, vol_bid]
             (%{"side" => "buy", "size" => volume, :order_time => ts}, [vol_ask, vol_bid]) when ts >= since ->
               {trade_vol, _rem_bin} = Float.parse(volume)
               [vol_ask, vol_bid + trade_vol]
             (_, [vol_ask, vol_bid]) ->
               [vol_ask, vol_bid]
           end
         )
    vol = %{"ASK" => ask, "BID" => bid}
    Logger.info("Traded vol: #{inspect vol}")
    vol
  end
end
