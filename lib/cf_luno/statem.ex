defmodule CfLuno.Statem do
  require Logger

  use GenStateMachine
  alias CfLuno.Transitions, as: Transitions
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

  def set_btc_to_sell_amt(btc_amount) do
    GenStateMachine.cast(__MODULE__, {:set_btc_sell_amt, btc_amount})
  end

  def set_btc_hodl_amt(btc_amount) do
    GenStateMachine.cast(__MODULE__, {:set_btc_hodl_amt, btc_amount})
  end

  #---------------------------------------------------------------------------------------------------------------------
  # callbacks
  #---------------------------------------------------------------------------------------------------------------------

  def init(_init_data) do
    {:ok, :disk_storage} = :dets.open_file(:disk_storage, [type: :set])
    data = case :dets.lookup(:disk_storage, :data) do
      %{} = data -> data
      _ -> %{btc_sell_amt: 0, btc_hodl_amt: 0}
    end
    oracle_price = get_oracle_price()
    new_data = Map.put(data, :oracle_price, oracle_price)
    {:ok, :wait_stable, new_data, {{:timeout, :check_oracle_price}, @start_delta_time, :check_oracle_price}}
  end

  def handle_event(:cast, :pause, state, %{btc_sell: btc_vol}) do
    Logger.info("Pausing with btc_sell amount:#{inspect btc_vol}, state:#{inspect state}")
    {
      :keep_state_and_data,
      [
        {{:timeout, :check_oracle_price}, :infinity, :check_oracle_price},
        {:state_timeout, :infinity, :limit_sell}
      ]
    }
  end

  def handle_event(:cast, {:set_btc_sell_amt, btc_vol}, state, data) do
    Logger.info("Set btc to sell:#{inspect btc_vol}, state:#{inspect state}")
    new_data = %{data | btc_sell_amt: btc_vol}
    :ok = :dets.insert(:disk_storage, {:data, new_data})
    {:keep_state, new_data}
  end

  def handle_event(:cast, {:set_btc_hodl_amt, btc_vol}, state, data) do
    Logger.info("Set btc to hodl:#{inspect btc_vol}, state:#{inspect state}")
    new_data = %{data | btc_hodl_amt: btc_vol}
    :ok = :dets.insert(:disk_storage, {:data, new_data})
    {:keep_state, new_data}
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
      :wait_stable -> Transitions.wait_stable()
      state when state == :sell or state == :quick_sell -> Transitions.sell()
      state when state == :buy or state == :quick_buy -> Transitions.buy()
    end
    {next_state, next_action} = check_delta(old_oracle_price, current_oracle_price, transitions)
    {:next_state, next_state, new_data, next_action}
  end

  def handle_event(
        event_type,
        {:limit_sell, post_actions},
        :sell,
        %{
          btc_sell_amt: sell_amt,
          btc_hodl_amt: hodl_amt,
          curr_order_time: curr_order_time,
        } = data
      )
      when sell_amt > @min_order_vol and (event_type == :internal or event_type == :state_timeout)  do
    {:ok, resp} = CfLuno.Api.list_orders("XBTZAR", "PENDING")
    orders = resp["orders"]
    {:ok, [curr_price, curr_vol, order_id, new_price]} = process_orders(orders, sell_amt)
    bal = get_btc_bal()
    new_data =
      case place_limit_order(curr_price, curr_vol, order_id, curr_order_time, new_price, sell_amt, hodl_amt, bal) do
        {:ok, [order_time, amt]} when order_time == curr_order_time and amt == sell_amt -> data
        {:ok, [new_order_time, new_sell_amt]} ->
          new_data = %{data | last_order_time: new_order_time, btc_sell_amt: new_sell_amt}
          :ok = :dets.insert(:disk_storage, {:data, new_data})
          new_data
      end
    {:keep_state, new_data, [{:state_timeout, @review_time, {:limit_sell, []}} | post_actions]}
  end

  def handle_event(
        event_type,
        {:limit_sell, post_actions},
        :quick_sell,
        %{
          btc_sell_amt: sell_amt,
          btc_hodl_amt: hodl_amt,
          last_order_time: curr_order_time,
        } = data
      )
      when sell_amt > @min_order_vol and (event_type == :internal or event_type == :state_timeout) do
    {:ok, resp} = CfLuno.Api.list_orders("XBTZAR", "PENDING")
    orders = resp["orders"]
    {:ok, [curr_price, curr_vol, order_id, new_price]} = process_orders(orders, 0)
    bal = get_btc_bal()
    new_data =
      case place_limit_order(curr_price, curr_vol, order_id, curr_order_time, new_price, sell_amt, hodl_amt, bal) do
        {:ok, [order_time, amt]} when order_time == curr_order_time and amt == sell_amt -> data
        {:ok, [new_order_time, new_sell_amt]} ->
          new_data = %{data | last_order_time: new_order_time, btc_sell_amt: new_sell_amt}
          :ok = :dets.insert(:disk_storage, {:data, new_data})
          new_data
      end
    {:keep_state, new_data, [{:state_timeout, @review_time, {:limit_sell, []}} | post_actions]}
  end

  def handle_event(:internal, :cancel_orders, _state, _data) do
    {:ok, resp} = CfLuno.Api.list_orders("XBTZAR", "PENDING")
    {:ok, %{"success" => true}} = cancel_orders(resp["orders"])
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

  defp get_btc_bal() do
    {:ok, balances} = CfLuno.Api.balance("XBT")
    xbt_balances = hd(balances["balance"])
    avail_bal = to_float(xbt_balances["balance"])
    unconf_bal = to_float(xbt_balances["unconfirmed"])
    avail_bal + unconf_bal
  end

  defp check_delta(old_price, curr_price, opts) do
    delta_perc = (curr_price - old_price) / old_price
    Logger.info("Delta perc:#{inspect Float.round(delta_perc, 4)}")
    case delta_perc do
      change_perc when abs(change_perc) < @stable_perc -> opts.only_btc.stable
      change_perc when change_perc > @ut_perc -> opts.only_btc.up_trend
      change_perc when change_perc < -@dt_perc -> opts.only_btc.down_trend
      change_perc when change_perc > 0 -> opts.only_btc.positive
      change_perc when change_perc < 0 -> opts.only_btc.negative
    end
  end

  defp process_orders(nil, before_limit_vol) do
    {:ok, new_price} = calc_limit_order_price(before_limit_vol, 0, 0)
    {}
    {:ok, [0, 0, 0, new_price]}
  end
  defp process_orders(orders, before_limit_vol) when length(orders) > 1 do
    {:ok, %{"success" => true}} = cancel_orders(orders)
    {:ok, new_price} = calc_limit_order_price(before_limit_vol, 0, 0)
    {:ok, [0, 0, 0, new_price]}
  end
  defp process_orders([order], before_limit_vol) do
    {curr_price, _} = Integer.parse(order["limit_price"])
    curr_vol = order["limit_volume"]
               |> to_float()
               |> Float.round(6)
    order_id = order["order_id"]
    {:ok, new_price} = calc_limit_order_price(before_limit_vol, curr_price, curr_vol)
    {:ok, [curr_price, curr_vol, order_id, new_price]}
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

  defp place_limit_order(curr_price, curr_vol, order_id, curr_order_time, new_price, sell_amt, hodl_amt, avail_bal)
       when avail_bal > hodl_amt + @min_order_vol do
    place_limit_order(curr_price, curr_vol, order_id, curr_order_time, new_price, sell_amt)
  end
  defp place_limit_order(_, _, _, curr_order_time, _, sell_amt, _, _) do
    {:ok, curr_order_time, sell_amt}
  end

  defp place_limit_order(0, 0, 0, curr_order_time, new_price, new_vol)
    do
    new_vol_str = :erlang.float_to_binary(new_vol, [{:decimals, 6}])
    new_price_str = to_string(new_price)
    Logger.info("Limit sell order for #{inspect new_vol_str} at #{inspect new_price_str}")
    new_order_time = :erlang.system_time(:millisecond)
    {:ok, %{"order_id" => _new_order_id}} = CfLuno.Api.post_order("XBTZAR", "ASK", new_vol_str, new_price_str, "true")
    {:ok, new_order_time, new_vol}
  end
  defp place_limit_order(curr_price, curr_vol, order_id, curr_order_time, new_price, new_vol)
       when curr_price == new_price do
    Logger.info("Keep Limit sell order #{inspect order_id} for #{inspect curr_vol} at #{inspect curr_price}")
    if new_vol > curr_vol do
      new_vol_str = :erlang.float_to_binary((new_vol - curr_vol), [{:decimals, 6}])
      new_price_str = to_string(new_price)
      Logger.info("Limit sell order for #{inspect new_vol_str} at #{inspect new_price_str}")
      {:ok, %{"order_id" => _new_order_id}} = CfLuno.Api.post_order("XBTZAR", "ASK", new_vol_str, new_price_str, "true")
    end
    {:ok, curr_order_time}
  end
  defp place_limit_order(curr_price, _curr_vol, order_id, curr_order_time, new_price, new_vol) do
    Logger.info("Cancel limit sell order #{inspect order_id} at #{inspect curr_price}")
    {:ok, %{"success" => true}} = CfLuno.Api.stop_order(order_id)
    Process.sleep(250)
    new_vol_str = :erlang.float_to_binary(new_vol, [{:decimals, 6}])
    new_price_str = to_string(new_price)
    Logger.info("Limit sell order for #{inspect new_vol_str} at #{inspect new_price_str}")
    new_order_time = :erlang.system_time(:millisecond)
    {:ok, %{"order_id" => _new_order_id}} = CfLuno.Api.post_order("XBTZAR", "ASK", new_vol_str, new_price_str, "true")
    {:ok, new_order_time}
  end

  def cancel_orders(nil) do
    :ok
  end
  def cancel_orders(orders) do
    Enum.each(
      orders,
      fn (order) ->
        order_id = order["order_id"]
        Logger.info("Cancel order id #{inspect order_id} for #{inspect order["limit_price"]}")
        CfLuno.Api.stop_order(order_id)
      end
    )
  end

end