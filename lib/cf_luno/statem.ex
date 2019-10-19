defmodule CfLuno.Statem do
  @moduledoc false
  require Logger

  use GenStateMachine, callback_mode: :state_functions

  @delta_time 60000
  @thresh_perc 0.01

  # Callbacks

  def init(_init_data) do
    oracle_price = get_oracle_price()
    new_data = %{
      :oracle_price => oracle_price,
      :mode => :sell
    }
    {:ok, :wait_stable, new_data, {:timeout, @delta_time, :check_oracle_price}}
  end

  def wait_stable(:timeout, :check_oracle_price, %{oracle_price: old_oracle_price, mode: :sell} = data) do
    current_oracle_price = get_oracle_price()
    new_data = %{data | oracle_price: current_oracle_price}
    case (current_oracle_price - old_oracle_price) / old_oracle_price < -@thresh_perc do
      change_perc when change_perc < -@thresh_perc ->
        {:next_state, :market_sell, new_data, {:next_event, :place_market_sell_order, []}}
      change_perc when change_perc > @thresh_perc ->
        {:next_state, :wait_stable, new_data, {:timeout, @delta_time, :check_oracle_price}}
      _ -> {:next_state, :limit_sell, new_data, {:next_event, :place_limit_sell_order, []}}
    end
  end

  def limit_sell(:place_limit_sell_order, _, data) do
    Logger.debug("Limit Sell Order")
    {:keep_state, data, {:timeout, @delta_time, :check_oracle_price}}
  end

  # helpers

  defp get_oracle_price() do
    {:ok, resp} = CfLuno.Api.get_cb_ticker("BTC-USD")
    price = resp["price"]
    String.to_float(price)
  end

end