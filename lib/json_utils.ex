defmodule JsonUtils do
  require Logger

  @sleep_time 1000
  @retry_count 3

  def retry_req(req_fun, params, retry_count \\ @retry_count)
  def retry_req(req_fun, params, 1) do
    apply(req_fun, params)
    |> decode_json_response()
  end
  def retry_req(req_fun, params, retry_count) do
    http_resp = apply(req_fun, params)
    case decode_json_response(http_resp) do
      {:error, {status_code, body}} when status_code == 429 or status_code == 500 ->
        Logger.warn("Response: {#{inspect status_code}, #{inspect body}}")
        sleep_and_retry(req_fun, params, retry_count)
      {:error, %HTTPoison.Error{id: nil, reason: reason}} when reason == :closed or :timeout ->
        sleep_and_retry(req_fun, params, retry_count)
      response ->
        response
    end
  end

  defp sleep_and_retry(req_fun, params, retry_count)  do
    Process.sleep(round(@sleep_time))
    retry_req(req_fun, params, retry_count - 1)
  end

  def decode_json_response({:ok, %HTTPoison.Response{status_code: code, body: json_body}})
      when code == 200 or code == 202 do
    body = if String.length(json_body) > 0, do: Jason.decode!(json_body), else: json_body
    Logger.debug("Json Response: #{code}, #{inspect body}}")
    {:ok, body}
  end
  def decode_json_response({:ok, %HTTPoison.Response{status_code: status_code, body: body}}) do
    Logger.warn("Response: {#{inspect status_code}, #{inspect body}}")
    {:error, {status_code, body}}
  end
  def decode_json_response(error) do
    Logger.error("#{inspect error}")
    error
  end

end
