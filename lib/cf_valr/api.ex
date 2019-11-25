defmodule CfValr.Api do
  require Logger

  @valr_uri "https://api.valr.com/api/v1"

  #---------------------------------------------------------------------------------------------------------------------
  # API
  #---------------------------------------------------------------------------------------------------------------------
  def get_ticker(pair) do
    "/public/" <> pair <> "/marketsummary"
    |> invoke_public_api()
  end

  def balance(assets) do
    "/balance?assets=" <> assets
    |> invoke_private_api("GET")
  end

  def get_orderbook_top(pair) do
    "/orderbook_top?pair=" <> pair
    |> invoke_public_api()
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


  defp invoke_private_api(path, method) do
    url = @valr_uri <> path
    {:ok, api_key, api_secret} = get_auth_args()
    Logger.debug("Luno private api path: #{inspect url}")
    case method do
      "GET" ->
        HTTPoison.get(
          url,
          [],
          hackney: [
            basic_auth: {api_key, api_secret}
          ]
        )
      "POST" ->
        HTTPoison.post(
          url,
          [],
          [],
          hackney: [
            basic_auth: {api_key, api_secret}
          ]
        )
    end
  end

  defp get_auth_args() do
    {:ok, System.get_env("luno_api_key"), System.get_env("luno_api_secret")}
  end
end

