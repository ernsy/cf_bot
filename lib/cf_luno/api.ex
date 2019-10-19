defmodule CfLuno.Api do
  require Logger

    def get_cb_ticker(pair) do
      url =  "https://api.pro.coinbase.com/products/" <> pair <> "/ticker"
      resp = HTTPoison.get(url)
      Logger.debug("CB Response: #{inspect resp}")
      Utils.check_http_response(resp)
  end
end
