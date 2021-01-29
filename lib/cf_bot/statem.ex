defmodule CfBot.Statem do
  require Logger

  use GenStateMachine

  @min_order_vol 0.0005
  @trade_delta_sec 60
  @long_review_time 1
  @short_review_time 1

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

  def init(%{min_incr: _, dt_pct: _, ut_pct: _, stable_pct: _, bv_pct: _, } = init_map) do
    %{name: name, med_mod: med_mod, pair: pair, ref_pair: ref_pair, ws: ws, mode: mode} = init_map
    %{sell_amt: sell_amt, buy_amt: buy_amt} = init_map
    ws_mod = Module.concat([name, WsUserClient])
    ws && DynamicSupervisor.start_child(CfBot.WsSup, {ws_mod, [med_mod, pair]})
    prim_curr = String.slice(pair, 0, 3)
    sec_curr = String.slice(pair, -3, 3)
    {:ok, name} = :dets.open_file(name, [type: :set])
    data = case :dets.lookup(name, :data) do
      [data: %{sell_amt: _, prim_hodl_amt: _, buy_amt: _, sec_hodl_amt: _, mode: _} = data] ->
        data
      _ ->
        prim_hodl_amt = med_mod.get_avail_bal(prim_curr)
        sec_hodl_amt = med_mod.get_avail_bal(sec_curr)
        %{sell_amt: 0, prim_hodl_amt: prim_hodl_amt, buy_amt: 0, sec_hodl_amt: sec_hodl_amt, mode: "manual"}
    end
    orders = med_mod.list_open_orders(pair)
    order_length = orders && length(orders)
    order_map = if order_length == 1 and mode != "buy" do
      hd(orders)
    else
      cancel_orders(orders, med_mod)
      %{}
    end
    {:ok, [oracle_price, datetime]} = get_oracle_price(ref_pair)
    queue = :queue.new
    maker_fee = med_mod.get_maker_fee()
    prim_hodl_amt = init_map[:prim_hodl_amt]
    {new_sell_amt, new_buy_amt} =
      cond do
        mode == "hodl" and prim_hodl_amt -> {max(med_mod.get_avail_bal(prim_curr) - prim_hodl_amt, 0), 0}
        mode == "bot" -> {sell_amt, buy_amt}
        true -> {data[:sell_amt], 0}
      end
    init_data = %{
      oracle_queue: {queue, 0},
      oracle_ref: {oracle_price, datetime},
      order_id: nil,
      old_price: 0,
      new_price: 0,
      order_time: :erlang.system_time(:millisecond),
      fee: maker_fee,
      sell_amt: new_sell_amt,
      buy_amt: new_buy_amt,
      next_transition: []
    }
    new_data = Map.merge(data, init_data)
               |> Map.merge(init_map)
               |> Map.merge(order_map)
    Logger.info("Init data:#{inspect new_data}")
    {:ok, :wait_stable, new_data}
  end

  def handle_event(:cast, {:resume, action}, state, data) do
    Logger.info("Resuming with data:#{inspect data}, state:#{state}")
    {:keep_state_and_data, [{:state_timeout, 0, action}]}
  end

  def handle_event(:cast, {:set_data, :prim_hodl_amt, val}, state, %{mode: "sell"} = data) do
    %{name: name, pair: pair, med_mod: med_mod} = data
    prim_curr = String.slice(pair, 0, 3)
    sell_amt = med_mod.get_avail_bal(prim_curr) - val
               |> Float.floor(6)
               |> max(0)
    Logger.info("Set :prim_hodl_amt to:#{val} and :sell_amt to :#{sell_amt}, state:#{state}")
    new_data = %{data | prim_hodl_amt: val, sell_amt: sell_amt, old_amt: sell_amt, order_id: nil}
    :ok = :dets.insert(name, {:data, new_data})
    Logger.info("New data #{inspect new_data}")
    {:keep_state, new_data}
  end

  def handle_event(:cast, {:set_data, key, val}, state, %{name: name} = data) do
    Logger.info("Set #{key} to:#{val}, state:#{state}")
    new_data = %{data | key => val}
    :ok = :dets.insert(name, {:data, new_data})
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
      {next_state, next_action} = get_next_state_and_action(pricef, state, data)
      new_data = %{data | oracle_queue: {queue, length}, oracle_ref: {q_price, q_datetime}}
      do_state_change(pricef, state, next_state, next_action, new_data)
    else
      new_queue = :queue.in({pricef, datetime}, queue)
      new_data = %{data | oracle_queue: {new_queue, length + 1}}
      {:keep_state, new_data}
    end
  end

  def handle_event(event_type, action, state, %{name: name} = data)
      when
        (event_type == :internal or event_type == :state_timeout) and
        (action == :limit_sell or action == :limit_buy or action == :market_sell or action == :market_buy) do
    new_data = calc_limit_order_price(data, state, action)
               |> post_order(state, action)
    #:ok = :dets.insert(name, {:data, new_data})
    %{next_transition: {next_state, next_action}} = new_data
    {:next_state, next_state, new_data, next_action}
  end

  def handle_event(:internal, :cancel_orders, _state, data) do
    %{sell_amt: sell_amt, buy_amt: buy_amt, med_mod: mod, pair: pair} = data
    orders = mod.list_open_orders(pair)
    %{} = cancel_orders(orders, mod)
    [new_ts, new_sell_amt, new_buy_amt] = calc_vol(data, sell_amt, buy_amt, "ASK", "BID")
    new_data =
      %{data | order_id: nil, old_price: 0, sell_amt: new_sell_amt, buy_amt: new_buy_amt, order_time: new_ts}
    {:keep_state, new_data}
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

  def terminate(_reason, _state, %{name: name}) do
    :dets.close(name)
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

  defp get_next_state_and_action(pricef, state, %{oracle_ref: {old_price, _old_datetime}} = data) do
    %{sell_amt: sell_amt, buy_amt: buy_amt, dt_pct: dt_pct, ut_pct: ut_pct, stable_pct: s_pct, mode: mode} = data
    transitions = apply(CfBot.Transitions, state, [])
    cond do
      sell_amt > 0 and buy_amt > 0 ->
        check_delta(old_price, pricef, dt_pct, ut_pct, s_pct, transitions[:buy_or_sell])
      sell_amt > 0 or mode == "sell" or mode == "hodl" ->
        check_delta(old_price, pricef, dt_pct, ut_pct, s_pct, transitions[:sell])
      buy_amt > 0 or mode == "buy" ->
        check_delta(old_price, pricef, dt_pct, ut_pct, s_pct, transitions[:buy])
      true ->
        {state, []}
    end
  end

  defp check_delta(old_price, curr_price, dt_pct, ut_pct, stable_pct, transitions) do
    delta_pct = (curr_price - old_price) / old_price
    cond do
      abs(delta_pct) < stable_pct -> transitions.stable
      delta_pct > ut_pct -> transitions.up_trend
      delta_pct < -dt_pct -> transitions.down_trend
      delta_pct > 0 ->
        transitions.positive
      delta_pct < 0 ->
        transitions.negative
    end
  end

  defp do_state_change(_pricef, state, state, _next_action, data) do
    {:next_state, state, data}
  end
  defp do_state_change(_pricef, _state, next_state, next_action, data) do
    Logger.debug("State change:#{next_state}")
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
    if new_sell_amt <= old_amt do
      new_sell_amt
    else
      sell_amt
    end
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
    [vol_key, _alt_vol_key, _hodl_amt_key] = get_state_keys(state)
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
  defp calc_limit_order_price(
         %{old_price: old_price, med_mod: mod, pair: pair, min_incr: min_incr, bv_pct: bv_pct} = data,
         state,
         _action
       ) do
    [vol_key, _alt_vol_key, _hodl_amt_key] = get_state_keys(state)
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
            %{"price" => best_price, "volume" => best_vol} = hd(type_orders)
            %{"price" => best_alt_price, "volume" => best_alt_vol} = hd(alt_orders)
            Logger.debug(
              "Best price:" <> best_price <> ", volume:" <> best_vol
              <> ". Best alt price:" <> best_alt_price <> ", volume:" <> best_alt_vol
            )
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

  defp get_state_keys(state) when state == :sell or state == :quick_sell do
    [:sell_amt, :buy_amt, :prim_hodl_amt]
  end
  defp get_state_keys(state) when state == :buy or state == :quick_buy do
    [:buy_amt, :sell_amt, :sec_hodl_amt]
  end

  defp get_state_values(data, state, vol_key, alt_vol_key, hodl_amt_key) do
    order_vol = data[vol_key]
    alt_vol = data[alt_vol_key]
    hodl_amt = data[hodl_amt_key]
    type = get_state_order_type(state)
    alt_type = if type == "BID", do: "ASK", else: "BID"
    [order_vol, alt_vol, type, alt_type, hodl_amt]
  end

  defp get_state_order_type(state) when state == :sell or state == :quick_sell, do: "ASK"
  defp get_state_order_type(state) when state == :buy or state == :quick_buy, do: "BID"

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

  defp post_order(
         %{old_price: order_price, new_price: order_price} = data,
         state,
         action
       ) when action == :limit_sell or action == :limit_buy do
    [data, rem_vol, _hodl_amt, type] = do_calc_vol(data, state)
    rem_vol_str = if rem_vol > 0, do: :erlang.float_to_binary(rem_vol, [{:decimals, 6}]), else: 0
    Logger.debug("Keep limit #{type} order remaining volume #{rem_vol_str} at #{order_price}")
    %{data | :next_transition => {state, {:state_timeout, @short_review_time, action}}}
  end
  defp post_order(
         %{new_price: price, pair: pair, med_mod: med_mod} = data,
         state,
         action
       ) when action == :limit_sell or action == :limit_buy do
    [data, rem_vol, hodl_amt, type] = do_calc_vol(data, state)
    bal_reserved? = if rem_vol > 0, do: stop_order(data), else: true
    bal_after_order = get_bal_after_order(data, type, rem_vol, bal_reserved?)
    if bal_after_order >= hodl_amt and rem_vol >= @min_order_vol do
      %{
        data |
        :order_id => med_mod.post_order(pair, type, rem_vol, price, "true"),
        :old_price => price,
        :next_transition => {state, {:state_timeout, @long_review_time, action}},
      }
    else
      Logger.debug("Volume below minimum, next state: #{:wait_stable}")
      %{data | :order_id => nil, :next_transition => {:wait_stable, []}}
    end
  end
  defp post_order(
         %{pair: pair, med_mod: med_mod} = data,
         state,
         action
       ) when action == :market_sell or action == :market_buy do
    [data, rem_vol, hodl_amt, type] = do_calc_vol(data, state)
    bal_reserved? = if rem_vol > 0, do: stop_order(data), else: true
    bal_after_order = get_bal_after_order(data, type, rem_vol, bal_reserved?)
    new_data =
      if bal_after_order >= hodl_amt and rem_vol >= @min_order_vol do
        med_mod.market_order(pair, type, rem_vol)
        [new_data, _rem_vol, _hodl_amt, _type] = wait_for_order_conf(data, state)
        new_data
      else
        data
      end
    %{new_data | :order_id => nil, :next_transition => {:wait_stable, []}}
  end

  defp wait_for_order_conf(data, state) do
    [data, rem_vol, hodl_amt, type] = do_calc_vol(data, state)
    if rem_vol < @min_order_vol do
      [data, rem_vol, hodl_amt, type]
    else
      wait_for_order_conf(data, state)
    end
  end

  def do_calc_vol(%{order_id: order_id} = data, state) do
    [vol_key, alt_vol_key, hodl_amt_key] = get_state_keys(state)
    [order_vol, alt_vol, type, alt_type, hodl_amt] = get_state_values(
      data,
      state,
      vol_key,
      alt_vol_key,
      hodl_amt_key
    )
    [ts, rem_vol, alt_vol] = calc_vol(data, order_vol, alt_vol, type, alt_type)
    [rem_vol, order_id] = if rem_vol < 1.0e-06, do: [0, nil], else: [rem_vol, order_id]
    [
      %{data | vol_key => rem_vol, alt_vol_key => alt_vol, :order_id => order_id, :order_time => ts},
      rem_vol,
      hodl_amt,
      type
    ]
  end

  defp calc_vol(data, order_vol, alt_vol, type, alt_type) do
    %{order_time: old_ts, ws: ws, mode: mode, med_mod: med_mod, pair: pair, order_id: order_id} = data
    sum_trades = med_mod.sum_trades(pair, old_ts, order_id, ws)
    ts = sum_trades["latest_ts"] || old_ts
    traded_vol = sum_trades[type] || 0
    alt_traded_vol = sum_trades[alt_type] || 0
    [ts] ++ get_return_values(traded_vol, order_vol, alt_traded_vol, alt_vol, mode)
  end

  defp get_return_values(traded_vol, order_vol, alt_traded_vol, alt_vol, mode) do
    rem_vol = if mode == "bot", do: order_vol - traded_vol + alt_traded_vol, else: order_vol - traded_vol
    alt_vol = if mode == "bot", do: alt_vol - alt_traded_vol + traded_vol, else: alt_vol - alt_traded_vol
    [max(rem_vol, 0), max(alt_vol, 0)]
  end


  defp get_bal_after_order(%{med_mod: med_mod, pair: pair, fee: maker_fee}, type, rem_vol, balance_reserved)
       when type == "SELL" do
    prim_curr = String.slice(pair, 0, 3)
    avail_bal = med_mod.get_avail_bal(prim_curr, balance_reserved)
    avail_bal - rem_vol * (1 + maker_fee)
  end
  defp get_bal_after_order(%{med_mod: med_mod, pair: pair}, type, rem_vol, balance_reserved) when type == "BUY" do
    sec_curr = String.slice(pair, -3, 3)
    avail_bal = med_mod.get_avail_bal(sec_curr, balance_reserved)
    {ask_price, _} = med_mod.get_ticker(pair)["ask"]
                     |> Float.parse()
    avail_bal - rem_vol * ask_price
  end
  defp get_bal_after_order(%{med_mod: med_mod, pair: pair}, type, rem_vol, balance_reserved)
       when type == "ASK" do
    prim_curr = String.slice(pair, 0, 3)
    bal = med_mod.get_avail_bal(prim_curr, balance_reserved)
    bal - rem_vol
  end
  defp get_bal_after_order(%{new_price: price, med_mod: med_mod, pair: pair}, type, rem_vol, balance_reserved)
       when type == "BID" do
    sec_curr = String.slice(pair, -3, 3)
    bal = med_mod.get_avail_bal(sec_curr, balance_reserved)
    bal - rem_vol * price
  end

  defp stop_order(%{order_id: order_id, med_mod: med_mod}) do
    case !is_nil(order_id) && med_mod.stop_order(order_id) do
      {:error, {404, _}} -> false
      _ -> true
    end
  end

  def cancel_orders(nil, _mod), do: %{}
  def cancel_orders(orders, med_mod) do
    Enum.each(
      orders,
      fn (%{order_id: id}) ->
        med_mod.stop_order(id)
      end
    )
    %{}
  end
end