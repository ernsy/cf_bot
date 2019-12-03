defmodule CfValr.WsClient do
  use WebSockex

  @url "wss://api.valr.com/ws/account"

  def start_link([cb_fun]) do
    auth_headers = CfValr.Api.get_auth_headers("GET", "/ws/account", "")
    {:ok, pid} = WebSockex.start_link(@url, __MODULE__, %{cb_fun: cb_fun}, [extra_headers: auth_headers])
    {:ok, pid}
  end

  def handle_frame({:text, body}, %{cb_fun: cb_fun} = state) do
    Jason.decode!(body)
    |> cb_fun.handle_ws_msg(state)
  end

end