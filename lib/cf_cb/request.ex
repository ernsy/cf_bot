defmodule CfCb.Request do
  require Logger
  import String, only: [to_float: 1]

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

  defp get_traded_volume(nil), do: [0, 0]
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
