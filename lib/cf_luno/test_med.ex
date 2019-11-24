defmodule CfLuno.TestMed do
  require Logger
  import String, only: [to_float: 1]

  def get_ticker(pair) do
    {:ok, ticker} = CfLuno.Api.get_ticker(pair)
    ticker
  end

  def get_avail_bal(asset) do
    {:ok, %{"balance" => [%{"balance" => avail_bal, "unconfirmed" => unconf_bal, "reserved" => reserved}]}} =
      CfLuno.Api.balance(asset)
    avail_bal = to_float(avail_bal) + to_float(unconf_bal) - to_float(reserved)
    Logger.info("Available #{asset} balance: #{avail_bal}")
    avail_bal
  end

  def get_maker_fee() do
    0.01
  end

  def get_orderbook(pair) do
    {:ok, orderbook} = CfLuno.Api.get_orderbook_top(pair)
    orderbook
  end

  def post_order(_pair, type, volume, price, _post_only) do
    vol_str = :erlang.float_to_binary(volume, [{:decimals, 6}])
    Logger.info("MOCK: Place limit #{type} for #{vol_str} at #{price}")
    "TestOrderID"
  end

  def stop_order(order_id, price) do
    Logger.info("MOCK: Cancel limit order #{order_id} at #{price}")
    {:ok, %{"success" => true}}
  end

  def list_open_orders(pair) do
    {:ok, %{"orders" => orders}} = CfLuno.Api.list_orders([pair: pair, state: "PENDING"])
    orders && Enum.map(
      orders,
      fn (%{"order_id" => id, "limit_price" => price, "creation_timestamp" => ts}) ->
        {pricef, _} = Float.parse(price)
        %{order_id: id, order_price: pricef, order_time: ts}
      end
    )
  end

  def sum_trades(_pair, _since, _order_id) do
    get_traded_volume([%{"type" => "ASK", "volume" => "0.0005"}, %{"type" => "BID", "volume" => "0.0005"}])
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
    Logger.info("MOCK: Traded vol: #{inspect vol}")
    vol
  end



end
