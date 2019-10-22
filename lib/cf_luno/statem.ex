defmodule CfLuno.Statem do
  require Logger

  use GenStateMachine

  @delta_time 60000
  @dt_perc 0.01
  @ut_perc 0.005
  @stable_perc 0.001
  @timeout_action {:timeout, @delta_time, :check_oracle_price}
  @limit_sell_order_action {:next_event, :internal, :limit_sell_order}
  @market_sell_order_action {:next_event, :internal, :market_sell_order}
  @cancel_order_action {:next_event, :internal, :cancel_order}

  def start_link(init_data) do
    GenStateMachine.start_link(__MODULE__, init_data, name: __MODULE__)
  end

  def set_btc_to_sell(btc_amount) do
    GenStateMachine.cast(__MODULE__, {:set_btc_to_sell, btc_amount})
  end

  # Callbacks

  def init(_init_data) do
    {:ok, :disk_storage} = :dets.open_file(:disk_storage, [type: :set])
    btc_amount = case :dets.lookup(:disk_storage, :btc_to_sell) do
      [{:btc_to_sell, amount}] -> amount
      [] -> 0
    end
    oracle_price = get_oracle_price()
    new_data = %{
      :btc_to_sell => btc_amount,
      :oracle_price => oracle_price,
      :mode => :sell
    }
    {:ok, :wait_stable, new_data, @timeout_action}
  end

  def handle_event(:cast, {:set_btc_to_sell, btc_amount}, state, data) do
    :ok = :dets.insert(:disk_storage, {:btc_to_sell, btc_amount})
    Logger.debug("Set btc to sell:#{inspect btc_amount}, state:#{inspect state}")
    {:keep_state, %{data | btc_to_sell: btc_amount}}
  end

  def handle_event(:timeout, :check_oracle_price, state, %{oracle_price: old_oracle_price} = data) do
    current_oracle_price = get_oracle_price()
    Logger.debug(
      "Check oracle price state: #{inspect state}
      old_price:  #{inspect old_oracle_price}
      curr_price: #{inspect current_oracle_price}
      date:       #{inspect {:erlang.date, :erlang.time}}"
    )
    new_data = %{data | oracle_price: current_oracle_price}
    opt = case state do
      :wait_stable ->
        [
          stable: {:sell_order, @limit_sell_order_action},
          down_trend: {:sell_order, @market_sell_order_action},
          up_trend: {:wait_stable, @timeout_action},
          default: {:wait_stable, @timeout_action}
        ]
      :sell_order ->
        [
          stable: {:sell_order, @limit_sell_order_action},
          down_trend: {:sell_order, @market_sell_order_action},
          up_trend: {:wait_stable, @cancel_order_action},
          default: {:sell_order, @limit_sell_order_action}
        ]
    end
    check_delta(old_oracle_price, current_oracle_price, new_data, opt)
  end

  def handle_event(:internal, :cancel_order, :wait_stable, data) do
    Logger.warn("Cancel limit order")
    {:keep_state, data, @timeout_action}
  end

  def handle_event(:internal, :limit_sell_order, :sell_order, data) do
    ask_price = get_luno_price("ask")
    # get current orders
    # cancel and place order if one doesn't exist at price, if volume below > x*btc_sell_amount
    Logger.debug("Limit sell order at #{inspect ask_price}")
    {:keep_state, data, @timeout_action}
  end

  def handle_event(:internal, :market_sell_order, :sell_order, data) do
    bid_price = get_luno_price("bid")
    Logger.warn("Limit market order at #{inspect bid_price}")
    {:keep_state, data, @timeout_action}
  end

  # helpers

  defp get_oracle_price() do
    {:ok, resp} = CfLuno.Api.get_cb_ticker("BTC-USD")
    price = resp["price"]
    {float, _rem_bin} = Float.parse(price)
    float
  end

  defp get_luno_price(type) do
    {:ok, resp} = CfLuno.Api.get_ticker("XBTZAR")
    price = resp[type]
    {float, _rem_bin} = Float.parse(price)
    float
  end

  defp check_delta(
         old_price,
         curr_price,
         new_data,
         [
           stable: {s_state, s_action},
           down_trend: {dt_state, dt_action},
           up_trend: {ut_state, ut_action},
           default: {d_state, d_action}
         ]
       ) do
    case (curr_price - old_price) / old_price  do
      change_perc when abs(change_perc) < @stable_perc ->
        {:next_state, s_state, new_data, s_action}
      change_perc when change_perc < -@dt_perc ->
        {:next_state, dt_state, new_data, dt_action}
      change_perc when change_perc > @ut_perc ->
        {:next_state, ut_state, new_data, ut_action}
      _ -> {:next_state, d_state, new_data, d_action}
    end
  end

end