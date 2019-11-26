defmodule CfValr.Api do
  require Logger

  @valr_uri "https://api.valr.com"

  #---------------------------------------------------------------------------------------------------------------------
  # API
  #---------------------------------------------------------------------------------------------------------------------
  def get_ticker(pair) do
    "/v1/public/" <> pair <> "/marketsummary"
    |> invoke_public_api()
  end

  def balances() do
    "/v1/account/balances"
    |> invoke_private_api("GET")
  end

  def get_orderbook_top(pair) do
    "/v1/marketdata/" <> pair <> "/orderbook"
    |> invoke_private_api("GET")
  end

  def post_limit_order(%{side: _, quantity: _, price: _, pair: _} = params) do
    {:ok, body} = Jason.encode(params)
    "/v1/orders/limit/"
    |> invoke_private_api("POST", body)
  end

  def delete_order(%{"orderId" => _, "pair" => _} = params) do
    {:ok, body} = Jason.encode(params)
    "/v1/orders/order/"
    |> invoke_private_api("DELETE", body)
  end

    def list_orders() do
    "/v1/orders/open"
    |> invoke_private_api("GET")
  end

  def get_trade_history(pair, limit) do
    "/v1/account/" <> pair <> "/tradehistory?limit=" <> limit
    |> invoke_private_api("GET")
  end

  #---------------------------------------------------------------------------------------------------------------------
  # private functions
  #---------------------------------------------------------------------------------------------------------------------

  defp invoke_public_api(path) do
    Logger.debug("Luno public api path: #{inspect path}")
    @valr_uri <> path
    |> HTTPoison.get()
  end


  defp invoke_private_api(path, method, body \\ "") do
    url = @valr_uri <> path
    headers = get_auth_headers(method, path, body)
    Logger.debug("CB private api v1 url: #{inspect url}")
    case method do
      "GET" -> HTTPoison.get(url, headers)
      "DELETE" -> HTTPoison.request(:delete, url, body, headers)
      "POST" -> HTTPoison.post(url, body, headers)
    end
  end

  def get_auth_headers(method, url_path, body) do
    key = System.get_env("valr_api_key")
    secret = System.get_env("valr_api_secret")
    ts = :os.system_time(:milli_seconds)
    msg = "#{ts}#{method}#{url_path}#{body}"
    sign = :crypto.hmac(:sha512, secret, msg)
           |> Base.encode16(case: :lower)
    [
      {"X-VALR-API-KEY", key},
      {"X-VALR-SIGNATURE", sign},
      {"X-VALR-TIMESTAMP", ts}
    ]
  end
end