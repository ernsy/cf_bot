defmodule CfBot.Statem do
  require Logger

  use GenStateMachine

  @min_order_vol 0.0005
  @trade_delta_sec 30
  @new_review_time 10
  @keep_review_time 100

  #---------------------------------------------------------------------------------------------------------------------
  # api
  #---------------------------------------------------------------------------------------------------------------------

  def start_link(%{name: name} = init_data) do
    GenStateMachine.start_link(__MODULE__, init_data, name: name)
  end

  def set_data(name, key, value) do
    GenStateMachine.cast(name, {:set_data, key, value})
  end

  def resume(name) do
    GenStateMachine.cast(name, {:resume, {:limit_sell, []}})
  end

  def oracle_update(name, msg) do
    GenStateMachine.cast(name, {:oracle_update, msg})
  end

  def ws_update(name, msg) do
    GenStateMachine.cast(name, {:ws_update, msg})
  end

  #---------------------------------------------------------------------------------------------------------------------
  # callbacks
  #---------------------------------------------------------------------------------------------------------------------

  def init(%{min_incr: _, dt_pct: _, ut_pct: _, stable_pct: _, bv_pct: _, j_pct: _, aj_pct: _} = init_map) do
    %{name: name, med_mod: med_mod, pair: pair, ref_pair: ref_pair, ws: ws, mode: mode} = init_map
    ws_mod = Module.concat([name, WsUserClient])
    ws && DynamicSupervisor.start_child(CfBot.WsSup, {ws_mod, [med_mod, pair]})
    prim_curr = String.slice(pair, 0, 3)
    orders = med_mod.list_open_orders(pair)
    cancel_orders(orders, med_mod)
    {:ok, [oracle_price, datetime]} = get_oracle_price(ref_pair)
    queue = :queue.new
    maker_fee = med_mod.get_maker_fee()
    order_time = :erlang.system_time(:millisecond)
    prim_hodl_amt = init_map[:prim_hodl_amt]
    %{prim_bal: prim_bal, sec_bal: sec_bal} = data =
      cond do
        mode == "hodl" and prim_hodl_amt ->
          %{sell_amt: max(med_mod.get_avail_bal(prim_curr) - prim_hodl_amt, 0), buy_amt: 0}
        mode == "bot" ->
          get_bot_amts(init_map, true)
        true ->
          %{sell_amt: init_map[:sell_amt], buy_amt: 0}
      end
    data = Map.merge(data, %{oracle_queue: {queue, 0}, oracle_ref: {oracle_price, datetime}, order_id: nil})
           |> Map.merge(%{old_price: 0, new_price: 0, order_time: order_time, fee: maker_fee})
           |> Map.merge(%{next_transition: [], start_amt: prim_bal + sec_bal, start_time: NaiveDateTime.utc_now()})
           |> Map.merge(init_map)
    Logger.info("Init data:#{inspect data}")
    {:ok, :wait_stable, data}
  end

  def handle_event(:cast, {:resume, action}, state, data) do
    Logger.info("Resuming with data:#{inspect data}, state:#{state}")
    {:keep_state_and_data, [{:state_timeout, 0, action}]}
  end

  def handle_event(:cast, {:set_data, :prim_hodl_amt, val}, state, %{mode: "sell"} = data) do
    %{pair: pair, med_mod: med_mod} = data
    prim_curr = String.slice(pair, 0, 3)
    sell_amt = med_mod.get_avail_bal(prim_curr) - val
               |> Float.floor(6)
               |> max(0)
    Logger.info("Set :prim_hodl_amt to:#{val} and :sell_amt to :#{sell_amt}, state:#{state}")
    new_data = %{data | prim_hodl_amt: val, sell_amt: sell_amt, old_amt: sell_amt}
    Logger.info("New data #{inspect new_data}")
    {:keep_state, new_data}
  end

  def handle_event(:cast, {:set_data, key, val}, state, data) do
    Logger.info("Set #{key} to:#{val}, state:#{state}")
    new_data = Map.put(data, key, val)
    display_data = Map.delete(new_data, :oracle_queue)
    Logger.info("New data #{inspect display_data}")
    {:keep_state, new_data}
  end

  def handle_event(:cast, {:oracle_update, %{"price" => price, "time" => time}}, state, data) do
    %{oracle_ref: {old_price, old_datetime}, oracle_queue: {queue, length}} = data
    {pricef, _rem_bin} = Float.parse(price)
    {:ok, datetime, _} = DateTime.from_iso8601(time)
    seconds_diff = DateTime.diff(datetime, old_datetime)
    if seconds_diff > @trade_delta_sec do
      queue = :queue.in({pricef, datetime}, queue)
      {{q_price, q_datetime}, queue} = dequeue_while(queue, datetime, {old_price, old_datetime})
      {next_state, next_action} = get_next_state_and_action(data, state, pricef)
      new_data = %{data | oracle_queue: {queue, length}, oracle_ref: {q_price, q_datetime}}
      do_state_change(new_data, state, next_state, next_action)
    else
      new_queue = :queue.in({pricef, datetime}, queue)
      new_data = %{data | oracle_queue: {new_queue, length + 1}}
      {:keep_state, new_data}
    end
  end

  def handle_event(event_type, action, state, data)
      when
        (event_type == :internal or event_type == :state_timeout) and
        (action == :limit_sell or action == :limit_buy or action == :market_sell or action == :market_buy) do
    new_data = calc_limit_order_price(data, state, action)
               |> post_order(state, action)
    %{next_transition: {next_state, next_action}} = new_data
    {:next_state, next_state, new_data, next_action}
  end

  def handle_event(:internal, :cancel_orders, state, %{med_mod: mod, pair: pair} = data) do
    orders = mod.list_open_orders(pair)
    cancel_orders(orders, mod)
    [data, _rem_vol, _hodl_amt, _type] = do_calc_vol(data, state)
    data = %{data | order_id: nil, old_price: 0}
    {:keep_state, data}
  end

  def handle_event(:info, {:ssl_closed, _}, _state, _data) do
    :keep_state_and_data
  end

  def handle_event(:cast, {:ws_update, %{"msg_type" => "new_trade"} = msg}, _state, data) do
    %{"volume" => vol, "side" => side} = msg
    new_data =
      if side == "sell" do
        %{sell_amt: sell_amt} = data
        %{data | sell_amt: sell_amt - vol}
      else
        %{buy_amt: buy_amt} = data
        %{data | buy_amt: buy_amt - vol}
      end
    {:keep_state, new_data}
  end

  def handle_event(event_type, event_content, state, data) do
    Logger.warn("Unhandled event:#{inspect [type: event_type, content: event_content, state: state, data: data]}")
    :keep_state_and_data
  end

  def terminate(_reason, _state, _data) do
    :ok
  end

  #---------------------------------------------------------------------------------------------------------------------
  # helper functions
  #---------------------------------------------------------------------------------------------------------------------

  defp get_oracle_price(pair) do
    {:ok, %{"price" => price, "time" => time}} = CfCb.Api.get_oracle_ticker(pair)
    {float_price, _rem_bin} = Float.parse(price)
    {:ok, datetime, _} = DateTime.from_iso8601(time)
    {:ok, [float_price, datetime]}
  end

  defp dequeue_while(queue, datetime, {old_price, old_datetime} = old_q_entry) do
    case :queue.out(queue) do
      {{:value, q_entry}, queue} ->
        {_q_price, q_datetime} = q_entry
        seconds_diff = DateTime.diff(datetime, q_datetime)
        if seconds_diff >= @trade_delta_sec do
          dequeue_while(queue, datetime, {old_price, old_datetime})
        else
          {q_entry, queue}
        end
      {:empty, queue} -> {old_q_entry, queue}
    end
  end

  defp get_next_state_and_action(data, state, curr_price) do
    %{sell_amt: sell_amt, buy_amt: buy_amt, mode: mode} = data
    cond do
      sell_amt > @min_order_vol and buy_amt > @min_order_vol ->
        check_delta(data, state, curr_price, :buy_or_sell)
      sell_amt > @min_order_vol or mode == "sell" or mode == "hodl" ->
        check_delta(data, state, curr_price, :sell)
      buy_amt > @min_order_vol or mode == "buy" ->
        check_delta(data, state, curr_price, :buy)
      true ->
        {state, []}
    end
  end

  defp check_delta(
         %{oracle_ref: {old_price, _}, } = data,
         state,
         curr_price,
         transition_key
       ) do
    %{dt_pct: dt_pct, ut_pct: ut_pct, stable_pct: s_pct, j_pct: j_pct, aj_pct: aj_pct} = data
    buy_state = state == :quick_buy or state == :buy
    sell_state = state == :quick_sell or state == :sell
    state_transitions = apply(CfBot.Transitions, state, [])
    transitions = state_transitions[transition_key]
    delta_pct = (curr_price - old_price) / old_price
    cond do
      state == :wait_stable and transition_key == :buy and delta_pct >= 0 and delta_pct < s_pct -> transitions.stable
      state == :wait_stable and transition_key == :sell and delta_pct <= 0 and -delta_pct < s_pct -> transitions.stable
      buy_state and delta_pct >= 0 and delta_pct < j_pct -> transitions.stable
      sell_state and delta_pct <= 0 and -delta_pct < j_pct -> transitions.stable
      buy_state and delta_pct <= 0 and -delta_pct < aj_pct -> transitions.stable
      sell_state and delta_pct >= 0 and delta_pct < aj_pct -> transitions.stable
      delta_pct > ut_pct -> transitions.up_trend
      delta_pct < -dt_pct -> transitions.down_trend
      delta_pct >= 0 ->
        transitions.positive
      delta_pct < 0 ->
        transitions.negative
    end
  end

  defp do_state_change(data, state, :wait_stable, _next_action) do
    data = get_bot_amts_and_action(data, true, state, [])
    {:next_state, :wait_stable, data}
  end

  defp do_state_change(data, state, state, _next_action) do
    {:next_state, state, data}
  end
  defp do_state_change(data, _state, next_state, next_action) do
    Logger.warn("State: #{next_state}")
    new_buy_amt = get_mode_buy_amt(data)
    new_sell_amt = get_mode_sell_amt(data)
    {:next_state, next_state, %{data | buy_amt: new_buy_amt, sell_amt: new_sell_amt}, next_action}
  end

  defp get_mode_sell_amt(%{sell_amt: sell_amt, mode: "sell"} = data)
       when sell_amt <= 0 do
    %{old_amt: old_amt, pair: pair, prim_hodl_amt: hodl_amt, med_mod: med_mod} = data
    prim_curr = String.slice(pair, 0, 3)
    new_sell_amt = med_mod.get_avail_bal(prim_curr) - hodl_amt
                   |> Float.floor(6)
                   |> max(0)
    if new_sell_amt <= old_amt, do: new_sell_amt, else: sell_amt
  end
  defp get_mode_sell_amt(%{sell_amt: sell_amt}), do: sell_amt

  defp get_mode_buy_amt(%{buy_amt: buy_amt, mode: "buy"} = data)
       when buy_amt <= 0 do
    %{pair: pair, sec_hodl_amt: hodl_amt, med_mod: med_mod, min_incr: min_incr, fee: fee} = data
    sec_curr = String.slice(pair, -3, 3)
    {bid_price, _} = med_mod.get_ticker(pair)["bid"]
                     |> Float.parse()
    (med_mod.get_avail_bal(sec_curr) - hodl_amt) / ((bid_price + min_incr) * (1 + fee))
  end
  defp get_mode_buy_amt(%{buy_amt: buy_amt}), do: buy_amt

  defp calc_limit_order_price(data, _state, action) when action == :market_sell or action == :market_buy do
    data
  end
  defp calc_limit_order_price(%{med_mod: mod, pair: pair, min_incr: min_incr} = data, state, _action)
       when state == :quick_sell or state == :quick_buy do
    type = get_state_order_type(state)
    [vol_key] = get_state_keys(state, [:vol_key])
    order_vol = data[vol_key]
    if order_vol > @min_order_vol do
      %{"bid" => bid, "ask" => ask} = mod.get_ticker(pair)
      Logger.debug("Bid price:" <> bid <> " ask price:" <> ask)
      {bidf, _} = Float.parse(bid)
      {askf, _} = Float.parse(ask)
      order_price =
        if type == "ASK" do
          calc_best_price(askf, askf, bidf, min_incr, type)
        else
          calc_best_price(bidf, bidf, askf, min_incr, type)
        end
      %{data | new_price: order_price}
    else
      data
    end
  end
  defp calc_limit_order_price(data, state, _action) do
    %{old_price: old_price, med_mod: mod, pair: pair, min_incr: min_incr, bv_pct: bv_pct} = data
    [vol_key] = get_state_keys(state, [:vol_key])
    order_vol = data[vol_key]
    if order_vol > @min_order_vol do
      type = get_state_order_type(state)
      vol_before_order = order_vol * bv_pct
      %{"asks" => asks, "bids" => bids} = mod.get_orderbook(pair)
      {type_orders, alt_orders} = if type == "ASK", do: {asks, bids}, else: {bids, asks}
      {:ok, new_price} = Enum.reduce_while(
        type_orders,
        {0, order_vol},
        fn (%{"volume" => volume_str, "price" => price_str}, {acc_volume, curr_vol}) ->
          {volume, _} = Float.parse(volume_str)
          {price, _} = Float.parse(price_str)
          {new_acc_volume, rem_limit_vol} =
            if curr_vol > 0 and ((type == "ASK" and price >= old_price) or (type == "BID" and price <= old_price)) do
              new_acc_volume = acc_volume + volume - curr_vol
              {new_acc_volume, 0}
            else
              new_acc_volume = acc_volume + volume
              {new_acc_volume, curr_vol}
            end
          if new_acc_volume > vol_before_order do
            %{"price" => best_price} = hd(type_orders)
            %{"price" => best_alt_price} = hd(alt_orders)
            {best_pricef, _} = Float.parse(best_price)
            {best_alt_pricef, _} = Float.parse(best_alt_price)
            new_price = calc_best_price(best_pricef, price, best_alt_pricef, min_incr, type)
            {:halt, {:ok, new_price}}
          else
            {:cont, {new_acc_volume, rem_limit_vol}}
          end
        end
      )
      %{data | new_price: new_price}
    else
      data
    end
  end

  defp calc_best_price(ask_price, ask_price, bid_price, min_incr, "ASK") do
    max(bid_price + min_incr, ask_price - min_incr)
  end
  defp calc_best_price(ask_price, order_price, _, min_incr, "ASK") do
    max(ask_price + min_incr, order_price) - min_incr
  end
  defp calc_best_price(bid_price, bid_price, ask_price, min_incr, "BID") do
    min(ask_price - min_incr, bid_price + min_incr)
  end
  defp calc_best_price(bid_price, order_price, _, min_incr, "BID") do
    min(bid_price - min_incr, order_price) + min_incr
  end

  defp post_order(%{old_price: order_price, new_price: order_price} = data, state, action)
       when action == :limit_sell or action == :limit_buy do
    [data, rem_vol, _hodl_amt, type] = do_calc_vol(data, state)
    rem_vol_str = if rem_vol > 0, do: :erlang.float_to_binary(rem_vol, [{:decimals, 6}]), else: 0
    Logger.debug("Keep limit #{type} order remaining volume #{rem_vol_str} at #{order_price}")
    %{data | next_transition: {state, {:state_timeout, @keep_review_time, action}}}
  end
  defp post_order(data, state, action)
       when action == :limit_sell or action == :limit_buy do
    %{new_price: price, pair: pair, med_mod: med_mod, order_id: order_id} = data
    {:ok, [order_id, bal_reserved?]} = med_mod.stop_order(order_id)
    [data, rem_vol, hodl_amt, type] = do_calc_vol(data, state)
    [prim_bal, sec_bal, bal_after_order] = get_bal_after_order(data, type, rem_vol, bal_reserved?)
    data = %{data | prim_bal: prim_bal, sec_bal: sec_bal}
    if bal_after_order >= hodl_amt and rem_vol >= @min_order_vol do
      order_id = med_mod.post_order(pair, type, rem_vol, price, "true") || order_id
      next_transition = {state, {:state_timeout, @new_review_time, action}}
      %{data | order_id: order_id, old_price: price, next_transition: next_transition}
    else
      data = get_bot_amts_and_action(data, bal_reserved?, state, action)
      %{next_transition: {state, _action}} = data
      sell_amt_str = :erlang.float_to_binary(data[:sell_amt], [{:decimals, 6}])
      buy_amt_str = :erlang.float_to_binary(data[:buy_amt], [{:decimals, 6}])
      Logger.info "Sell amt #{sell_amt_str} Buy amt #{buy_amt_str}"
      Logger.warn "State #{state}"
      %{data | order_id: order_id}
    end
  end
  defp post_order(%{pair: pair, med_mod: med_mod, order_id: order_id} = data, state, action)
       when action == :market_sell or action == :market_buy do
    {:ok, [old_order_id, bal_reserved?]} = med_mod.stop_order(order_id)
    [data, rem_vol, hodl_amt, type] = do_calc_vol(data, state)
    [prim_bal, sec_bal, bal_after_order] = get_bal_after_order(data, type, rem_vol, bal_reserved?)
    if bal_after_order >= hodl_amt and rem_vol >= @min_order_vol do
      med_mod.market_order(pair, type, rem_vol / 10)
    end
    next_transition = {:wait_stable, []}
    %{data | order_id: old_order_id, next_transition: next_transition, prim_bal: prim_bal, sec_bal: sec_bal}
  end

  def get_bot_amts_and_action(data, bal_reserved?, state, action) do
    %{buy_amt: buy_amt, sell_amt: sell_amt} = data = get_bot_amts(data, bal_reserved?)
    cond  do
      (sell_amt > @min_order_vol and action == :limit_sell) or (buy_amt > @min_order_vol and action == :limit_buy) ->
        %{data | :next_transition => {state, {:state_timeout, @new_review_time, action}}}
      true ->
        %{data | next_transition: {:wait_stable, {:next_event, :internal, :cancel_orders}}}
    end
  end

  def get_bot_amts(%{med_mod: med_mod} = data, bal_reserved?) do
    maker_fee = med_mod.get_maker_fee()
    {price, _} = med_mod.get_ticker("XBTZAR")["last_trade"]
                 |> Float.parse()
    prim_bal = med_mod.get_avail_bal("XBT", bal_reserved?)
    sec_bal = med_mod.get_avail_bal("ZAR", bal_reserved?) / price
    buy_amt = sec_bal - 0.001
    fee_allowance = (prim_bal + buy_amt) * maker_fee * 10
    sell_amt = prim_bal - fee_allowance
    Map.merge(data, %{sell_amt: sell_amt, buy_amt: buy_amt, prim_bal: prim_bal, sec_bal: sec_bal})
  end

  def do_calc_vol(data, state) do
    state_keys = get_state_keys(state, [:vol_key, :alt_vol_key, :bal_key, :alt_bal_key, :hodl_key])
    state_values = Enum.map(state_keys, &(data[&1]))
    type = get_state_order_type(state)
    [data, rem_vol, hodl_amt] = calc_vol(data, state_keys, state_values, type)
    [data, rem_vol, hodl_amt, type]
  end

  defp calc_vol(
         %{start_amt: start_amt, start_time: st} = data,
         [vol_key, a_vol_key, bal_key, alt_bal_key, _hodl_key],
         [order_vol, alt_vol, bal, alt_bal, hodl_amt],
         type
       ) do
    %{order_time: old_ts, ws: ws, mode: mode, med_mod: med_mod, pair: pair, order_id: order_id} = data
    alt_type = if type == "BID", do: "ASK", else: "BID"
    sum_trades = med_mod.sum_trades(pair, old_ts, order_id, ws)
    ts = sum_trades["latest_ts"] || old_ts
    traded_vol = sum_trades[type] || 0
    alt_traded_vol = sum_trades[alt_type] || 0
    if traded_vol != 0 or alt_traded_vol != 0 do
      order_vol = if mode == "bot", do: order_vol - traded_vol + alt_traded_vol, else: order_vol - traded_vol
      alt_vol = if mode == "bot", do: alt_vol - alt_traded_vol + traded_vol, else: alt_vol - alt_traded_vol
      bal = bal - traded_vol + alt_traded_vol
      alt_bal = alt_bal - alt_traded_vol + traded_vol
      profit = bal + alt_bal - start_amt
      diff_s = NaiveDateTime.diff(NaiveDateTime.utc_now(), st)
      monthly_profit = profit / diff_s * 60 * 60 * 24 * 30
      profit_str = :erlang.float_to_binary(profit, [{:decimals, 6}])
      monthly_profit_str = :erlang.float_to_binary(monthly_profit, [{:decimals, 6}])
      bal_str = :erlang.float_to_binary(bal, [{:decimals, 6}])
      alt_bal_str = :erlang.float_to_binary(alt_bal, [{:decimals, 6}])
      Logger.info("Profit #{profit_str} Monthly #{monthly_profit_str} Bal #{bal_str} AltBal #{alt_bal_str}")
      data =
        %{data | vol_key => order_vol, a_vol_key => alt_vol, bal_key => bal, alt_bal_key => alt_bal, :order_time => ts}
      [data, order_vol, hodl_amt]
    else
      data =
        %{data | vol_key => order_vol, a_vol_key => alt_vol, bal_key => bal, alt_bal_key => alt_bal, :order_time => ts}
      [data, order_vol, hodl_amt]
    end
  end

  defp get_state_keys(state, keys) when state == :sell or state == :quick_sell or state == :wait_stable do
    key_map =
      %{vol_key: :sell_amt, alt_vol_key: :buy_amt, bal_key: :prim_bal, alt_bal_key: :sec_bal, hodl_key: :prim_hodl_amt}
    get_state_keys(state, keys, key_map)
  end
  defp get_state_keys(state, keys) when state == :buy or state == :quick_buy do
    key_map =
      %{vol_key: :buy_amt, alt_vol_key: :sell_amt, bal_key: :sec_bal, alt_bal_key: :prim_bal, hodl_key: :sec_hodl_amt}
    get_state_keys(state, keys, key_map)
  end
  defp get_state_keys(_state, keys, key_map), do: Enum.map(keys, fn (key) -> %{^key => val} = key_map; val end)

  defp get_state_order_type(state) when state == :sell or state == :quick_sell or state == :wait_stable, do: "ASK"
  defp get_state_order_type(state) when state == :buy or state == :quick_buy, do: "BID"

  defp get_bal_after_order(data, type, rem_vol, balance_reserved)
       when type == "SELL" do
    %{med_mod: med_mod, pair: pair, fee: maker_fee, sec_bal: sec_bal} = data
    prim_curr = String.slice(pair, 0, 3)
    bal = med_mod.get_avail_bal(prim_curr, balance_reserved)
    bal_after_order = bal - rem_vol * (1 + maker_fee)
    [bal, sec_bal, bal_after_order]
  end
  defp get_bal_after_order(data, type, rem_vol, balance_reserved)
       when type == "BUY" do
    %{med_mod: med_mod, pair: pair, prim_bal: prim_bal} = data
    sec_curr = String.slice(pair, -3, 3)
    bal = med_mod.get_avail_bal(sec_curr, balance_reserved)
    {ask_price, _} = med_mod.get_ticker(pair)["ask"]
                     |> Float.parse()
    bal_after_order = bal - rem_vol * ask_price
    [prim_bal, bal / ask_price, bal_after_order]
  end
  defp get_bal_after_order(data, type, rem_vol, balance_reserved)
       when type == "ASK" do
    %{med_mod: med_mod, pair: pair, sec_bal: sec_bal} = data
    prim_curr = String.slice(pair, 0, 3)
    bal = med_mod.get_avail_bal(prim_curr, balance_reserved)
    bal_after_order = bal - rem_vol
    [bal, sec_bal, bal_after_order]
  end
  defp get_bal_after_order(data, type, rem_vol, balance_reserved)
       when type == "BID" do
    %{new_price: price, med_mod: med_mod, pair: pair, prim_bal: prim_bal} = data
    sec_curr = String.slice(pair, -3, 3)
    bal = med_mod.get_avail_bal(sec_curr, balance_reserved)
    bal_after_order = bal - rem_vol * price
    [prim_bal, bal / price, bal_after_order]
  end

  def cancel_orders(nil, _mod), do: %{}
  def cancel_orders(orders, med_mod) do
    Enum.each(orders, fn (%{order_id: id}) -> med_mod.stop_order(id) end)
  end
end