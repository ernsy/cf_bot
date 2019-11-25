defmodule CfCb.TestMed do
  require Logger

  def post_order(_product_id, type, size, price, _post_only) do
    size_str = :erlang.float_to_binary(size, [{:decimals, 6}])
    Logger.info("MOCK: Place limit #{type} for #{size_str} at #{price}")
    "TestOrderID"
  end

  def stop_order(order_id, price) do
    Logger.info("MOCK: Cancel limit order #{order_id} at #{price}")
    {:ok, %{"success" => true}}
  end

  def sum_trades(_product_id, _since, nil), do: %{"ASK" => 0, "BID" => 0}
  def sum_trades(_product_id, _since, _order_id) do
    IO.inspect(%{"ASK" => 0.0005, "BID" => 0.001}, label: "MOCK traded vol")
  end

  def get_avail_bal(currency) do
    IO.inspect((if currency == "BTC", do: 0.5, else: 2500.0), label: "MOCK Bal")
  end

  def get_ticker(product_id) do
    CfCb.Mediate.get_ticker(product_id)
  end


  def get_maker_fee() do
    CfCb.Mediate.get_maker_fee()
  end

  def get_orderbook(product_id) do
    CfCb.Mediate.get_orderbook(product_id)
  end

  def list_open_orders(product_id) do
    CfCb.Mediate.list_open_orders(product_id)
  end
end

