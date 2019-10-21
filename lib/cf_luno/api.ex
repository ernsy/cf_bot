defmodule CfLuno.Api do
  require Logger

  @doc """
  Coinbase is used as an oracle price
"""
    def get_cb_ticker(pair) do
      url =  "https://api.pro.coinbase.com/products/" <> pair <> "/ticker"
      resp = HTTPoison.get(url)
      #Logger.debug("CB Response: #{inspect resp}")
      Utils.decode_json_response(resp)
  end

  def get_ticker(pair) do
    url = "https://api.mybitx.com/api/1/ticker?pair=" <> pair
    resp = HTTPoison.get(url)
    Utils.decode_json_response(resp)
  end
end
