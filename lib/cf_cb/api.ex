defmodule CfCb.Api do
  require Logger

  @cb_uri  Application.get_env(:cf_luno, :cb_uri, "https://public.sandbox.pro.coinbase.com")

  def get_oracle_ticker(product_id) do
    url = "https://api.pro.coinbase.com/products/" <> product_id <> "/ticker"
    Logger.debug("CB public api v1 url: #{inspect url}")
    HTTPoison.get(url)
    |> JsonUtils.decode_json_response()
    #"/products/" <> product_id <> "/ticker"
    #|> invoke_public_api()
  end

  def get_ticker(product_id) do
    "/products/" <> product_id <> "/ticker"
    |> invoke_public_api()
  end

  def get_accounts() do
    "/accounts"
    |> invoke_private_api("GET")
  end

  def get_account(id) do
    "/accounts/" <> id
    |> invoke_private_api("GET")
  end

  def get_orderbook_top(product_id) do
    "/products/" <> product_id <> "/book?level=2"
    |> invoke_public_api()
  end

  def place_order(%{side: _, product_id: _} = params) do
    {:ok, body} = Jason.encode(params)
    "/orders"
    |> invoke_private_api("POST", body)
  end

  def cancel_order(order_id) do
    "/orders/" <> order_id
    |> invoke_private_api("DELETE")
  end

  def list_orders(params) do
    "/orders?" <> URI.encode_query(params)
    |> invoke_private_api("GET")
  end

  def fills(params) do
    "/fills?" <> URI.encode_query(params)
    |> invoke_private_api("GET")
  end


  #---------------------------------------------------------------------------------------------------------------------
  # private functions
  #---------------------------------------------------------------------------------------------------------------------

  defp invoke_public_api(path) do
    Logger.debug("CB public api v1 path: #{inspect path}")
    @cb_uri <> path
    |> HTTPoison.get()
  end

  defp invoke_private_api(path, method, body \\ "") do
    url = @cb_uri <> path
    headers = get_auth_headers(method, path, body)
    Logger.debug("CB private api v1 url: #{inspect url}")
    case method do
      "GET" -> HTTPoison.get(url, headers, [])
      "DELETE" -> HTTPoison.delete(url, headers, [])
      "POST" -> HTTPoison.post(url, body, headers, [])
    end
  end

  defp get_auth_headers(method, url_path, body) do
    key = System.get_env("cb_api_key")
    {:ok, secret} = System.get_env("cb_api_secret")
                    |> Base.decode64
    passphrase = System.get_env("cb_passphrase")
    ts = :os.system_time(:seconds)
    msg = "#{ts}#{method}#{url_path}#{body}"
    sign = :crypto.hmac(:sha256, secret, msg)
           |> Base.encode64(case: :lower)
    [
      {"Content-Type", "application/json"},
      {"CB-ACCESS-KEY", key},
      {"CB-ACCESS-SIGN", sign},
      {"CB-ACCESS-TIMESTAMP", ts},
      {"CB-ACCESS-PASSPHRASE", passphrase}
    ]
  end
end
