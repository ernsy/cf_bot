defmodule CfLuno.Statem do
  require Logger

  use GenStateMachine

  import String, only: [to_float: 1]

  @short_stable_delta_time 15000
  @long_stable_delta_time 30000
  @unstable_delta_time 60000
  @order_review_time 5000

  @dt_perc 0.002
  @ut_perc 0.002
  @stable_perc 0.0005
  @min_order_vol 0.0005

  @short_stable_timeout_action {{:timeout, :check_oracle_price}, @short_stable_delta_time, :check_oracle_price}
  @long_stable_timeout_action {{:timeout, :check_oracle_price}, @long_stable_delta_time, :check_oracle_price}
  @unstable_timeout_action {{:timeout, :check_oracle_price}, @unstable_delta_time, :check_oracle_price}
  @order_review_timeout_action {:state_timeout, @order_review_time, :limit_sell}

  @short_limit_sell_action {:next_event, :internal, {:limit_sell, @short_stable_timeout_action}}
  @long_limit_sell_action {:next_event, :internal, {:limit_sell, @long_stable_timeout_action}}
  @cancel_order_action {:next_event, :internal, :cancel_order}

  #---------------------------------------------------------------------------------------------------------------------
  # api
  #---------------------------------------------------------------------------------------------------------------------

  def start_link(init_data) do
    GenStateMachine.start_link(__MODULE__, init_data, name: __MODULE__)
  end

  def start_stable() do
    GenStateMachine.cast(__MODULE__, :start_stable)
  end

  def start_unstable() do
    GenStateMachine.cast(__MODULE__, :start_unstable)
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
    {:ok, :wait_stable, new_data, @unstable_timeout_action}
  end

  def handle_event(:cast, :start_stable, state, %{btc_hodl: btc_amount}) do
    Logger.info("Starting stable with btc_hodl amount:#{inspect btc_amount}, state:#{inspect state}")
    {:keep_state_and_data, @short_stable_timeout_action}
  end

  def handle_event(:cast, :start_unstable, state, %{btc_hodl: btc_amount}) do
    Logger.info("Starting unstable with btc_hodl amount:#{inspect btc_amount}, state:#{inspect state}")
    {:keep_state_and_data, @unstable_timeout_action}
  end

  def handle_event(:cast, {:set_btc_hodl, btc_amount}, state, data) do
    :ok = :dets.insert(:disk_storage, {:btc_hodl, btc_amount})
    Logger.info("Set btc to hodl:#{inspect btc_amount}, state:#{inspect state}")
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
    #Logger.info(
    #  "Check oracle price state: #{inspect state}
    #  old_price:  #{inspect old_oracle_price}
    #  curr_price: #{inspect current_oracle_price}
    #  date:       #{inspect :erlang.date}"
    #)
    new_data = %{data | oracle_price: current_oracle_price}
    opt = case state do
      :wait_stable ->
        %{
          stable: {:sell, @long_limit_sell_action},
          up_trend: {:wait_stable, @unstable_timeout_action},
          down_trend: {:quick_sell, @short_limit_sell_action},
          positive: {:wait_stable, @unstable_timeout_action},
          negative: {:sell, @long_limit_sell_action}
        }
      :sell ->
        %{
          stable: {:sell, @long_limit_sell_action},
          up_trend: {:wait_stable, @cancel_order_action},
          down_trend: {:quick_sell, @short_limit_sell_action},
          positive: {:sell, @long_limit_sell_action},
          negative: {:sell, @long_limit_sell_action}
        }
      :quick_sell ->
        %{
          stable: {:sell, @long_limit_sell_action},
          up_trend: {:wait_stable, @cancel_order_action},
          down_trend: {:quick_sell, @short_limit_sell_action},
          positive: {:sell, @long_limit_sell_action},
          negative: {:sell, @long_limit_sell_action}
        }
    end
    check_delta(old_oracle_price, current_oracle_price, new_data, opt)
  end

  def handle_event(:internal, :cancel_order, :wait_stable, data) do
    {:ok, resp} = CfLuno.Api.list_orders("XBTZAR", "PENDING")
    orders = resp["orders"]
    if orders do
      order = hd(orders)
      order_id = order["order_id"]
      {:ok, %{"success" => true}} = CfLuno.Api.stop_order(order_id)
      {curr_limit_price, _} = Integer.parse(order["limit_price"])
      Logger.info("Cancelled limit sell order #{inspect order_id} at #{inspect curr_limit_price}")
    end
    {:keep_state, data, @unstable_timeout_action}
  end

  def handle_event(:internal, {:limit_sell, post_action}, :sell, %{btc_hodl: btc_hodl}) do
    new_limit_vol = calc_limit_vol(btc_hodl)
    check_vol_and_process_order(new_limit_vol, new_limit_vol)
    {:keep_state_and_data, [@order_review_timeout_action, post_action]}
  end

  def handle_event(:state_timeout, :limit_sell, :sell, %{btc_hodl: btc_hodl}) do
    new_limit_vol = calc_limit_vol(btc_hodl)
    check_vol_and_process_order(new_limit_vol, new_limit_vol)
    {:keep_state_and_data, @order_review_timeout_action}
  end

  def handle_event(:internal, {:limit_sell, post_action}, :quick_sell, %{btc_hodl: btc_hodl}) do
    new_limit_vol = calc_limit_vol(btc_hodl)
    check_vol_and_process_order(0, new_limit_vol)
    {:keep_state_and_data, [@order_review_timeout_action, post_action]}
  end

  def handle_event(:state_timeout, :limit_sell, :quick_sell, %{btc_hodl: btc_hodl}) do
    new_limit_vol = calc_limit_vol(btc_hodl)
    check_vol_and_process_order(0, new_limit_vol)
    {:keep_state_and_data, @order_review_timeout_action}
  end

  def handle_event(:info, {:ssl_closed, _}, _state, _data) do
    {:keep_state_and_data, []}
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
         opt
       ) do
    delta_perc = (curr_price - old_price) / old_price
    {next_state, next_action} = case delta_perc do
      change_perc when abs(change_perc) < @stable_perc ->
        opt.stable
      change_perc when change_perc > @ut_perc ->
        bid_price = get_luno_price("bid")
        Logger.info("Current Luno bid price:#{inspect bid_price}")
        opt.up_trend
      change_perc when change_perc < -@dt_perc ->
        opt.down_trend
      change_perc when change_perc > 0 ->
        opt.positive
      change_perc when change_perc < 0 ->
        opt.negative
    end
    dp = Float.round(delta_perc, 4)
    Logger.info("CB price:#{inspect curr_price}, delta:#{inspect dp}, next_state:#{inspect next_state}")
    {:next_state, next_state, new_data, next_action}
  end

  defp calc_limit_vol(btc_hodl) do
    {:ok, balances} = CfLuno.Api.balance("XBT")
    xbt_bal = hd(balances["balance"])
    avail_bal = to_float(xbt_bal["balance"])
    unconf_bal = to_float(xbt_bal["unconfirmed"])
    avail_bal + unconf_bal - btc_hodl
    |> min(avail_bal)
    |> Float.round(6)
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
    Enum.each(
      orders,
      fn (order) ->
        order_id = order["order_id"]
        Logger.info("Cancel order id #{inspect order_id} for #{inspect order["limit_price"]}")
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

end