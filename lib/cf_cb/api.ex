defmodule CfCb.Api do
  require Logger
  
  @cb_uri "https://api-public.sandbox.pro.coinbase.com"

  def get_cb_ticker(pair) do
    "/products/" <> pair <> "/ticker"
    |> invoke_public_api()
  end

  def get_accounts() do
    "/accounts"
    |> invoke_private_api_get()
  end

  def get_accounts(order_id) do
  {:ok, accounts} = invoke_private_api_get("/accounts")
  Enum.find(accounts, fn (%{"id" => id} = account) when id == order_id -> account end)
  end

  def get_account(id) do
    "/accounts/" <> id
    |> invoke_private_api_get()
  end

  def list_orders(params) do
    "/orders?" <> URI.encode_query(params)
    |> invoke_private_api_get()
  end

  def fills(params) do
    "/fills?" <> URI.encode_query(params)
    |> invoke_private_api_get()
  end


  #---------------------------------------------------------------------------------------------------------------------
  # private functions
  #---------------------------------------------------------------------------------------------------------------------

  defp invoke_public_api(path) do
    url = @cb_uri <> path
    Logger.debug("public api v1 url: #{inspect url}")
    JsonUtils.retry_req(&HTTPoison.get/1, url)
  end

  defp invoke_private_api_get(path) do
    JsonUtils.retry_req(&do_invoke_private_api_get/1, path)
  end
  defp do_invoke_private_api_get(path) do
    url = @cb_uri <> path
    headers = get_auth_headers("GET", path)
    Logger.debug("private api v1 get url: #{inspect url}")
    HTTPoison.get(url, headers, [])
  end

  defp get_auth_headers(method, url_path, body \\ "") do
    key = System.get_env("cb_api_key")
    {:ok, secret} = System.get_env("cb_api_secret")
                    |> Base.decode64
    passphrase = System.get_env("cb_passphrase")
    ts = :os.system_time(:seconds)
    msg = "#{ts}#{method}#{url_path}#{body}"
    sign = :crypto.hmac(:sha256, secret, msg)
           |> Base.encode64(case: :lower)
           |> IO.inspect
    [
      {"Content-Type", "application/json"},
      {"CB-ACCESS-KEY", key},
      {"CB-ACCESS-SIGN", sign},
      {"CB-ACCESS-TIMESTAMP", ts},
      {"CB-ACCESS-PASSPHRASE", passphrase}
    ]
  end
end
