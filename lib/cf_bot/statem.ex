defmodule CfBot.Statem do
  require Logger

  use GenStateMachine

  @min_order_vol 0.001
  @trade_delta_sec 60

  #---------------------------------------------------------------------------------------------------------------------
  # api
  #---------------------------------------------------------------------------------------------------------------------

  def start_link(%{name: name} = init_data) do
    GenStateMachine.start_link(__MODULE__, init_data, name: name)
  end

  def pause(name) do
    GenStateMachine.cast(name, :pause)
  end

  def resume(name) do
    GenStateMachine.cast(name, {:resume, {:limit_sell, []}})
  end

  def set_sell_amt(name, amount) when is_float(amount) do
    GenStateMachine.cast(name, {:set_data, :sell_amt, amount})
  end

  def set_buy_amt(name, amount) when is_float(amount) do
    GenStateMachine.cast(name, {:set_data, :buy_amt, amount})
  end

  def set_hodl_amt(name, asset, amount) do
    type = cond do
      asset == "primary" -> :prim_hodl_amt
      asset == "secondary" -> :sec_hodl_amt
    end
    GenStateMachine.cast(name, {:set_data, type, amount})
  end

  def oracle_update(name, msg) do
    GenStateMachine.cast(name, {:oracle_update, msg})
  end

  def set_mode(name, mode) do
    GenStateMachine.cast(name, {:set_data, :mode, mode})
  end

  #---------------------------------------------------------------------------------------------------------------------
  # callbacks
  #---------------------------------------------------------------------------------------------------------------------

  def init(
        %{
          med_mod: med_mod,
          pair: pair,
          ref_pair: ref_pair,
          min_incr: _,
          review_time: _,
          dt_pct: _,
          ut_pct: _,
          stable_pct: _,
        } = init_map
      )
    do
    {:ok, :disk_storage} = :dets.open_file(:disk_storage, [type: :set])
    data = case :dets.lookup(:disk_storage, :data) do
      [data: %{sell_amt: _, prim_hodl_amt: _, buy_amt: _, sec_hodl_amt: _, mode: _} = data] ->
        data
      _ ->
        prim_curr = String.slice(pair, 0, 3)
        sec_curr = String.slice(pair, -3, 3)
        prim_hodl_amt = med_mod.get_avail_bal(prim_curr)
        sec_hodl_amt = med_mod.get_avail_bal(sec_curr)
        %{sell_amt: 0, prim_hodl_amt: prim_hodl_amt, buy_amt: 0, sec_hodl_amt: sec_hodl_amt, mode: "manual"}
    end
    orders = med_mod.list_open_orders(pair)
    order_length = orders && length(orders)
    order_map = if  order_length == 1 do
      hd(orders)
    else
      cancel_orders(orders, med_mod)
      %{}
    end
    {:ok, [oracle_price, datetime]} = get_ref_price(ref_pair)
    queue = :queue.new
    maker_fee = med_mod.get_maker_fee()
    init_data = %{
      oracle_queue: {queue, 0},
      oracle_ref: {oracle_price, datetime},
      pause: false,
      order_id: nil,
      order_price: 0,
      order_time: :erlang.system_time(:millisecond),
      fee: maker_fee
    }
    new_data = Map.merge(data, init_data)
               |> Map.merge(init_map)
               |> Map.merge(order_map)
    Logger.info("Init data:#{inspect new_data}")
    {:ok, :wait_stable, new_data}
  end

  def handle_event(:cast, :pause, state, data) do
    Logger.info("Pausing with data:#{inspect data}, state:#{state}")
    {:keep_state, %{data | pause: true} [{:state_timeout, :infinity, :limit_sell}]}
  end

  def handle_event(:cast, {:resume, action}, state, data) do
    Logger.info("Resuming with data:#{inspect data}, state:#{state}")
    {:keep_state, %{data | pause: false}, [{:state_timeout, 0, action}]}
  end

  def handle_event(:cast, {:set_data, key, val}, state, data) do
    Logger.info("Set #{key} to:#{val}, state:#{state}")
    new_data = %{data | key => val}
    :ok = :dets.insert(:disk_storage, {:data, new_data})
    Logger.info("New data #{inspect new_data}")
    {:keep_state, new_data}
  end

  def handle_event(
        :cast,
        {:oracle_update, %{"price" => price, "time" => time}},
        state,
        %{
          oracle_queue: {queue, length},
          sell_amt: sell_amt,
          buy_amt: buy_amt,
          prim_hodl_amt: hodl_amt,
          oracle_ref: {old_price, old_datetime},
          med_mod: med_mod,
          pair: pair,
          min_incr: min_incr,
          dt_pct: dt_pct,
          ut_pct: ut_pct,
          stable_pct: s_pct,
          fee: fee,
          mode: mode
        } = data
      ) do
    {pricef, _rem_bin} = Float.parse(price)
    {:ok, datetime, _} = DateTime.from_iso8601(time)
    seconds_diff = DateTime.diff(datetime, old_datetime)
    if seconds_diff > @trade_delta_sec do
      {{:value, {q_price, q_datetime}}, queue} = :queue.out(queue)
      queue = :queue.in({pricef, datetime}, queue)
      transitions = apply(CfBot.Transitions, state, [])
      {next_state, next_action} =
        cond do
          sell_amt > 0 and buy_amt > 0 ->
            check_delta(old_price, pricef, dt_pct, ut_pct, s_pct, transitions[:buy_or_sell])
          sell_amt > 0 or mode == "hodl" ->
            check_delta(old_price, pricef, dt_pct, ut_pct, s_pct, transitions[:sell])
          buy_amt > 0 or mode == "buy" ->
            check_delta(old_price, pricef, dt_pct, ut_pct, s_pct, transitions[:buy])
          true ->
            {state, []}
        end
      new_data = %{data | oracle_queue: {queue, length}, oracle_ref: {q_price, q_datetime}}
      Logger.debug("Time between trades: #{seconds_diff}")
      do_state_change(state, next_state, next_action, pricef, new_data)
    else
      new_queue = :queue.in({pricef, datetime}, queue)
      new_data = %{data | oracle_queue: {new_queue, length + 1}}
      {:keep_state, new_data}
    end
  end

  def handle_event(event_type, {action, post_actions}, state, %{mode: mode, review_time: review_time} = data)
      when
        (event_type == :internal or event_type == :state_timeout) and (action == :limit_sell or action == :limit_buy) do
    [vol_key, alt_vol_key, hodl_amt_key, type] =
      if state == :sell or state == :quick_sell do
        [:sell_amt, :buy_amt, :prim_hodl_amt, "ASK"]
      else
        [:buy_amt, :sell_amt, :sec_hodl_amt, "BID"]
      end
    order_vol = data[vol_key]
    if order_vol >= @min_order_vol do
      alt_vol = data[alt_vol_key]
      hodl_amt = data[hodl_amt_key]
      vol_before_order = if state == :quick_sell or state == :quick_buy, do: 0, else: order_vol
      {:ok, new_price} = calc_limit_order_price(vol_before_order, order_vol, type, data)
      {:ok, [timestamp, rem_vol, alt_vol, new_order_id]} =
        place_limit_order(new_price, order_vol, alt_vol, hodl_amt, type, data)
      new_data =
        %{
          data |
          :order_time => timestamp,
          vol_key => rem_vol,
          alt_vol_key => alt_vol,
          :order_id => new_order_id,
          :order_price => new_price
        }
      :ok = :dets.insert(:disk_storage, {:data, new_data})
      {:keep_state, new_data, [{:state_timeout, review_time, {action, []}} | post_actions]}
    else
      next_state = if mode == "hodl" or mode == "buy" do
        :wait_stable
      else
        state
      end
      Logger.warn("Volume below minimum, next state: #{next_state}")
      {:next_state, next_state, %{data | vol_key => 0, :order_price => 0}, []}
    end
  end

  def handle_event(
        :internal,
        :cancel_orders,
        _state,
        %{order_time: order_ts, sell_amt: sell_amt, buy_amt: buy_amt, med_mod: mod, pair: pair, order_id: id}
        = data
      ) do
    orders = mod.list_open_orders(pair)
    %{} = cancel_orders(orders, mod)
    trades = mod.sum_trades(pair, order_ts, id)
    vol_sold = trades["ASK"]
    vol_bought = trades["BID"]
    new_sell_amt = sell_amt - vol_sold
    new_buy_amt = buy_amt - vol_bought
    new_ts = :erlang.system_time(:millisecond)
    new_data =
      %{data | order_id: nil, order_price: 0, sell_amt: new_sell_amt, buy_amt: new_buy_amt, order_time: new_ts}
    {:keep_state, new_data}
  end

  def handle_event(:info, {:ssl_closed, _}, _state, _data) do
    :keep_state_and_data
  end

  def handle_event(event_type, {id, _} = event_content, state, data)
      when (id == :limit_buy or id == :limit_sell) and state != :wait_stable do
    Logger.info("No sell or buy amount:#{inspect [type: event_type, content: event_content, state: state, data: data]}")
    :keep_state_and_data
  end

  def handle_event(event_type, event_content, state, data) do
    Logger.warn("Unhandled event:#{inspect [type: event_type, content: event_content, state: state, data: data]}")
    :keep_state_and_data
  end

  def terminate(_reason, _state, _data) do
    :dets.close(:disk_storage)
  end

  #---------------------------------------------------------------------------------------------------------------------
  # helper functions
  #---------------------------------------------------------------------------------------------------------------------

  defp get_ref_price(pair) do
    {:ok, %{"price" => price, "time" => time}} = CfCb.Api.get_oracle_ticker(pair)
    {float_price, _rem_bin} = Float.parse(price)
    {:ok, datetime, _} = DateTime.from_iso8601(time)
    {:ok, [float_price, datetime]}
  end

  defp check_delta(old_price, curr_price, dt_pct, ut_pct, stable_pct, transitions) do
    delta_pct = (curr_price - old_price) / old_price
    case delta_pct do
      change_pct when abs(change_pct) < stable_pct -> transitions.stable
      change_pct when change_pct > ut_pct -> transitions.up_trend
      change_pct when change_pct < -dt_pct -> transitions.down_trend
      change_pct when change_pct > 0 -> transitions.positive
      change_pct when change_pct < 0 -> transitions.negative
    end
  end

  defp do_state_change(
         state,
         next_state,
         next_action,
         pricef,
         %{
           order_price: old_price,
           sell_amt: sell_amt,
           buy_amt: buy_amt,
           pair: pair,
           prim_hodl_amt: p_hodl_amt,
           sec_hodl_amt: sec_hodl_amt,
           med_mod: med_mod,
           min_incr: min_incr,
           fee: fee,
           mode: mode
         } = data
       ) do
    if next_state != state do
      Logger.warn("State change:#{next_state}")
      Logger.info("old oracle price: #{old_price}, new oracle price:#{pricef}")
      new_sell_amt =
        if mode == "hodl" and sell_amt <= 0 do
          prim_curr = String.slice(pair, 0, 3)
          max(med_mod.get_avail_bal(prim_curr) - p_hodl_amt, 0)
        else
          sell_amt
        end
      new_buy_amt =
        if mode == "buy" and buy_amt <= 0 do
          sec_curr = String.slice(pair, -3, 3)
          {bid_price, _} = med_mod.get_ticker(pair)["bid"]
                           |> Float.parse()
          (med_mod.get_avail_bal(sec_curr) - sec_hodl_amt) / ((bid_price + min_incr) * (1 + fee))
        else
          buy_amt
        end
      {:next_state, next_state, %{data | sell_amt: new_sell_amt, buy_amt: new_buy_amt}, next_action}
    else
      {:next_state, next_state, data}
    end
  end

  defp calc_limit_order_price(
         0,
         _curr_limit_vol,
         type,
         %{med_mod: mod, pair: pair, min_incr: min_incr}
       ) do
    %{"bid" => bid, "ask" => ask} = mod.get_ticker(pair)
    Logger.info("Bid price:" <> bid <> " ask price:" <> ask)
    {bidf, _} = Float.parse(bid)
    {askf, _} = Float.parse(ask)
    if type == "ASK" do
      {:ok, calc_best_price(askf, askf, bidf, min_incr, type)}
    else
      {:ok, calc_best_price(bidf, bidf, askf, min_incr, type)}
    end
  end
  defp calc_limit_order_price(
         pre_vol,
         curr_vol,
         type,
         %{order_price: curr_price, med_mod: mod, pair: pair, min_incr: min_incr}
       ) do
    %{"asks" => asks, "bids" => bids} = mod.get_orderbook(pair)
    {type_orders, alt_orders} = if type == "ASK", do: {asks, bids}, else: {bids, asks}
    Enum.reduce_while(
      type_orders,
      {0, curr_vol},
      fn (%{"volume" => volume_str, "price" => price_str}, {acc_volume, curr_vol}) ->
        {volume, _} = Float.parse(volume_str)
        {price, _} = Float.parse(price_str)
        {new_acc_volume, rem_limit_vol} =
          if curr_vol > 0 and ((type == "ASK" and price >= curr_price) or (type == "BID" and price <= curr_price)) do
            new_acc_volume = acc_volume + volume - curr_vol
            {new_acc_volume, 0}
          else
            new_acc_volume = acc_volume + volume
            {new_acc_volume, curr_vol}
          end
        if new_acc_volume > pre_vol do
          %{"price" => best_price, "volume" => best_vol} = hd(type_orders)
          %{"price" => best_alt_price, "volume" => best_alt_vol} = hd(alt_orders)
          Logger.info(
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

  defp place_limit_order(
         new_price,
         new_vol,
         alt_vol,
         _hodl_amt,
         type,
         %{order_time: old_ts, order_price: old_price, order_id: order_id, mode: mode, med_mod: med_mod, pair: pair}
       )
       when old_price == new_price do
    traded_vol = med_mod.sum_trades(pair, old_ts, order_id)[type]
    [ts, rem_vol, alt_vol] = get_return_vlaues(traded_vol, new_vol, alt_vol, mode)
    rem_vol_str = :erlang.float_to_binary(rem_vol, [{:decimals, 6}])
    Logger.info("Keep limit order #{order_id} remaining volume #{rem_vol_str} at #{old_price}")
    {:ok, [ts, rem_vol, alt_vol, order_id]}
  end
  defp place_limit_order(
         new_price,
         new_vol,
         alt_vol,
         hodl_amt,
         type,
         %{
           order_time: old_ts,
           order_price: old_price,
           order_id: order_id,
           mode: mode,
           med_mod: med_mod,
           pair: pair,
           min_incr: min_incr,
           fee: fee
         }
       ) do
    !is_nil(order_id) && med_mod.stop_order(order_id, old_price)
    traded_vol = med_mod.sum_trades(pair, old_ts, order_id)[type]
    [ts, rem_vol, alt_vol] = get_return_vlaues(traded_vol, new_vol, alt_vol, mode)
    prim_curr = String.slice(pair, 0, 3)
    sec_curr = String.slice(pair, -3, 3)
    [bal, adj_rem_vol] =
      if type == "ASK" do
        [med_mod.get_avail_bal(prim_curr), rem_vol]
      else
        bal = med_mod.get_avail_bal(sec_curr)
        adj_rem_vol = min(rem_vol, (bal - hodl_amt) / ((new_price + min_incr) * (1 + fee)))
        [bal, adj_rem_vol]
      end
    if bal > hodl_amt and adj_rem_vol >= @min_order_vol do
      new_order_id = med_mod.post_order(pair, type, adj_rem_vol, new_price, "true")
      {:ok, [ts, adj_rem_vol, alt_vol, new_order_id]}
    else
      {:ok, [ts, 0, alt_vol, order_id]}
    end
  end

  defp get_return_vlaues(traded_vol, new_vol, alt_vol, mode) do
    rem_vol = max(new_vol - traded_vol, 0.0)
    alt_vol = if mode == "bot", do: alt_vol + traded_vol, else: alt_vol
    ts = :erlang.system_time(:millisecond)
    [ts, rem_vol, alt_vol]
  end

  def cancel_orders(nil, _mod), do: %{}
  def cancel_orders(orders, med_mod) do
    Enum.each(
      orders,
      fn (%{order_id: id, order_price: price}) ->
        med_mod.stop_order(id, price)
      end
    )
    %{}
  end

end