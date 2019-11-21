defmodule CfCb.TestMed do
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
    Logger.info("MOCK: Place limit #{type} for #{size_str} at #{price}")
    "TestOrderID"
  end

  def stop_order(order_id, price) do
    Logger.info("MOCK: Cancel limit order #{order_id} at #{price}")
    {:ok, %{"success" => true}}
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
  def sum_trades(_product_id, _since, _order_id) do
    trades = %{"ASK" => 0.0005, "BID" => 0.001}
    Logger.info("MOCK: Traded vol: #{inspect trades}")
    trades
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
end
