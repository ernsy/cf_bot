defmodule CfCb.Mediate do
  require Logger
  import String, only: [to_float: 1]

  def get_ticker(product_id) do
    {:ok, ticker} = CfCb.Api.get_ticker(product_id)
    ticker
  end

  def get_avail_bal(currency) do
    {:ok, accounts} = JsonUtils.retry_req(&CfCb.Api.get_accounts/0, [])
    account = Enum.find(accounts, fn (%{"currency" => acc_curr} = account) -> acc_curr == currency end)
    {avail_bal, _rem_bin} = Float.parse(account["available"])
    Logger.info("Available #{currency} balance: #{avail_bal}")
    avail_bal
  end

  def get_orderbook(product_id) do
    {:ok, %{"bids" => bids, "asks" => asks}} = JsonUtils.retry_req(&CfCb.Api.get_orderbook_top,[product_id])
    mediated_bids = mediate_order_book(tl(bids))
    mediated_asks = mediate_order_book(tl(asks))
    %{"bids" => mediated_bids, "asks" => mediated_asks}
  end

  def post_order(pair, type, volume, price, post_only) do
    vol_str = :erlang.float_to_binary(volume, [{:decimals, 6}])
    Logger.info("Place limit #{type} for #{vol_str} at #{price}")
    params = [pair: pair, type: type, volume: vol_str, price: price, post_only: post_only]
    {:ok, %{"id" => new_order_id}} = CfCb.Api.post_order(params)
    new_order_id
  end
#{
#"id": "d0c5340b-6d6c-49d9-b567-48c4bfca13d2",
#"price": "0.10000000",
#"size": "0.01000000",
#"product_id": "BTC-USD",
# "side": "buy",
#      "stp": "dc",
#           "type": "limit",
#                   "time_in_force": "GTC",
#                                     "post_only": false,
#"created_at": "2016-12-08T20:02:28.53864Z",
#"fill_fees": "0.0000000000000000",
#"filled_size": "0.00000000",
# "executed_value": "0.0000000000000000",
#                "status": "pending",
#                        "settled": false
#                                   }

  def stop_order(order_id, price) do
    Logger.info("Cancel limit order #{order_id} at #{price}")
    CfCb.Api.cancel_order(order_id)
  end

  def list_open_orders(product_id) do
    {:ok, orders} = CfCb.Api.list_orders([product_id: product_id, status: "open"])
    orders
  end

  def list_trades(_product_id, _since, order_id) do
    {:ok, fills} = CfCb.Api.fills([order_id: order_id])
    get_traded_volume(fills)
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

  defp get_traded_volume(nil), do: %{"ASK" => 0, "BID" => 0}
  defp get_traded_volume(fills) do
    [ask, bid] = Enum.reduce(
      fills,
      [0, 0],
      fn
        (%{"side" => "sell", "size" => volume}, [vol_ask, vol_bid]) -> [vol_ask + to_float(volume), vol_bid]
        (%{"side" => "buy", "size" => volume}, [vol_ask, vol_bid]) -> [vol_ask, vol_bid + to_float(volume)]
      end
    )
    vol = %{"ASK" => ask, "BID" => bid}
    Logger.info("Traded vol: #{inspect vol}")
    vol
  end
end
