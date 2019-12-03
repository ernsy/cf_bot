defmodule CfLuno.Mediate do
  require Logger
  import String, only: [to_float: 1]

  def get_ticker(pair) do
    {:ok, ticker} = JsonUtils.retry_req(&CfLuno.Api.get_ticker/1, [pair])
    ticker
  end

  def get_avail_bal(asset) do
    {:ok, %{"balance" => [%{"balance" => avail_bal, "unconfirmed" => unconf_bal, "reserved" => reserved}]}} =
      JsonUtils.retry_req(&CfLuno.Api.balance/1, [asset])
    avail_bal = to_float(avail_bal) + to_float(unconf_bal) - to_float(reserved)
    Logger.info("Available #{asset} balance: #{avail_bal}")
    avail_bal
  end

  def get_maker_fee() do
    0.01
  end

  def get_orderbook(pair) do
    {:ok, orderbook} = JsonUtils.retry_req(&CfLuno.Api.get_orderbook_top/1,[pair])
    orderbook
  end

  def post_order(pair, type, volume, price, post_only) do
    vol_str = :erlang.float_to_binary(volume, [{:decimals, 6}])
    price_str = trunc(price)
    Logger.info("Place limit #{type} for #{vol_str} at #{price_str}")
    params = [pair: pair, type: type, volume: vol_str, price: price_str, post_only: post_only]
    {:ok, %{"order_id" => new_order_id}} = JsonUtils.retry_req(&CfLuno.Api.post_order/1, [params])
    new_order_id
  end

  def stop_order(order_id, price) do
    Logger.info("Cancel limit order #{order_id} at #{price}")
    JsonUtils.retry_req(&CfLuno.Api.stop_order/1, [order_id])
    Process.sleep(400) #wait for balance to update after cancelling order
  end

  def list_open_orders(pair) do
    {:ok, %{"orders" => orders}} = JsonUtils.retry_req(&CfLuno.Api.list_orders/1 ,[[pair: pair, state: "PENDING"]])
    orders && Enum.map(
      orders,
      fn (%{"order_id" => id, "limit_price" => price,  "creation_timestamp" => ts}) ->
        {pricef, _} = Float.parse(price)
        %{order_id: id, order_price: pricef, order_time: ts}
      end
    )
  end

  def sum_trades(_product_id, _since, _, true), do: %{"ASK" => 0, "BID" => 0}
  def sum_trades(pair, since, _order_id, false) do
    {:ok, %{"trades" => trades}} = JsonUtils.retry_req(&CfLuno.Api.list_trades/1, [[pair: pair, since: since]])
    get_traded_volume(trades)
  end

  #---------------------------------------------------------------------------------------------------------------------
  # helper functions
  #---------------------------------------------------------------------------------------------------------------------

  defp get_traded_volume(nil), do: %{"ASK" => 0, "BID" => 0}
  defp get_traded_volume(trades) do
    [ask, bid] = Enum.reduce(
      trades,
      [0, 0],
      fn
        (%{"type" => "ASK", "volume" => volume}, [vol_ask, vol_bid]) -> [vol_ask + to_float(volume), vol_bid]
        (%{"type" => "BID", "volume" => volume}, [vol_ask, vol_bid]) -> [vol_ask, vol_bid + to_float(volume)]
      end
    )
    vol = %{"ASK" => ask, "BID" => bid}
    Logger.info("Traded vol: #{inspect vol}")
    vol
  end

end
