defmodule CfLuno.Api do
  require Logger

  @luno_url_v1 "https://api.mybitx.com/api/1"

  @doc """
    Coinbase is used as an oracle price
  """
  def get_cb_ticker(pair) do
    url = "https://api.pro.coinbase.com/products/" <> pair <> "/ticker"
    resp = HTTPoison.get(url)
    Logger.info("CB public api v1 url: #{inspect url}")
    JsonUtils.decode_json_response(resp)
  end

  def get_ticker(pair) do
    path = "/ticker?pair=" <> pair
    invoke_public_api_v1(path)
  end

  def get_orderbook_top(pair) do
    path = "/orderbook_top?pair=" <> pair
    invoke_public_api_v1(path)
  end

  def list_orders(pair, state) do
    path = "/listorders?pair=" <> pair <> "&state=" <> state
    invoke_private_api_v1(path)
  end

  def balance(assets) do
    path = "/balance?assets=" <> assets
    invoke_private_api_v1(path)
  end

  #---------------------------------------------------------------------------------------------------------------------
  # private functions
  #---------------------------------------------------------------------------------------------------------------------
  defp invoke_public_api_v1(path) do
    url = @luno_url_v1 <> path
    Logger.info("public api v1 url: #{inspect url}")
    JsonUtils.retry_req(&HTTPoison.get/1, url)
  end
 
  defp invoke_private_api_v1(path) do
    JsonUtils.retry_req(&do_invoke_private_api_v1/1, path)
  end

  defp do_invoke_private_api_v1(path) do
    url = @luno_url_v1 <> path
    {:ok, api_key, api_secret} = get_auth_args()
    Logger.info("private api v1 url: #{inspect url}")
    HTTPoison.get(
      url,
      [],
      hackney: [
        basic_auth: {api_key, api_secret}
      ]
    )
  end

  defp get_auth_args() do
    api_key = System.get_env("api_key")
    api_secret = System.get_env("api_secret")
    {:ok, api_key, api_secret}
  end
end
