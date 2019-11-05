defmodule CfLuno.Statem do
  require Logger

  use GenStateMachine
  import String, only: [to_float: 1]

  @dt_perc 0.002
  @ut_perc 0.002
  @stable_perc 0.0002
  @min_btc_order_vol 0.0005

  @review_time 3000
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
    GenStateMachine.cast(__MODULE__, {:resume, :limit_sell})
  end

  def set_sell_amt(amount) when is_float(amount) do
    GenStateMachine.cast(__MODULE__, {:set_data, :btc_sell_amt, amount})
  end

  def set_buy_amt(amount) when is_float(amount) do
    GenStateMachine.cast(__MODULE__, {:set_data, :btc_buy_amt, amount})
  end

  def set_hodl_amt(asset, amount) do
    type = cond do
      asset == "BTC" -> :btc_hodl_amt
      asset == "ZAR" -> :zar_hodl_amt
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

  def init(_init_data) do
    {:ok, %{"orders" => orders}} = CfLuno.Api.list_orders("XBTZAR", "PENDING")
    :ok = cancel_orders(orders)
    {:ok, :disk_storage} = :dets.open_file(:disk_storage, [type: :set])
    data = case :dets.lookup(:disk_storage, :data) do
      [data: %{btc_sell_amt: _, btc_hodl_amt: _, btc_buy_amt: _, zar_hodl_amt: _, order_time: _, mode: _} = data] ->
        data
      _ ->
        %{
          btc_sell_amt: 0,
          btc_hodl_amt: get_bal("XBT"),
          btc_buy_amt: 0,
          zar_hodl_amt: get_bal("ZAR"),
          order_time: :erlang.system_time(:millisecond),
          mode: "Manual"
        }
    end
    {:ok, [oracle_price, datetime]} = get_oracle_price()
    queue = :queue.new
    init_data = %{oracle_queue: {queue, 0}, oracle_ref: {oracle_price, datetime}, pause: false, order_id: 0, order_price: 0}
    new_data = Map.merge(data, init_data)
    Logger.info("Init data:#{inspect new_data}")
    {:ok, :wait_stable, new_data}
  end

  def handle_event(:cast, :pause, state, data) do
    Logger.info("Pausing with data:#{inspect data}, state:#{inspect state}")
    {:keep_state, %{data | pause: true} [{:state_timeout, :infinity, :limit_sell}]}
  end

  def handle_event(:cast, {:set_data, key, val}, state, data) do
    Logger.info("Set #{inspect key} to:#{inspect val}, state:#{inspect state}")
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
          btc_sell_amt: btc_sell_amt,
          btc_buy_amt: btc_buy_amt,
          oracle_ref: {old_price, old_datetime}
        } = data
      ) do
    {float_price, _rem_bin} = Float.parse(price)
    {:ok, datetime, _} = DateTime.from_iso8601(time)
    seconds_diff = DateTime.diff(datetime, old_datetime)
    if seconds_diff > @trade_delta_sec do
      {{:value, {q_price, q_datetime}}, queue} = :queue.out(queue)
      queue = :queue.in({float_price, datetime}, queue)
      transitions = apply(CfLuno.Transitions, state, [])
      {next_state, next_action} =
        cond do
          btc_sell_amt > 0 and btc_buy_amt > 0 -> check_delta(old_price, float_price, transitions[:buy_or_sell])
          btc_sell_amt > 0 -> check_delta(old_price, float_price, transitions[:sell])
          btc_buy_amt > 0 -> check_delta(old_price, float_price, transitions[:buy])
          true -> {state, []}
        end
      new_data = %{data | oracle_queue: {queue, length}, oracle_ref: {q_price, q_datetime}}
      if next_state != state do
        Logger.warn("State change:#{inspect next_state}")
        Logger.info("old oracle price: #{inspect old_price}, new oracle price:#{inspect float_price}")
        Logger.info("Time between trades: #{inspect seconds_diff}")
        {:next_state, next_state, new_data, next_action}
      else
        {:next_state, next_state, new_data}
      end

    else
      new_queue = :queue.in({float_price, datetime}, queue)
      new_data = %{data | oracle_queue: {new_queue, length + 1}}
      {:keep_state, new_data}
    end
  end

  def handle_event(event_type, {action, post_actions}, state, %{order_price: old_price} = data)
      when
        (event_type == :internal or event_type == :state_timeout) and (action == :limit_sell or action == :limit_buy) do
    [vol_key, alt_vol_key, hodl_amt_key, type] =
      if state == :sell or state == :quick_sell do
        [:btc_sell_amt, :btc_buy_amt, :btc_hodl_amt, "ASK"]
      else
        [:btc_buy_amt, :btc_sell_amt, :zar_hodl_amt, "BID"]
      end
    order_vol = data[vol_key]
    if order_vol >= @min_btc_order_vol do
      alt_vol = data[alt_vol_key]
      hodl_amt = data[hodl_amt_key]
      vol_before_order = if state == :quick_sell or state == :quick_buy, do: 0, else: order_vol
      {:ok, new_price} = calc_limit_order_price(vol_before_order, old_price, order_vol, type)
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
      :keep_state_and_data
    end

  end

  def handle_event(
        :internal,
        :cancel_orders,
        _state,
        %{order_time: last_order_time, btc_sell_amt: btc_sell_amt, btc_buy_amt: btc_buy_amt} = data
      ) do
    {:ok, %{"orders" => orders}} = CfLuno.Api.list_orders("XBTZAR", "PENDING")
    :ok = cancel_orders(orders)
    {:ok, %{"trades" => trades}} = CfLuno.Api.list_trades([pair: "XBTZAR", since: last_order_time])
    vol_sold = get_traded_volume_since(trades, "ASK")
    vol_bought = get_traded_volume_since(trades, "BID")
    new_data =
      %{
        data |
        order_id: 0,
        order_price: 0,
        btc_sell_amt: btc_sell_amt - vol_sold,
        btc_buy_amt: btc_buy_amt - vol_bought
      }
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

  defp get_oracle_price() do
    {:ok, %{"price" => price, "time" => time}} = CfLuno.Api.get_cb_ticker("BTC-USD")
    {float_price, _rem_bin} = Float.parse(price)
    {:ok, datetime, _} = DateTime.from_iso8601(time)
    {:ok, [float_price, datetime]}
  end

  defp get_bal(asset) do
    {
      :ok,
      %{"balance" => [%{"balance" => avail_bal, "unconfirmed" => unconf_bal, "reserved" => reserved}]}
    } = CfLuno.Api.balance(asset)
    avail_bal = to_float(avail_bal) + to_float(unconf_bal) - to_float(reserved)
    Logger.info("Avaialable #{inspect asset} balance: #{inspect avail_bal}")
    avail_bal
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

  defp calc_limit_order_price(0, _curr_limit_price, _curr_limit_vol, type) do
    {:ok, %{"bid" => bid, "ask" => ask}} = CfLuno.Api.get_ticker("XBTZAR")
    Logger.info("Luno bid price:" <> bid <> " ask price:" <> ask)
    {bid_int, _rem_bin} = Integer.parse(bid)
    {ask_int, _rem_bin} = Integer.parse(ask)
    if type == "asks" do
      {:ok, calc_best_price(ask_int, ask_int, bid_int, type)}
    else
      {:ok, calc_best_price(bid_int, bid_int, ask_int, type)}
    end
  end
  defp calc_limit_order_price(before_limit_vol, curr_price, curr_vol, type) do
    {:ok, %{"asks" => asks, "bids" => bids}} = CfLuno.Api.get_orderbook_top("XBTZAR")
    {type_orders, alt_orders} = if type == "ASK", do: {asks, bids}, else: {bids, asks}
    Enum.reduce_while(
      type_orders,
      {0, curr_vol},
      fn (order, {acc_volume, curr_vol}) ->
        volume = to_float(order["volume"])
        {price, _rem_bin} = Integer.parse(order["price"])
        {new_acc_volume, rem_limit_vol} =
          if curr_vol > 0 and ((type == "ASK" and price >= curr_price) or (type == "BID" and price <= curr_price)) do
            new_acc_volume = acc_volume + volume - curr_vol
            {new_acc_volume, 0}
          else
            new_acc_volume = acc_volume + volume
            {new_acc_volume, curr_vol}
          end
        if new_acc_volume > before_limit_vol do
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
         %{order_time: old_timestamp, order_price: old_price, order_id: order_id, mode: mode}
       )
       when old_price == new_price do
    [timestamp, rem_vol, alt_vol] = get_return_vlaues(old_timestamp, type, new_vol, alt_vol, mode)
    Logger.info("Limit order #{inspect order_id} remaining volume #{inspect rem_vol} at #{inspect old_price}")
    {:ok, [timestamp, rem_vol, alt_vol, order_id]}
  end
  defp place_limit_order(
         new_price,
         new_vol,
         alt_vol,
         hodl_amt,
         type,
         %{order_time: old_timestamp, order_price: old_price, order_id: order_id, mode: mode}
       ) do
    CfLuno.Api.stop_order(order_id, old_price)
    [timestamp, rem_vol, alt_vol] = get_return_vlaues(old_timestamp, type, new_vol, alt_vol, mode)
    bal = if type == "ASK", do: get_bal("XBT"), else: get_bal("ZAR")
    if bal > hodl_amt and rem_vol >= @min_btc_order_vol do
      {:ok, %{"order_id" => new_order_id}} = CfLuno.Api.post_order("XBTZAR", type, rem_vol, new_price, "true")
      {:ok, [timestamp, rem_vol, alt_vol, new_order_id]}
    else
      {:ok, [timestamp, 0, alt_vol, order_id]}
    end
  end

  defp get_return_vlaues(old_timestamp, type, new_vol, alt_vol, mode) do
    {:ok, %{"trades" => trades}} = CfLuno.Api.list_trades([pair: "XBTZAR", since: old_timestamp])
    traded_vol = get_traded_volume_since(trades, type)
    rem_vol = max(new_vol - traded_vol, 0)
    alt_vol = if mode == "Bot", do: alt_vol + traded_vol, else: alt_vol
    timestamp = :erlang.system_time(:millisecond)
    [timestamp, rem_vol, alt_vol]
  end

  defp get_traded_volume_since(nil, _type), do: 0
  defp get_traded_volume_since(trades, type) do
    Enum.reduce(
      trades,
      0,
      fn
        (%{"type" => order_type, "volume" => volume}, vol_acc) when order_type == type -> vol_acc + to_float(volume)
        (_, vol_acc) -> vol_acc
      end
    )
  end

  def cancel_orders(nil), do: :ok
  def cancel_orders(orders) do
    Enum.each(
      orders,
      fn (order) ->
        order_id = order["order_id"]
        price = order["limit_price"]
        {:ok, %{"success" => true}} = CfLuno.Api.stop_order(order_id, price)
      end
    )
  end

end