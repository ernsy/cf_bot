defmodule CfLuno.Statem do
  require Logger

  use GenStateMachine
  import String, only: [to_float: 1]

  @dt_perc 0.0025
  @ut_perc 0.0025
  @stable_perc 0.0002
  @min_order_vol 0.0005

  @review_time 2000
  @trade_delta_sec 60

  #---------------------------------------------------------------------------------------------------------------------
  # api
  #---------------------------------------------------------------------------------------------------------------------

  def start_link(init_data) do
    GenStateMachine.start_link(__MODULE__, init_data, name: __MODULE__)
  end

  def pause() do
    GenStateMachine.cast(__MODULE__, :pause)
  end

  def resume() do
    GenStateMachine.cast(__MODULE__, {:resume, {:limit_sell, []}})
  end

  def set_sell_amt(amount) when is_float(amount) do
    GenStateMachine.cast(__MODULE__, {:set_data, :sell_amt, amount})
  end

  def set_buy_amt(amount) when is_float(amount) do
    GenStateMachine.cast(__MODULE__, {:set_data, :buy_amt, amount})
  end

  def set_hodl_amt(asset, amount) do
    type = cond do
      asset == "primary" -> :prim_hodl_amt
      asset == "secondary" -> :sec_hodl_amt
    end
    GenStateMachine.cast(__MODULE__, {:set_data, type, amount})
  end

  def oracle_update(msg) do
    GenStateMachine.cast(__MODULE__, {:oracle_update, msg})
  end

  def set_mode(mode) do
    GenStateMachine.cast(__MODULE__, {:set_data, :mode, mode})
  end

  #---------------------------------------------------------------------------------------------------------------------
  # callbacks
  #---------------------------------------------------------------------------------------------------------------------

  def init(%{med_mod: med_mod, pair: pair, oracle_pair: oracle_pair} = init_args) do
    orders = med_mod.list_open_orders(pair)
    :ok = cancel_orders(orders, med_mod)
    {:ok, :disk_storage} = :dets.open_file(:disk_storage, [type: :set])
    data = case :dets.lookup(:disk_storage, :data) do
      [data: %{sell_amt: _, prim_hodl_amt: _, buy_amt: _, sec_hodl_amt: _, order_time: _, mode: _} = data] ->
        data
      _ ->
        prim_curr = String.slice(pair, 0..2)
        sec_curr = String.slice(pair,-3, 3)
        %{
          sell_amt: 0,
          prim_hodl_amt: med_mod.get_avail_bal(prim_curr),
          buy_amt: 0,
          sec_hodl_amt: med_mod.get_avail_bal(sec_curr),
          order_time: :erlang.system_time(:millisecond),
          mode: "manual"
        }
    end
    {:ok, [oracle_price, datetime]} = get_oracle_price(oracle_pair)
    queue = :queue.new
    init_data = %{
      oracle_queue: {queue, 0},
      oracle_ref: {oracle_price, datetime},
      pause: false,
      order_id: nil,
      order_price: 0
    }
    new_data = Map.merge(data, init_data)
               |> Map.merge(init_args)
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
        %{oracle_queue: {queue, length},
          sell_amt: sell_amt,
          buy_amt: buy_amt,
          prim_hodl_amt: hodl_amt,
          oracle_ref: {old_price, old_datetime},
          med_mod: med_mod,
          pair: pair,
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
          sell_amt > 0 and buy_amt > 0 -> check_delta(old_price, pricef, transitions[:buy_or_sell])
          sell_amt > 0 or mode == "hodl" -> check_delta(old_price, pricef, transitions[:sell])
          buy_amt > 0 -> check_delta(old_price, pricef, transitions[:buy])
          true -> {state, []}
        end
      new_data = %{data | oracle_queue: {queue, length}, oracle_ref: {q_price, q_datetime}}
      if next_state != state do
        Logger.warn("State change:#{next_state}")
        Logger.info("old oracle price: #{old_price}, new oracle price:#{pricef}")
        Logger.info("Time between trades: #{seconds_diff}")
        new_sell_amt =
          if mode == "hodl" and sell_amt <= 0 do
            prim_curr = String.slice(pair, 0..2)
            max(med_mod.get_avail_bal(prim_curr) - hodl_amt, 0)
          else
            sell_amt
          end
        {:next_state, next_state, %{new_data | sell_amt: new_sell_amt}, next_action}
      else
        {:next_state, next_state, new_data}
      end

    else
      new_queue = :queue.in({pricef, datetime}, queue)
      new_data = %{data | oracle_queue: {new_queue, length + 1}}
      {:keep_state, new_data}
    end
  end

  def handle_event(event_type, {action, post_actions}, state, %{mode: mode} = data)
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
      {:keep_state, new_data, [{:state_timeout, @review_time, {action, []}} | post_actions]}
    else
      next_state = if mode == "hodl", do: :wait_stable, else: state
      Logger.warn("State change: #{next_state}")
      {:next_state, :wait_stable, %{data | vol_key => 0, :order_price => 0}, []}
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
    :ok = cancel_orders(orders, mod)
    trades = mod.sum_trades(pair, order_ts, id)
    vol_sold = trades["ASK"]
    vol_bought = trades["BID"]
    new_data =
      %{data | order_id: nil, order_price: 0, sell_amt: sell_amt - vol_sold, buy_amt: buy_amt - vol_bought}
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

  defp get_oracle_price(pair) do
    {:ok, %{"price" => price, "time" => time}} = CfCb.Api.get_oracle_ticker(pair)
    {float_price, _rem_bin} = Float.parse(price)
    {:ok, datetime, _} = DateTime.from_iso8601(time)
    {:ok, [float_price, datetime]}
  end

  defp check_delta(old_price, curr_price, transitions) do
    delta_perc = (curr_price - old_price) / old_price
    case delta_perc do
      change_perc when abs(change_perc) < @stable_perc -> transitions.stable
      change_perc when change_perc > @ut_perc -> transitions.up_trend
      change_perc when change_perc < -@dt_perc -> transitions.down_trend
      change_perc when change_perc > 0 -> transitions.positive
      change_perc when change_perc < 0 -> transitions.negative
    end
  end

  defp calc_limit_order_price(0, _curr_limit_vol, type, %{med_mod: med_mod, pair: pair}) do
    %{"bid" => bid, "ask" => ask} = med_mod.get_ticker(pair)
    Logger.info("Bid price:" <> bid <> " ask price:" <> ask)
    {bid_int, _rem_bin} = Integer.parse(bid)
    {ask_int, _rem_bin} = Integer.parse(ask)
    if type == "ASK" do
      {:ok, calc_best_price(ask_int, ask_int, bid_int, type)}
    else
      {:ok, calc_best_price(bid_int, bid_int, ask_int, type)}
    end
  end
  defp calc_limit_order_price(pre_vol, curr_vol, type, %{order_price: curr_price, med_mod: req_mod, pair: pair}) do
    %{"asks" => asks, "bids" => bids} = req_mod.get_orderbook(pair)
    {type_orders, alt_orders} = if type == "ASK", do: {asks, bids}, else: {bids, asks}
    Enum.reduce_while(
      type_orders,
      {0, curr_vol},
      fn (%{"volume" => volume_str, "price" => price_str}, {acc_volume, curr_vol}) ->
        volume = to_float(volume_str)
        {price, _rem_bin} = Integer.parse(price_str)
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
          {best_price_int, _} = Integer.parse(best_price)
          {best_alt_price_int, _} = Integer.parse(best_alt_price)
          new_price = calc_best_price(best_price_int, price, best_alt_price_int, type)
          {:halt, {:ok, new_price}}
        else
          {:cont, {new_acc_volume, rem_limit_vol}}
        end
      end
    )
  end

  defp calc_best_price(ask_price, ask_price, bid_price, "ASK") do
    max(bid_price + 1, ask_price - 1)
  end
  defp calc_best_price(ask_price, order_price, _, "ASK") do
    max(ask_price + 1, order_price) - 1
  end
  defp calc_best_price(bid_price, bid_price, ask_price, "BID") do
    min(ask_price - 1, bid_price + 1)
  end
  defp calc_best_price(bid_price, order_price, _, "BID") do
    min(bid_price - 1, order_price) + 1
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
    Logger.info("Keep limit order #{order_id} remaining volume #{rem_vol} at #{old_price}")
    {:ok, [ts, rem_vol, alt_vol, order_id]}
  end
  defp place_limit_order(
         new_price,
         new_vol,
         alt_vol,
         hodl_amt,
         type,
         %{order_time: old_ts, order_price: old_price, order_id: order_id, mode: mode, med_mod: med_mod, pair: pair}
       ) do
    !is_nil(order_id) && med_mod.stop_order(order_id, old_price)
    Process.sleep(200)
    traded_vol = med_mod.sum_trades(pair, old_ts, order_id)[type]
    [ts, rem_vol, alt_vol] = get_return_vlaues(traded_vol, new_vol, alt_vol, mode)
    prim_curr = String.slice(pair, 0..2)
    sec_curr = String.slice(pair,-3, 3)
    bal = if type == "ASK", do: med_mod.get_avail_bal(prim_curr), else: med_mod.get_avail_bal(sec_curr)
    if bal > hodl_amt and rem_vol >= @min_order_vol do
      new_order_id = med_mod.post_order(pair, type, rem_vol, new_price, "true")
      {:ok, [ts, rem_vol, alt_vol, new_order_id]}
    else
      {:ok, [ts, 0, alt_vol, order_id]}
    end
  end

  defp get_return_vlaues(traded_vol, new_vol, alt_vol, mode) do
    rem_vol = max(new_vol - traded_vol, 0)
    alt_vol = if mode == "bot", do: alt_vol + traded_vol, else: alt_vol
    ts = :erlang.system_time(:millisecond)
    [ts, rem_vol, alt_vol]
  end

  def cancel_orders(nil, _mod), do: :ok
  def cancel_orders(orders, med_mod) do
    Enum.each(
      orders,
      fn (%{id: id, price: price}) ->
        med_mod.stop_order(id, price)
      end
    )
  end

end