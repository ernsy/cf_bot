defmodule CfLuno.Api do
  require Logger

  @luno_url_v1 "https://api.mybitx.com/api/1"

  #---------------------------------------------------------------------------------------------------------------------
  # Mock api
  #---------------------------------------------------------------------------------------------------------------------
#  def post_order(pair, type, volume, price, post_only) when is_binary(pair) do
#    vol_str = :erlang.float_to_binary(volume, [{:decimals, 6}])
#    price_str = to_string(price)
#    Logger.info("Mock Limit " <> type <> " for " <> vol_str <> " at " <> price_str)
#    path = "/postorder?pair=" <> pair <> "&type=" <> type <> "&volume=" <> vol_str <> "&price=" <> price_str <> "&post_only=" <> post_only
#    Logger.debug("private api v1 post url: #{inspect path}")
#    {:ok, %{"order_id" => "TestOrderID"}}
#  end
#
#  def stop_order(order_id, price) when is_binary(order_id) do
#    Logger.info("Mock cancel limit order #{inspect order_id} at #{inspect price}")
#    path = "/stoporder?order_id=" <> order_id
#    Logger.debug("private api v1 post url: #{inspect path}")
#    {:ok, %{"success" => true}}
#  end
#
#  def list_trades(_params) do
#    {:ok, %{"trades" => [%{"type" => "ASK", "volume" => "0.0005"}, %{"type" => "BID", "volume" => "0.0005"}]}}
#  end

  #---------------------------------------------------------------------------------------------------------------------
  # API
  #---------------------------------------------------------------------------------------------------------------------
  @doc """
    Coinbase is used as an oracle price
  """
  def get_cb_ticker(pair) do
    url = "https://api.pro.coinbase.com/products/" <> pair <> "/ticker"
    Logger.debug("CB public api v1 url: #{inspect url}")
    HTTPoison.get(url)
    |> JsonUtils.decode_json_response()
  end

  def get_ticker(pair) do
    "/ticker?pair=" <> pair
    |> invoke_public_api_v1()
  end

  def get_orderbook_top(pair) do
    "/orderbook_top?pair=" <> pair
    |> invoke_public_api_v1()
  end

  def list_orders(pair, state) do
    "/listorders?pair=" <> pair <> "&state=" <> state
    |> invoke_private_api_v1_get()
  end

  def balance(assets) do
    "/balance?assets=" <> assets
    |> invoke_private_api_v1_get()
  end

  def post_order(pair, type, volume, price, post_only) do
    vol_str = :erlang.float_to_binary(volume, [{:decimals, 6}])
    price_str = to_string(price)
    Logger.info("Limit " <> type <> " for " <> vol_str <> " at " <> price_str)
    "/postorder?pair=" <> pair <> "&type=" <> type <> "&volume=" <> vol_str <> "&price=" <> price_str <> "&post_only=" <> post_only
    |> invoke_private_api_v1_post()
  end

  def stop_order(order_id), do: stop_order(order_id, "unknown")
  def stop_order(order_id, price) when is_binary(order_id) do
    Logger.info("Cancel limit order #{inspect order_id} at #{inspect price}")
    "/stoporder?order_id=" <> order_id
    |> invoke_private_api_v1_post()
  end
  def stop_order(order_id, price)  do
    Logger.info("No limit order #{inspect order_id} at #{inspect price}")
    {:ok, %{"success" => true}}
  end

  def list_trades(params) do
    query_str = URI.encode_query(params)
    "/listtrades?" <> query_str
    |> invoke_private_api_v1_get()
  end

  #---------------------------------------------------------------------------------------------------------------------
  # private functions
  #---------------------------------------------------------------------------------------------------------------------
  defp invoke_public_api_v1(path) do
    url = @luno_url_v1 <> path
    Logger.debug("public api v1 url: #{inspect url}")
    JsonUtils.retry_req(&HTTPoison.get/1, url)
  end

  defp invoke_private_api_v1_get(path) do
    JsonUtils.retry_req(&do_invoke_private_api_v1_get/1, path)
  end

  defp invoke_private_api_v1_post(path) do
    JsonUtils.retry_req(&do_invoke_private_api_v1_post/1, path)
  end

  defp do_invoke_private_api_v1_get(path) do
    url = @luno_url_v1 <> path
    {:ok, api_key, api_secret} = get_auth_args()
    Logger.debug("private api v1 get url: #{inspect url}")
    HTTPoison.get(
      url,
      [],
      hackney: [
        basic_auth: {api_key, api_secret}
      ]
    )
  end

  defp do_invoke_private_api_v1_post(path) do
    url = @luno_url_v1 <> path
    {:ok, api_key, api_secret} = get_auth_args()
    Logger.debug("private api v1 post url: #{inspect url}")
    HTTPoison.post(
      url,
      [],
      [],
      hackney: [
        basic_auth: {api_key, api_secret}
      ]
    )
  end

  defp get_auth_args() do
    {:ok, System.get_env("luno_api_key"), System.get_env("luno_api_secret")}
  end
end
