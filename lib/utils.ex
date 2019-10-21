defmodule Utils do
  require Logger

  def decode_json_response({:ok, %HTTPoison.Response{status_code: 200, body: json_body}}) do
    body = Jason.decode!(json_body)
    {:ok, body}
  end
  def decode_json_response({:ok, %HTTPoison.Response{status_code: status_code, body: json_body}}) do
    body = Jason.decode!(json_body)
    Logger.warn("Response: {#{inspect status_code}, #{inspect body}}")
    {:error, {status_code, body}}
  end
  def decode_json_response(error) do
    error
  end

end
