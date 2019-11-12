defmodule CfCb.Request do

  def list_open_orders(product_id) do
    {:ok, orders} = CfCb.Api.list_orders(product_id, "open")
    orders
  end

end
