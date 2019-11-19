defmodule CfLuno.Api do
  require Logger

  @luno_url_v1 "https://api.mybitx.com/api/1"

  #---------------------------------------------------------------------------------------------------------------------
  # Mock api
  #---------------------------------------------------------------------------------------------------------------------

  def post_order(params) do
    path = "/postorder?" <> URI.encode_query(params)
    Logger.debug("Mock post order url: #{inspect path}")
    {:ok, %{"order_id" => "TestOrderID"}}
  end

  def stop_order(order_id) do
    path = "/stoporder?order_id=" <> order_id
    Logger.debug("mock stop order url: #{inspect path}")
    {:ok, %{"success" => true}}
  end

  def list_trades(_params) do
    {:ok, %{"trades" => [%{"type" => "ASK", "volume" => "0.0005"}, %{"type" => "BID", "volume" => "0.0005"}]}}
  end

  #---------------------------------------------------------------------------------------------------------------------
  # API
  #---------------------------------------------------------------------------------------------------------------------
  @doc """
    Coinbase is used as an oracle price
  """

  def get_ticker(pair) do
    "/ticker?pair=" <> pair
    |> invoke_public_api_v1()
  end

  def balance(assets) do
    "/balance?assets=" <> assets
    |> invoke_private_api_v1_get()
  end

  def get_orderbook_top(pair) do
    "/orderbook_top?pair=" <> pair
    |> invoke_public_api_v1()
  end

  def post_order(params) do
    "/postorder?" <> URI.encode_query(params)
    |> invoke_private_api_v1_post()
  end

  def stop_order(order_id) do
    "/stoporder?order_id=" <> order_id
    |> invoke_private_api_v1_post()
  end

  def list_orders(params) do
    "/listorders?" <> URI.encode_query(params)
    |> invoke_private_api_v1_get()
  end

  def list_trades(params) do
    "/listtrades?" <> URI.encode_query(params)
    |> invoke_private_api_v1_get()
  end

  #---------------------------------------------------------------------------------------------------------------------
  # private functions
  #---------------------------------------------------------------------------------------------------------------------
  defp invoke_public_api_v1(path) do
    url = @luno_url_v1 <> path
    Logger.debug("public api v1 url: #{inspect url}")
    JsonUtils.retry_req(&HTTPoison.get/1, [url])
  end

  defp invoke_private_api_v1_get(path) do
    JsonUtils.retry_req(&do_invoke_private_api_v1_get/1, [path])
  end

  defp invoke_private_api_v1_post(path) do
    JsonUtils.retry_req(&do_invoke_private_api_v1_post/1, [path])
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
