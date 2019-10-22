defmodule JsonUtils do
  require Logger

  @max_req_per_minute 60
  @retry_count (60 / @max_req_per_minute)

  def retry_req(req_fun, params, retry_count \\ @retry_count)
  def retry_req(req_fun, params, 1) do
    http_resp = req_fun.(params)
    decode_json_response(http_resp)
  end
  def retry_req(req_fun, params, retry_count) do
    http_resp = req_fun.(params)
    case decode_json_response(http_resp) do
      {:error, {429, _body}} ->
        Process.sleep(round(60000 / @max_req_per_minute))
        retry_req(req_fun, params, retry_count - 1)
      response -> response
    end
  end

    def decode_json_response({:ok, %HTTPoison.Response{status_code: 200, body: json_body}}) do
    body = Jason.decode!(json_body)
    Logger.info("Json Response: {200, #{inspect body}}")
    {:ok, body}
  end
  def decode_json_response({:ok, %HTTPoison.Response{status_code: status_code, body: json_body}}) do
    body = Jason.decode!(json_body)
    Logger.warn("Response: {#{inspect status_code}, #{inspect body}}")
    {:error, {status_code, body}}
  end
  def decode_json_response(error) do
    Logger.error(error)
    error
  end

end
