defmodule CfLuno.Statem do
  require Logger

  use GenStateMachine
  alias CfLuno.Transitions, as: Transitions
  import String, only: [to_float: 1]

  @dt_perc 0.002
  @ut_perc 0.002
  @stable_perc 0.0005
  @min_btc_order_vol 0.0005

  @review_time 3000
  @trade_delta 50

  #---------------------------------------------------------------------------------------------------------------------
  # api
  #---------------------------------------------------------------------------------------------------------------------

  def start_link(init_data) do
    GenStateMachine.start_link(__MODULE__, init_data, name: __MODULE__)
  end

  def check_oracle_price() do
    GenStateMachine.cast(__MODULE__, :check_oracle_price)
  end

  def pause() do
    GenStateMachine.cast(__MODULE__, :pause)
  end

  def set_sell_amt(amount) when is_float(amount) do
    GenStateMachine.cast(__MODULE__, {:set_amt, :btc_sell_amt, amount})
  end

  def set_buy_amt(amount) when is_float(amount) do
    GenStateMachine.cast(__MODULE__, {:set_amt, :btc_buy_amt, amount})
  end

  def set_hodl_amt(asset, amount) do
    type = cond do
      asset == "BTC" -> :btc_hodl_amt
      asset == "ZAR" -> :zar_hodl_amt
    end
    GenStateMachine.cast(__MODULE__, {:set_amt, type, amount})
  end

  def oracle_update(msg) do
    GenStateMachine.cast(__MODULE__, {:oracle_update, msg})
  end

  #---------------------------------------------------------------------------------------------------------------------
  # callbacks
  #---------------------------------------------------------------------------------------------------------------------

  def init(_init_data) do
    {:ok, :disk_storage} = :dets.open_file(:disk_storage, [type: :set])
    data = case :dets.lookup(:disk_storage, :data) do
      [data: %{btc_sell_amt: _, btc_hodl_amt: _, btc_buy_amt: _, zar_hodl_amt: _, last_order_time: _} = data] ->
        data
      _ ->
        %{
          btc_sell_amt: 0,
          btc_hodl_amt: get_bal("XBT"),
          btc_buy_amt: 0,
          zar_hodl_amt: get_bal("ZAR"),
          last_order_time: :erlang.system_time(:millisecond)
        }
    end
    {:ok, [oracle_price, time]} = get_oracle_price()
    queue = :queue.new
    queue = :queue.in({oracle_price, time}, queue)
    init_data = %{oracle_price: oracle_price, oracle_queue: {queue, 1}, pause: false}
    new_data = Map.merge(data, init_data)
    Logger.info("Init data:#{inspect new_data}")
    {:ok, :wait_stable, new_data}
  end

  def handle_event(:cast, :pause, state, data) do
    Logger.info("Pausing with data:#{inspect data}, state:#{inspect state}")
    {:keep_state, %{data | pause: true} [{:state_timeout, :infinity, :limit_sell}]}
  end

  def handle_event(:cast, {:set_amt, type, amt}, state, data) do
    Logger.info("Set #{inspect type} amount:#{inspect amt}, state:#{inspect state}")
    new_data = %{data | type => amt}
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
          btc_buy_amt: btc_buy_amt
        } = data
      ) do
    {float_price, _rem_bin} = Float.parse(price)
    if length > @trade_delta do
      {{:value, {old_price, old_time}}, queue} = :queue.out(queue)
      new_queue = :queue.in({float_price, time}, queue)
      transitions = case state do
        :wait_stable -> Transitions.wait_stable()
        state when state == :sell or state == :quick_sell -> Transitions.sell()
        state when state == :buy or state == :quick_buy -> Transitions.buy()
      end
      {next_state, next_action} =
        cond do
          btc_sell_amt > 0 and btc_buy_amt > 0 ->
            check_delta(old_price, float_price, transitions[:btc_and_zar])
          btc_sell_amt > 0 ->
            check_delta(old_price, float_price, transitions[:only_btc])
          btc_buy_amt > 0 ->
            check_delta(old_price, float_price, transitions[:only_zar])
          true -> {state, []}
        end
      new_data = %{data | oracle_queue: {new_queue, length}}
      if next_state != state do
        Logger.warn("State change:#{inspect next_state}")
        Logger.info("old oracle price: #{inspect old_price}, new oracle price:#{inspect float_price}")
        {:ok, old_datetime, _} = DateTime.from_iso8601(old_time)
        {:ok, datetime, _} = DateTime.from_iso8601(time)
        seconds_diff = DateTime.diff(datetime, old_datetime)
        Logger.info("Time between trades: #{inspect seconds_diff}")
        {:next_state, next_state, new_data, next_action}
      else
        {:next_state, next_state, new_data}
      end

    else
      new_queue = :queue.in({float_price, time}, queue)
      new_data = %{data | oracle_queue: {new_queue, length + 1}}
      {:keep_state, new_data}
    end
  end

  def handle_event(
        event_type,
        {:limit_sell, post_actions},
        :sell,
        %{btc_sell_amt: sell_amt, btc_hodl_amt: hodl_amt, last_order_time: order_time} = data
      )
      when sell_amt >= @min_btc_order_vol and (event_type == :internal or event_type == :state_timeout)  do
    {:ok, %{"orders" => orders}} = CfLuno.Api.list_orders("XBTZAR", "PENDING")
    {:ok, [curr_price, curr_vol, order_id, new_price]} = process_orders(orders, sell_amt, "asks")
    bal = get_bal("XBT")
    new_data =
      process_limit_order(curr_price, curr_vol, order_id, order_time, new_price, sell_amt, hodl_amt, bal, data, "ASK")
    {:keep_state, new_data, [{:state_timeout, @review_time, {:limit_sell, []}} | post_actions]}
  end

  def handle_event(
        event_type,
        {:limit_sell, post_actions},
        :quick_sell,
        %{btc_sell_amt: sell_amt, btc_hodl_amt: hodl_amt, last_order_time: order_time} = data
      )
      when sell_amt >= @min_btc_order_vol and (event_type == :internal or event_type == :state_timeout) do
    {:ok, %{"orders" => orders}} = CfLuno.Api.list_orders("XBTZAR", "PENDING")
    {:ok, [curr_price, curr_vol, order_id, new_price]} = process_orders(orders, 0, "asks")
    bal = get_bal("XBT")
    new_data =
      process_limit_order(curr_price, curr_vol, order_id, order_time, new_price, sell_amt, hodl_amt, bal, data, "ASK")
    {:keep_state, new_data, [{:state_timeout, @review_time, {:limit_sell, []}} | post_actions]}
  end

  #[type: :state_timeout, content: {:limit_sell, []}, state: :buy, data: %{btc_buy_amt: 0.0005, btc_hodl_amt: 0.9792, btc_sell_amt: 0.0
  def handle_event(
        event_type,
        {:limit_buy, post_actions},
        :buy,
        %{btc_buy_amt: buy_amt, zar_hodl_amt: hodl_amt, last_order_time: order_time} = data
      )
      when buy_amt >= @min_btc_order_vol and (event_type == :internal or event_type == :state_timeout)  do
    {:ok, %{"orders" => orders}} = CfLuno.Api.list_orders("XBTZAR", "PENDING")
    {:ok, [curr_price, curr_vol, order_id, new_price]} = process_orders(orders, buy_amt, "bids")
    bal = get_bal("ZAR")
    new_data =
      process_limit_order(curr_price, curr_vol, order_id, order_time, new_price, buy_amt, hodl_amt, bal, data, "BID")
    {:keep_state, new_data, [{:state_timeout, @review_time, {:limit_buy, []}} | post_actions]}
  end

  def handle_event(
        event_type,
        {:limit_buy, post_actions},
        :quick_buy,
        %{btc_buy_amt: buy_amt, zar_hodl_amt: hodl_amt, last_order_time: order_time} = data
      )
      when buy_amt >= @min_btc_order_vol and (event_type == :internal or event_type == :state_timeout)  do
    {:ok, %{"orders" => orders}} = CfLuno.Api.list_orders("XBTZAR", "PENDING")
    {:ok, [curr_price, curr_vol, order_id, new_price]} = process_orders(orders, 0, "bids")
    bal = get_bal("ZAR")
    new_data =
      process_limit_order(curr_price, curr_vol, order_id, order_time, new_price, buy_amt, hodl_amt, bal, data, "BID")
    {:keep_state, new_data, [{:state_timeout, @review_time, {:limit_buy, []}} | post_actions]}
  end



  def handle_event(:internal, :cancel_orders, _state, _data) do
    {:ok, %{"orders" => orders}} = CfLuno.Api.list_orders("XBTZAR", "PENDING")
    :ok = cancel_orders(orders)
    :keep_state_and_data
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
    {:ok, [float_price, time]}
  end

  defp get_bal(asset) do
    {
      :ok,
      %{"balance" => [%{"balance" => avail_bal, "unconfirmed" => unconf_bal, "reserved" => reserved}]}
    } = CfLuno.Api.balance(asset)
    to_float(avail_bal) + to_float(unconf_bal) - to_float(reserved)
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

  defp process_orders(nil, before_limit_vol, type) do
    {:ok, new_price} = calc_limit_order_price(before_limit_vol, 0, 0, type)
    {:ok, [0, 0, "0", new_price]}
  end
  defp process_orders(orders, before_limit_vol, type) when length(orders) > 1 do
    :ok = cancel_orders(orders)
    {:ok, new_price} = calc_limit_order_price(before_limit_vol, 0, 0, type)
    {:ok, [0, 0, "0", new_price]}
  end
  defp process_orders(
         [%{"limit_price" => limit_price, "limit_volume" => limit_volume, "order_id" => order_id}],
         before_limit_vol,
         type
       ) do
    {curr_price, _} = Integer.parse(limit_price)
    curr_vol = limit_volume
               |> to_float()
               |> Float.round(6)
    {:ok, new_price} = calc_limit_order_price(before_limit_vol, curr_price, curr_vol, type)
    {:ok, [curr_price, curr_vol, order_id, new_price]}
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
    {type_orders, alt_orders} = if type == "asks", do: {asks, bids}, else: {bids, asks}
    Enum.reduce_while(
      type_orders,
      {0, curr_vol},
      fn (order, {acc_volume, curr_vol}) ->
        volume = to_float(order["volume"])
        {price, _rem_bin} = Integer.parse(order["price"])
        {new_acc_volume, rem_limit_vol} =
          if curr_vol > 0 and ((type == "asks" and price >= curr_price) or (type == "bids" and price <= curr_price)) do
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
            <> ". Best alt price:" <> best_alt_price <> ", volume:" <> best_alt_vol)
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

  defp calc_best_price(ask_price, ask_price, bid_price, "asks") do
    max(bid_price + 1, ask_price - 1)
  end
  defp calc_best_price(ask_price, order_price, _, "asks") do
    max(ask_price + 1, order_price) - 1
  end
  defp calc_best_price(bid_price, bid_price, ask_price, "bids") do
    min(ask_price - 1, bid_price + 1)
  end
  defp calc_best_price(bid_price, order_price, _, "bids") do
    min(bid_price - 1, order_price) + 1
  end

  defp process_limit_order(old_price, old_vol, order_id, old_timestamp, new_price, sell_amt, hodl_amt, bal, data, type)
       when bal > hodl_amt do
    {:ok, [timestamp, new_sell_amt]} =
      place_limit_order(old_price, old_vol, order_id, old_timestamp, new_price, sell_amt, type)
    sell_amt_key = if type == "ASK", do: :btc_sell_amt, else: :btc_buy_amt
    new_data = %{data | :last_order_time => timestamp, sell_amt_key => new_sell_amt}
    :ok = :dets.insert(:disk_storage, {:data, new_data})
    new_data
  end
  defp process_limit_order(old_price, _, order_id, _, _, _, _, _bal, data, type)  do
    if order_id != "0" do
      {:ok, %{"success" => true}} = CfLuno.Api.stop_order(order_id, old_price)
    end
    timestamp = :erlang.system_time(:millisecond)
    sell_amt_key = if type == "ASK", do: :btc_sell_amt, else: :btc_buy_amt
    new_data = %{data | :last_order_time => timestamp, sell_amt_key => 0}
    :ok = :dets.insert(:disk_storage, {:data, new_data})
    new_data
  end

  defp place_limit_order(old_price, old_vol, order_id, old_timestamp, new_price, new_vol, type)
       when old_price == new_price and old_vol >= new_vol do
    {:ok, %{"trades" => trades}} = CfLuno.Api.list_trades([pair: "XBTZAR", since: old_timestamp])
    traded_vol = get_traded_volume_since(trades, type)
    rem_vol = max(new_vol - traded_vol, 0)
    timestamp = :erlang.system_time(:millisecond)
    Logger.info("Keep Limit order #{inspect order_id} for #{inspect old_vol} at #{inspect old_price}")
    {:ok, [timestamp, rem_vol]}
  end
  defp place_limit_order(0, 0, "0", old_timestamp, new_price, new_vol, type) do
    {:ok, %{"trades" => trades}} = CfLuno.Api.list_trades([pair: "XBTZAR", since: old_timestamp])
    traded_vol = get_traded_volume_since(trades, type)
    timestamp = timestamp = :erlang.system_time(:millisecond)
    rem_vol = new_vol - traded_vol
    if rem_vol >= @min_btc_order_vol do
      {:ok, %{"order_id" => _new_order_id}} = CfLuno.Api.post_order("XBTZAR", type, rem_vol, new_price, "true")
      {:ok, [timestamp, rem_vol]}
    else
      {:ok, [timestamp, 0]}
    end
  end
  defp place_limit_order(old_price, _old_vol, order_id, old_timestamp, new_price, new_vol, type) do
    {:ok, %{"success" => true}} = CfLuno.Api.stop_order(order_id, old_price)
    {:ok, %{"trades" => trades}} = CfLuno.Api.list_trades([pair: "XBTZAR", since: old_timestamp])
    traded_vol = get_traded_volume_since(trades, type)
    timestamp = timestamp = :erlang.system_time(:millisecond)
    rem_vol = new_vol - traded_vol
    if rem_vol >= @min_btc_order_vol do
      {:ok, %{"order_id" => _new_order_id}} = CfLuno.Api.post_order("XBTZAR", type, rem_vol, new_price, "true")
      {:ok, [timestamp, rem_vol]}
    else
      {:ok, [timestamp, 0]}
    end
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