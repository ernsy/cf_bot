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

  def post_order(params) do
    "/postorder?" <> URI.encode_query(params)
    |> invoke_private_api("POST")
  end

  def stop_order(order_id) do
    "/stoporder?order_id=" <> order_id
    |> invoke_private_api("POST")
  end

  def list_orders(params) do
    "/listorders?" <> URI.encode_query(params)
    |> invoke_private_api("GET")
  end

  def list_trades(params) do
    "/listtrades?" <> URI.encode_query(params)
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
      "GET" -> HTTPoison.get(url, headers, [])
      "DELETE" -> HTTPoison.delete(url, headers, [])
      "POST" -> HTTPoison.post(url, body, headers, [])
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

#curl --location --request GET "https://api.valr.com/v1/account/balances" --header "X-VALR-API-KEY: 7d1814b386d17fc48aaa95032aaf54f08ef6de4dcc24f79d61a0b2a72aa11a7d" --header "X-VALR-SIGNATURE: 5a58816c3cb149bc900f4f274d2de1809764ab22126ff635c06bd1f222e77fa22750de9057fd4d15dd1cec26c6e451ac13091ce7bd9007cc045315461146cfcc" --header "X-VALR-TIMESTAMP: 1574786805119"
