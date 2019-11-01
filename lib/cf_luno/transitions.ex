defmodule CfLuno.Transitions do
  @moduledoc false

  @short_stable_delta_time 15000
  @long_stable_delta_time 30000
  @unstable_delta_time 60000

  @short_stable_timeout_action {{:timeout, :check_oracle_price}, @short_stable_delta_time, :check_oracle_price}
  @long_stable_timeout_action {{:timeout, :check_oracle_price}, @long_stable_delta_time, :check_oracle_price}
  @unstable_timeout_action {{:timeout, :check_oracle_price}, @unstable_delta_time, :check_oracle_price}

  @quick_limit_sell_action {:next_event, :internal, {:limit_sell, []}}
  @quick_limit_buy_action {:next_event, :internal, {:limit_buy, []}}
  @limit_sell_action {:next_event, :internal, {:limit_sell, []}}
  @limit_buy_action {:next_event, :internal, {:limit_buy, []}}
  @cancel_order_action {:next_event, :internal, :cancel_orders}

  def wait_stable() do
    %{
      btc_and_zar:
      %{
        stable: {:sell, @limit_sell_action},
        up_trend: {:quick_buy, @quick_limit_buy_action},
        down_trend: {:quick_sell, @quick_limit_sell_action},
        positive: {:buy, @limit_buy_action},
        negative: {:sell, @limit_sell_action}
      },
      only_btc:
      %{
        stable: {:sell, @limit_sell_action},
        up_trend: {:wait_stable, []},
        down_trend: {:quick_sell, @quick_limit_sell_action},
        positive: {:wait_stable, []},
        negative: {:sell, @limit_sell_action}
      },
      only_zar:
      %{
        stable: {:buy, @limit_buy_action},
        up_trend: {:quick_buy, @quick_limit_buy_action},
        down_trend: {:wait_stable, []},
        positive: {:buy, @limit_buy_action},
        negative: {:wait_stable, []}
      }
    }
  end

  def sell() do
    %{
      btc_and_zar:
      %{
        stable: {:sell, @limit_sell_action},
        up_trend: {:quick_buy, [@cancel_order_action, @quick_limit_buy_action]},
        down_trend: {:quick_sell, @quick_limit_sell_action},
        positive: {:sell, @limit_sell_action},
        negative: {:sell, @limit_sell_action}
      },
      only_btc:
      %{
        stable: {:sell, @limit_sell_action},
        up_trend: {:wait_stable, [@cancel_order_action]},
        down_trend: {:quick_sell, @quick_limit_sell_action},
        positive: {:sell, @limit_sell_action},
        negative: {:sell, @limit_sell_action}
      },
      only_zar:
      %{
        stable: {:wait_stable, []},
        up_trend: {:quick_buy, [@cancel_order_action, @quick_limit_buy_action]},
        down_trend: {:wait_stable, []},
        positive: {:wait_stable, []},
        negative: {:wait_stable, []}
      }
    }
  end

  def buy() do
    %{
      btc_and_zar:
      %{
        stable: {:buy, @limit_buy_action},
        up_trend: {:quick_buy, @quick_limit_buy_action},
        down_trend: {:quick_sell, [@cancel_order_action, @quick_limit_sell_action]},
        positive: {:buy, @limit_buy_action},
        negative: {:buy, @limit_sell_action}
      },
      only_btc:
      %{
        stable: {:wait_stable, []},
        up_trend: {:wait_stable, []},
        down_trend: {:quick_sell, [@cancel_order_action, @quick_limit_sell_action]},
        positive: {:wait_stable, []},
        negative: {:wait_stable, []}
      },
      only_zar:
      %{
        stable: {:buy, @limit_buy_action},
        up_trend: {:quick_buy, @quick_limit_buy_action},
        down_trend: {:wait_stable, []},
        positive: {:buy, @limit_buy_action},
        negative: {:buy, @limit_buy_action}
      }
    }
  end

end
