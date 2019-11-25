defmodule CfLuno.TestMed do
  require Logger

  def post_order(_pair, type, volume, price, _post_only) do
    vol_str = :erlang.float_to_binary(volume, [{:decimals, 6}])
    Logger.info("MOCK: Place limit #{type} for #{vol_str} at #{price}")
    "TestOrderID"
  end

  def stop_order(order_id, price) do
    Logger.info("MOCK: Cancel limit order #{order_id} at #{price}")
    {:ok, %{"success" => true}}
  end

  def sum_trades(_pair, _since, _order_id) do
    IO.inspect(%{"ASK" => 0.001, "BID" => 0.001}, label: "sum_trades")
  end

  def get_ticker(pair) do
    CfLuno.Mediate.get_ticker(pair)
  end

  def get_avail_bal(asset) do
    CfLuno.Mediate.get_avail_bal(asset)
  end

  def get_maker_fee() do
    CfLuno.Mediate.get_maker_fee()
  end

  def get_orderbook(pair) do
    CfLuno.Mediate.get_orderbook(pair)
  end

  def list_open_orders(pair) do
    CfLuno.Mediate.list_open_orders(pair)
  end

end
