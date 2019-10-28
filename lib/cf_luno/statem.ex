defmodule CfLuno.Statem do
  require Logger

  use GenStateMachine
  alias CfLuno.StateConstants, as: Const
  import String, only: [to_float: 1]

  @dt_perc 0.002
  @ut_perc 0.002
  @stable_perc 0.0005
  @min_order_vol 0.0005

  @start_delta_time 60000
  @review_time 5000

  #---------------------------------------------------------------------------------------------------------------------
  # api
  #---------------------------------------------------------------------------------------------------------------------

  def start_link(init_data) do
    GenStateMachine.start_link(__MODULE__, init_data, name: __MODULE__)
  end

  def pause() do
    GenStateMachine.cast(__MODULE__, :pause)
  end

  def set_btc_to_sell(btc_amount) do
    GenStateMachine.cast(__MODULE__, {:set_btc_to_sell, btc_amount})
  end

  #---------------------------------------------------------------------------------------------------------------------
  # callbacks
  #---------------------------------------------------------------------------------------------------------------------

  def init(_init_data) do
    {:ok, :disk_storage} = :dets.open_file(:disk_storage, [type: :set])
    btc_amount = case :dets.lookup(:disk_storage, :btc_to_sell) do
      [{:btc_to_sell, amount}] -> amount
      [] -> 0
    end
    oracle_price = get_oracle_price()
    new_data = %{:btc_to_sell => btc_amount, :oracle_price => oracle_price, }
    {:ok, :wait_stable, new_data, {{:timeout, :check_oracle_price}, @start_delta_time, :check_oracle_price}}
  end

  def handle_event(:cast, :pause, state, %{btc_to_sell: btc_amount}) do
    Logger.info("Pausing with btc_sell amount:#{inspect btc_amount}, state:#{inspect state}")
    {
      :keep_state_and_data,
      [
        {{:timeout, :check_oracle_price}, :infinity, :check_oracle_price},
        {:state_timeout, :infinity, :limit_sell}
      ]
    }
  end

  def handle_event(:cast, {:set_btc_to_sell, btc_amount}, state, data) do
    :ok = :dets.insert(:disk_storage, {:set_btc_to_sell, btc_amount})
    Logger.info("Set btc to sell:#{inspect btc_amount}, state:#{inspect state}")
    {:keep_state, %{data | btc_to_sell: btc_amount}}
  end

  def handle_event(
        {:timeout, :check_oracle_price},
        :check_oracle_price,
        state,
        %{oracle_price: old_oracle_price} = data
      ) do
    current_oracle_price = get_oracle_price()
    new_data = %{data | oracle_price: current_oracle_price}
    transitions = case state do
      :wait_stable -> CfLuno.Transitions.wait_stable()
      state when state == :sell or state == :quick_sell -> CfLuno.Transitions.sell
      state when state == :buy or state == :quick_buy -> CfLuno.Transitions.buy
    end
    {next_state, next_action} = check_delta(old_oracle_price, current_oracle_price, transitions)
    {:next_state, next_state, new_data, next_action}
  end

  def handle_event(event_type, {:limit_sell, post_actions}, :sell, %{btc_to_sell: btc_amnt})
      when event_type == :internal or event_type == :state_timeout  do
    new_limit_vol = calc_limit_vol(btc_amnt)
    check_vol_and_process_order(new_limit_vol, new_limit_vol)
    {:keep_state_and_data, [{:state_timeout, @review_time, {:limit_sell, []}} | post_actions]}
  end

  def handle_event(event_type, {:limit_sell, post_actions}, :quick_sell, %{btc_to_sell: btc_amnt})
      when event_type == :internal or event_type == :state_timeout do
    new_limit_vol = calc_limit_vol(btc_amnt)
    check_vol_and_process_order(0, new_limit_vol)
    {:keep_state_and_data, [{:state_timeout, @review_time, {:limit_sell, []}} | post_actions]}
  end

  def handle_event(:internal, :cancel_orders, _state, _data) do
    {:ok, resp} = CfLuno.Api.list_orders("XBTZAR", "PENDING")
    cancel_orders(resp["orders"])
    :keep_state_and_data
  end

  def handle_event(:info, {:ssl_closed, _}, _state, _data) do
    :keep_state_and_data
  end

  def handle_event(event_type, event_content, state, _data) do
    Logger.warn("Unhandled event:#{inspect [type: event_type, content: event_content, state: state]}")
    :keep_state_and_data
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

  defp check_delta(old_price, curr_price, opts) do
    delta_perc = (curr_price - old_price) / old_price
    Logger.info("Delta perc:#{inspect Float.round(delta_perc, 4)}")
    {next_state, next_action} = case delta_perc do
      change_perc when abs(change_perc) < @stable_perc -> opts.only_btc.stable
      change_perc when change_perc > @ut_perc -> opts.only_btc.up_trend
      change_perc when change_perc < -@dt_perc -> opts.only_btc.down_trend
      change_perc when change_perc > 0 -> opts.only_btc.positive
      change_perc when change_perc < 0 -> opts.only_btc.negative
    end
  end

  defp calc_limit_vol(btc_amnt) do
    btc_amnt
  end

  defp check_vol_and_process_order(before_limit_vol, new_limit_vol) when new_limit_vol >= @min_order_vol do
    {:ok, resp} = CfLuno.Api.list_orders("XBTZAR", "PENDING")
    resp["orders"]
    |> process_orders(before_limit_vol, new_limit_vol)
  end
  defp check_vol_and_process_order(_before_limit_vol, _new_limit_vol) do
    ask_price = get_luno_price("ask")
    Logger.info("Current Luno ask price:#{inspect ask_price}")
    {:ok, "volume to sell below minimum order volume"}
  end

  defp process_orders(nil, before_limit_vol, new_limit_vol) do
    {:ok, new_limit_price} = calc_limit_order_price(before_limit_vol, 0, 0)
    place_order(new_limit_price, new_limit_vol)
  end
  defp process_orders(orders, before_limit_vol, new_limit_vol) when length(orders) > 1 do
    cancel_orders(orders)
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
    {:ok, calc_lowest_limit_order_price(ask, ask)}
  end
  defp calc_limit_order_price(before_limit_vol, curr_limit_price, curr_limit_vol) do
    {:ok, book} = CfLuno.Api.get_orderbook_top("XBTZAR")
    asks = book["asks"]
    lowest_ask = hd(asks)
    {lowest_ask_price, _} = Integer.parse(lowest_ask["price"])
    Logger.info("Lowest ask price:#{inspect lowest_ask_price}, volume#{inspect lowest_ask["volume"]}")
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
          new_limit_order_price = calc_lowest_limit_order_price(lowest_ask_price, ask_price)
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
    vol_str = :erlang.float_to_binary(new_limit_vol, [{:decimals, 6}])
    {:ok, %{}} = CfLuno.Api.post_order("XBTZAR", "ASK", vol_str, to_string(new_limit_price), "true")
    Logger.info("Placed limit sell order for #{inspect vol_str} at #{inspect new_limit_price}")
  end
  defp place_order(curr_limit_price, curr_limit_vol, order_id, new_limit_price, new_limit_vol)
       when curr_limit_price == new_limit_price do
    Logger.info(
      "Keep Limit sell order #{inspect order_id} for #{inspect curr_limit_vol} at #{inspect curr_limit_price}"
    )
    if new_limit_vol > curr_limit_vol do
      vol_str = :erlang.float_to_binary((new_limit_vol - curr_limit_vol), [{:decimals, 6}])
      {:ok, %{}} = CfLuno.Api.post_order("XBTZAR", "ASK", vol_str, to_string(new_limit_price), "true")
      Logger.info(
        "Placed limit sell order for #{inspect vol_str} at #{inspect new_limit_price}"
      )
    end
  end
  defp place_order(curr_limit_price, _curr_limit_vol, order_id, new_limit_price, new_limit_vol) do
    {:ok, %{"success" => true}} = CfLuno.Api.stop_order(order_id)
    Logger.info("Cancelled limit sell order #{inspect order_id} at #{inspect curr_limit_price}")
    vol_str = :erlang.float_to_binary(new_limit_vol, [{:decimals, 6}])
    Process.sleep(250)
    {:ok, %{}} = CfLuno.Api.post_order("XBTZAR", "ASK", vol_str, to_string(new_limit_price), "true")
    Logger.info("Placed limit sell order for #{inspect vol_str} at #{inspect new_limit_price}")
  end

  def cancel_orders(nil) do
    :ok
  end
  def cancel_orders(orders) do
    Enum.each(
      orders,
      fn (order) ->
        order_id = order["order_id"]
        {:ok, %{"success" => true}} = CfLuno.Api.stop_order(order_id)
        Logger.info("Cancelled order id #{inspect order_id} for #{inspect order["limit_price"]}")
      end
    )
  end

end