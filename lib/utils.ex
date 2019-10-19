defmodule Utils do

  def check_http_response({:ok, %HTTPoison.Response{status_code: 200, body: json_body}}) do
    body = Jason.decode!(json_body)
    {:ok, body}
  end

end
