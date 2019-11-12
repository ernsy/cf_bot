defmodule CfLuno.Request do
  require Logger
  import String, only: [to_float: 1]

  def list_open_orders(pair) do
    {:ok, %{"orders" => orders}} = CfLuno.Api.list_orders(pair, "PENDING")
    orders && Enum.map(orders, fn(%{"order_id" => id, "limit_price" => price}) -> %{id: id, price: price} end)
  end

  def get_bal(asset) do
    {
      :ok,
      %{"balance" => [%{"balance" => avail_bal, "unconfirmed" => unconf_bal, "reserved" => reserved}]}
    } = CfLuno.Api.balance(asset)
    avail_bal = to_float(avail_bal) + to_float(unconf_bal) - to_float(reserved)
    Logger.info("Available #{inspect asset} balance: #{inspect avail_bal}")
    avail_bal
  end

end
