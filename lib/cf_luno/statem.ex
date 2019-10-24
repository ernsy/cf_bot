defmodule CfLuno.Statem do
  require Logger

  use GenStateMachine

  import String, only: [to_float: 1]

  @delta_time 60000
  @dt_perc 0.01
  @ut_perc 0.005
  @stable_perc 0.001

  @timeout_action {{:timeout, :check_oracle_price}, @delta_time, :check_oracle_price}
  @limit_sell_order_action {:next_event, :internal, :limit_sell_order}
  @market_sell_order_action {:next_event, :internal, :market_sell_order}
  @cancel_order_action {:next_event, :internal, :cancel_order}

  #---------------------------------------------------------------------------------------------------------------------
  # api
  #---------------------------------------------------------------------------------------------------------------------

  def start_link(init_data) do
    GenStateMachine.start_link(__MODULE__, init_data, name: __MODULE__)
  end

  def set_btc_hodl(btc_amount) do
    GenStateMachine.cast(__MODULE__, {:set_btc_hodl, btc_amount})
  end

  #---------------------------------------------------------------------------------------------------------------------
  # callbacks
  #---------------------------------------------------------------------------------------------------------------------

  def init(_init_data) do
    {:ok, :disk_storage} = :dets.open_file(:disk_storage, [type: :set])
    btc_amount = case :dets.lookup(:disk_storage, :btc_hodl) do
      [{:btc_hodl, amount}] -> amount
      [] -> 0
    end
    oracle_price = get_oracle_price()
    new_data = %{
      :btc_hodl => btc_amount,
      :oracle_price => oracle_price,
    }
    {:ok, :wait_stable, new_data, @timeout_action}
  end

  def handle_event(:cast, {:set_btc_hodl, btc_amount}, state, data) do
    :ok = :dets.insert(:disk_storage, {:btc_hodl, btc_amount})
    Logger.debug("Set btc to hodl:#{inspect btc_amount}, state:#{inspect state}")
    {:keep_state, %{data | btc_hodl: btc_amount}}
  end

  def handle_event(
        {:timeout, :check_oracle_price},
        :check_oracle_price,
        state,
        %{
          oracle_price: old_oracle_price,
        } = data
      ) do
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
          stable: {:sell, @limit_sell_order_action},
          down_trend: {:quick_sell, @market_sell_order_action},
          up_trend: {:wait_stable, @timeout_action},
          positive: {:wait_stable, @timeout_action},
          negative: {:sell, @limit_sell_order_action}
        ]
      :sell ->
        [
          stable: {:sell, @limit_sell_order_action},
          down_trend: {:quick_sell, @market_sell_order_action},
          up_trend: {:wait_stable, @cancel_order_action},
          positive: {:sell, @limit_sell_order_action},
          negative: {:sell, @limit_sell_order_action}
        ]
      :quick_sell ->
        [
          stable: {:sell, @limit_sell_order_action},
          down_trend: {:quick_sell, @limit_sell_order_action},
          up_trend: {:wait_stable, @cancel_order_action},
          positive: {:sell, @limit_sell_order_action},
          negative: {:sell, @limit_sell_order_action}
        ]
    end
    check_delta(old_oracle_price, current_oracle_price, new_data, opt)
  end

  def handle_event(:internal, :cancel_order, :wait_stable, data) do
    Logger.warn("Cancel limit order")
    {:keep_state, data, @timeout_action}
  end

  def handle_event(:internal, :limit_sell_order, :sell, %{btc_hodl: btc_hodl}) do
    {:ok, resp} = CfLuno.Api.list_orders("XBTZAR", "PENDING")
    orders = resp["orders"]
    new_limit_vol = calc_limit_vol(btc_hodl)
    process_orders(orders, new_limit_vol, new_limit_vol)
    {:keep_state_and_data, @timeout_action}
  end

  def handle_event(:internal, :limit_sell_order, :quick_sell, %{btc_hodl: btc_hodl}) do
    {:ok, resp} = CfLuno.Api.list_orders("XBTZAR", "PENDING")
    orders = resp["orders"]
    new_limit_vol = calc_limit_vol(btc_hodl)
    process_orders(orders, 0, new_limit_vol)
    {:keep_state_and_data, @timeout_action}
  end

  def handle_event(:internal, :market_sell_order, :quick_sell, data) do
    bid_price = get_luno_price("bid")
    Logger.warn("Market order at #{inspect bid_price}")
    {:keep_state, data, @limit_sell_order_action}
  end

  def terminate(_reason, _state, _data) do
    :dets.close(:disk_storage)
  end

  #---------------------------------------------------------------------------------------------------------------------
  # helper functions
  #---------------------------------------------------------------------------------------------------------------------

  defp get_oracle_price() do
    {:ok, resp} = CfLuno.Api.get_cb_ticker("BTC-USD")
    price = resp["price"]
    {float, _rem_bin} = Float.parse(price)
    float
  end

  defp get_luno_price(type) do
    {:ok, resp} = CfLuno.Api.get_ticker("XBTZAR")
    price = resp[type]
    {i_price, _rem_bin} = Integer.parse(price)
    i_price
  end

  defp check_delta(
         old_price,
         curr_price,
         new_data,
         [
           stable: {s_state, s_action},
           down_trend: {dt_state, dt_action},
           up_trend: {ut_state, ut_action},
           positive: {p_state, p_action},
           negative: {n_state, n_action},
         ]
       ) do
    case (curr_price - old_price) / old_price  do
      change_perc when abs(change_perc) < @stable_perc ->
        {:next_state, s_state, new_data, s_action}
      change_perc when change_perc > @ut_perc ->
        {:next_state, ut_state, new_data, ut_action}
      change_perc when change_perc < -@dt_perc ->
        {:next_state, dt_state, new_data, dt_action}
      change_perc when change_perc > 0 ->
        {:next_state, p_state, new_data, p_action}
      change_perc when change_perc < 0 ->
        {:next_state, n_state, new_data, n_action}
    end
  end

  defp calc_limit_vol(btc_hodl) do
    {:ok, balances} = CfLuno.Api.balance("XBT")
    xbt_bal = hd(balances["balance"])
    to_float(xbt_bal["balance"]) + to_float(xbt_bal["unconfirmed"]) + to_float(xbt_bal["reserved"]) - btc_hodl
    |> Float.round(6)
  end

  defp process_orders(nil, before_limit_vol, new_limit_vol) do
    {:ok, new_limit_price} = calc_limit_order_price(before_limit_vol, 0, 0)
    place_order(new_limit_price, new_limit_vol)
  end
  defp process_orders(orders, before_limit_vol, new_limit_vol) when length(orders) > 1 do
    Enum.each(
      orders,
      fn (order) ->
        order_id = order["order_id"]
        Logger.debug("Cancel order id #{inspect order_id} for #{inspect order["limit_price"]}")
      end
    )
    {:ok, new_limit_price} = calc_limit_order_price(before_limit_vol, 0, 0)
    place_order(new_limit_price, new_limit_vol)
  end
  defp process_orders([order], before_limit_vol, new_limit_vol) do
    {curr_limit_price, _} = Integer.parse(order["limit_price"])
    curr_limit_vol = order["limit_volume"]
                     |> to_float()
                     |> Float.round(6)
    order_id = order["order_id"]
    {:ok, new_limit_price} = calc_limit_order_price(before_limit_vol, curr_limit_price, curr_limit_vol)
    place_order(curr_limit_price, curr_limit_vol, order_id, new_limit_price, new_limit_vol)
  end

  defp calc_limit_order_price(0, _curr_limit_price, _curr_limit_vol) do
    ask = get_luno_price("ask")
    calc_lowest_limit_order_price(ask, ask)
  end
  defp calc_limit_order_price(before_limit_vol, curr_limit_price, curr_limit_vol) do
    {:ok, book} = CfLuno.Api.get_orderbook_top("XBTZAR")
    asks = book["asks"]
    {lowest_ask, _} = hd(asks)["price"]
                      |> Integer.parse()
    Enum.reduce_while(
      asks,
      {0, curr_limit_vol},
      fn (ask, {acc_volume, curr_limit_vol}) ->
        ask_volume = to_float(ask["volume"])
        {ask_price, _rem_bin} = Integer.parse(ask["price"])
        {new_acc_volume, rem_limit_vol} =
          if curr_limit_vol > 0 and ask_price >= curr_limit_price do
            new_acc_volume = acc_volume + ask_volume - curr_limit_vol
            {new_acc_volume, 0}
          else
            new_acc_volume = acc_volume + ask_volume
            {new_acc_volume, curr_limit_vol}
          end
        if new_acc_volume > before_limit_vol do
          new_limit_order_price = calc_lowest_limit_order_price(lowest_ask, ask_price)
          {:halt, {:ok, new_limit_order_price}}
        else
          {:cont, {new_acc_volume, rem_limit_vol}}
        end
      end
    )
  end

  defp calc_lowest_limit_order_price(lowest_ask, lowest_ask) do
    bid_price = get_luno_price("bid")
    max(bid_price + 1, lowest_ask - 1)
  end
  defp calc_lowest_limit_order_price(lowest_ask, ask_price) do
    max(lowest_ask + 1, ask_price) - 1
  end

  defp place_order(new_limit_price, new_limit_vol) do
    Logger.debug("Limit sell order for #{inspect new_limit_vol} at #{inspect new_limit_price}")
  end
  defp place_order(curr_limit_price, curr_limit_vol, _order_id, new_limit_price, new_limit_vol)
       when curr_limit_price == new_limit_price do
    Logger.debug("Keep Limit sell order for #{inspect curr_limit_vol} at #{inspect curr_limit_price}")
    if new_limit_vol > curr_limit_vol do
      Logger.debug("Limit sell order for #{inspect (new_limit_vol - curr_limit_vol)} at #{inspect new_limit_price}")
    end
  end
  defp place_order(curr_limit_price, _curr_limit_vol, order_id, new_limit_price, new_limit_vol) do
    Logger.debug("Cancel limit sell order #{inspect order_id} at #{inspect curr_limit_price}")
    Logger.debug("New limit sell order for #{inspect new_limit_vol} at #{inspect new_limit_price}")
  end

end