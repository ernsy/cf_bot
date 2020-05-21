defmodule JsonUtils do
  require Logger

  @sleep_time 1000
  @retry_count 3

  def retry_req(req_fun, params, back_off_time \\ nil, retry_count \\ @retry_count)
  def retry_req(req_fun, params, _back_off_time, 1) do
    apply(req_fun, params)
    |> decode_json_response()
  end
  def retry_req(req_fun, params, back_off_time, retry_count) do
    http_resp = apply(req_fun, params)
    case decode_json_response(http_resp) do
      {:error, {429, body}} ->
        sleep_and_retry(req_fun, params, back_off_time, retry_count)
      {:error, {code, body}} when code == 500 or code == 404->
        sleep_and_retry(req_fun, params, nil, retry_count)
      {:error, %HTTPoison.Error{id: nil, reason: reason}} when reason == :closed or reason == :timeout ->
        sleep_and_retry(req_fun, params, nil, retry_count)
      response ->
        response
    end
  end

  defp sleep_and_retry(req_fun, params, back_off_time, retry_count)  do
    sleep_time = back_off_time || @sleep_time
    Process.sleep(sleep_time)
    retry_req(req_fun, params, back_off_time, retry_count - 1)
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


  def convert_date_time(dt_str) do
    {:ok, dt, 0} = DateTime.from_iso8601(dt_str)
    DateTime.to_unix(dt)
  end

end
