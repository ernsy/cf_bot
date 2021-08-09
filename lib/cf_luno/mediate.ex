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
    0.0003
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
        Logger.debug("Limit #{type} #{vol_str} @ #{price_str}")
        new_order_id
      _ -> nil
    end
  end

  def market_order(pair, type, volume) do
    vol_str = :erlang.float_to_binary(volume, [{:decimals, 6}])
    type = if type == "BID", do: "BUY", else: "SELL"
    params0 = [pair: pair, type: type]
    if type == "BUY" do
      {ask_price, _} = get_ticker(pair)["ask"]
                       |> Float.parse()
      counter_vol = ask_price * volume
                    |> :erlang.float_to_binary([{:decimals, 6}])
      Logger.warn("Market #{type} #{vol_str} @ #{ask_price}")
      JsonUtils.retry_req(&CfLuno.Api.market_order/1, [params0 ++ [counter_volume: counter_vol]])
    else
      result = JsonUtils.retry_req(&CfLuno.Api.market_order/1, [params0 ++ [base_volume: vol_str]])
      {bid_price, _} = get_ticker(pair)["bid"]
                       |> Float.parse()
      Logger.warn("Market #{type} #{vol_str} @ #{bid_price}")
      result
    end
  end

  def stop_order(nil) do
    {:ok, [nil, false]}
  end
  def stop_order(order_id) do
    Logger.debug("Cancel limit order #{order_id}")
    case JsonUtils.retry_req(&CfLuno.Api.stop_order/1, [order_id]) do
      {:ok, %{"success" => true}} -> {:ok, [nil, true]}
      _ -> {:ok, [order_id, false]}
    end
  end

  def list_open_orders(pair) do
    case JsonUtils.retry_req(&CfLuno.Api.list_orders/1, [[pair: pair, state: "PENDING"]]) do
      {:ok, %{"orders" => orders}} ->
        Logger.debug("Orders #{inspect orders}")
        orders && Enum.map(
          orders,
          fn (%{"order_id" => id, "limit_price" => price, "creation_timestamp" => ts}) ->
            {pricef, _} = Float.parse(price)
            %{order_id: id, old_price: pricef, order_time: ts}
          end
        )
      _ -> %{}
    end
  end

  def sum_trades(_product_id, _since, _order_id, true) do
    nil
  end
  def sum_trades(pair, since, _order_id, false) do
    {:ok, %{"trades" => trades}} = JsonUtils.retry_req(&CfLuno.Api.list_trades/1, [[pair: pair, since: since]])
    get_traded_volume(trades)
  end

  #---------------------------------------------------------------------------------------------------------------------
  # helper functions
  #---------------------------------------------------------------------------------------------------------------------

  defp get_traded_volume(nil), do: nil
  defp get_traded_volume(trades) do
    [ask, bid, total_sec] = Enum.reduce(
      trades,
      [0, 0, 0],
      fn
        (%{"type" => "ASK", "volume" => volume, "price" => price}, [vol_ask, vol_bid, total_sec]) ->
          vol_f = to_float(volume)
          price_f = to_float(price)
          [vol_ask + vol_f, vol_bid, total_sec + price_f * vol_f]
        (%{"type" => "BID", "volume" => volume, "price" => price}, [vol_ask, vol_bid, total_sec]) ->
          vol_f = to_float(volume)
          price_f = to_float(price)
          [vol_ask, vol_bid + vol_f, total_sec - price_f * vol_f]
      end
    )
    latest_ts = trades
                |> List.last()
                |> Map.get("timestamp")
    avg = if ask > 0 or bid > 0, do: round(total_sec / (ask - bid)), else: 0
    vol = %{"ASK" => ask, "BID" => bid, "latest_ts" => latest_ts + 2, "avg" => avg}
    cond do
      ask > 0 and bid > 0 -> Logger.warn("Traded vol: #{inspect vol}")
      ask > 0.05 -> Logger.error("Sold #{ask} @ #{avg}")
      ask > 0 -> Logger.info("Sold #{ask} @ #{avg}")
      bid > 0.05 -> Logger.error("Bought #{bid} @ #{avg}")
      bid > 0 -> Logger.info("Bought #{bid} @ #{avg}")
      true -> :ok
    end
    vol
  end

end
