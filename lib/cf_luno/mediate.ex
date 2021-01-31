defmodule CfLuno.Mediate do
  require Logger
  import String, only: [to_float: 1]

  def get_ticker(pair) do
    {:ok, ticker} = JsonUtils.retry_req(&CfLuno.Api.get_ticker/1, [pair])
    ticker
  end

  def get_avail_bal(asset, balance_reserved \\ false) do
    {:ok, %{"balance" => [%{"balance" => avail_bal, "unconfirmed" => unconf_bal, "reserved" => reserved}]}} =
      JsonUtils.retry_req(&CfLuno.Api.balance/1, [asset])
    Logger.debug("Bal avail: #{avail_bal} unconf: #{unconf_bal} reserved: #{reserved}}")
    avail_bal =
      if balance_reserved do
        to_float(avail_bal) + to_float(unconf_bal)
      else
        to_float(avail_bal) + to_float(unconf_bal) - to_float(reserved)
      end
    Logger.debug("Available #{asset} balance: #{avail_bal}")
    avail_bal
  end

  def get_maker_fee() do
    0.001
  end

  def get_orderbook(pair) do
    {:ok, orderbook} = JsonUtils.retry_req(&CfLuno.Api.get_orderbook_top/1, [pair])
    orderbook
  end

  def post_order(pair, type, volume, price, post_only) do
    vol_str = :erlang.float_to_binary(volume, [{:decimals, 6}])
    price_str = trunc(price)
    params = [pair: pair, type: type, volume: vol_str, price: price_str, post_only: post_only]
    case JsonUtils.retry_req(&CfLuno.Api.post_order/1, [params]) do
      {:ok, %{"order_id" => new_order_id}} ->
        Logger.debug("Placed limit #{type} with id #{new_order_id} for #{vol_str} at #{price_str}")
        new_order_id
      _ -> nil
    end
  end

  def market_order(pair, type, volume) do
    vol_str = :erlang.float_to_binary(volume, [{:decimals, 6}])
    type = if type ==  "BID", do: "BUY", else: "SELL"
    params0 = [pair: pair, type: type]
    if type == "BUY" do
      {ask_price, _} = get_ticker(pair)["ask"]
                       |> Float.parse()
      counter_vol = ask_price * volume
                    |> :erlang.float_to_binary([{:decimals, 6}])
      Logger.info("Place market #{type} for #{vol_str} at #{ask_price}")
      JsonUtils.retry_req(&CfLuno.Api.market_order/1, [params0 ++ [counter_volume: counter_vol]])
    else
      result = JsonUtils.retry_req(&CfLuno.Api.market_order/1, [params0 ++ [base_volume: vol_str]])
      {bid_price, _} = get_ticker(pair)["bid"]
                       |> Float.parse()
      Logger.info("Place market #{type} for #{vol_str} at #{bid_price}")
      result
    end
  end

  def stop_order(nil) do
    :ok
  end
  def stop_order(order_id) do
    Logger.debug("Cancel limit order #{order_id}")
    JsonUtils.retry_req(&CfLuno.Api.stop_order/1, [order_id])
    #Process.sleep(4000) #wait for balance to update after cancelling order
  end

  def list_open_orders(pair) do
    {:ok, %{"orders" => orders}} = JsonUtils.retry_req(&CfLuno.Api.list_orders/1, [[pair: pair, state: "PENDING"]])
    orders && Enum.map(
      orders,
      fn (%{"order_id" => id, "limit_price" => price, "creation_timestamp" => ts}) ->
        {pricef, _} = Float.parse(price)
        %{order_id: id, old_price: pricef, order_time: ts}
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
    [ask, bid, last_price] = Enum.reduce(
      trades,
      [0, 0, 0],
      fn
        (%{"type" => "ASK", "volume" => volume, "price" => price}, [vol_ask, vol_bid, _last_price]) -> [vol_ask + to_float(volume), vol_bid, price]
        (%{"type" => "BID", "volume" => volume, "price" => price}, [vol_ask, vol_bid, _last_price]) -> [vol_ask, vol_bid + to_float(volume), price]
      end
    )
    latest_ts = trades
                |> List.last()
                |> Map.get("timestamp")
    vol = %{"ASK" => ask, "BID" => bid, "latest_ts" => latest_ts + 1, "last_order_price" => last_price}
    cond do
      ask > 0 and bid > 0 -> Logger.warn("Traded vol: #{inspect vol}")
      ask > 0 ->  Logger.warn("Sold #{ask} at lowest #{last_price}")
      bid > 0 -> Logger.warn("Bought #{bid} at highest #{last_price}")
      true -> :ok
    end
    vol
  end

end
