defmodule CfLuno.StateConstants do

  def short_stable_delta_time, do: 15000
  def long_stable_delta_time, do: 30000
  def unstable_delta_time, do: 60000
  def order_review_time, do: 5000

  def short_stable_timeout_action, do: {{:timeout, :check_oracle_price}, short_stable_delta_time(), :check_oracle_price}
  def long_stable_timeout_action, do: {{:timeout, :check_oracle_price}, long_stable_delta_time(), :check_oracle_price}
  def unstable_timeout_action, do: {{:timeout, :check_oracle_price}, unstable_delta_time(), :check_oracle_price}
  def order_review_timeout_action, do: {:state_timeout, order_review_time(), :limit_sell}
  def pause_timeout_actions, do: [
                               {{:timeout, :check_oracle_price}, :infinity, :check_oracle_price},
                               {:state_timeout, :infinity, :limit_sell}
  ]

  def quick_limit_sell_action, do: {:next_event, :internal, {:limit_sell, short_stable_timeout_action()}}
  def quick_limit_buy_action, do: {:next_event, :internal, {:limit_buy, short_stable_timeout_action()}}
  def limit_sell_action, do: {:next_event, :internal, {:limit_sell, long_stable_timeout_action()}}
  def limit_buy_action, do: {:next_event, :internal, {:limit_buy, long_stable_timeout_action()}}
  def cancel_order_action, do: {:next_event, :internal, :cancel_order}

  def wait_stable do
    %{
      btc_and_zar:
      %{
        stable: {:sell, limit_sell_action()},
        up_trend: {:quick_buy, quick_limit_buy_action()},
        down_trend: {:quick_sell, quick_limit_sell_action()},
        positive: {:buy, limit_buy_action()},
        negative: {:sell, limit_sell_action()}
      },
      only_btc:
      %{
        stable: {:sell, limit_sell_action()},
        up_trend: {:wait_stable, unstable_timeout_action()},
        down_trend: {:quick_sell, quick_limit_sell_action()},
        positive: {:wait_stable, unstable_timeout_action()},
        negative: {:sell, limit_sell_action()}
      },
      only_zar:
      %{
        stable: {:buy, limit_buy_action()},
        up_trend: {:quick_buy, quick_limit_buy_action()},
        down_trend: {:wait_stable, unstable_timeout_action()},
        positive: {:buy, limit_buy_action()},
        negative: {:wait_stable, unstable_timeout_action()}
      }
    }
  end

  def sell do
    %{
      btc_and_zar:
      %{
        stable: {:sell, limit_sell_action()},
        up_trend: {:quick_buy, quick_limit_buy_action()},
        down_trend: {:quick_sell, quick_limit_sell_action()},
        positive: {:sell, limit_sell_action()},
        negative: {:sell, limit_sell_action()}
      },
      only_btc:
      %{
        stable: {:sell, limit_sell_action()},
        up_trend: {:wait_stable, unstable_timeout_action()},
        down_trend: {:quick_sell, quick_limit_sell_action()},
        positive: {:sell, limit_sell_action()},
        negative: {:sell, limit_sell_action()}
      },
      only_zar:
      %{
        stable: {:wait_stable, unstable_timeout_action()},
        up_trend: {:quick_buy, quick_limit_buy_action()},
        down_trend: {:wait_stable, unstable_timeout_action()},
        positive: {:wait_stable, unstable_timeout_action()},
        negative: {:wait_stable, unstable_timeout_action()}
      }
    }
  end

  def quick_sell do
    %{
      btc_and_zar:
      %{
        stable: {:sell, limit_sell_action()},
        up_trend: {:quick_buy, quick_limit_buy_action()},
        down_trend: {:quick_sell, quick_limit_sell_action()},
        positive: {:sell, limit_sell_action()},
        negative: {:sell, limit_sell_action()}
      },
      only_btc:
      %{
        stable: {:sell, limit_sell_action()},
        up_trend: {:wait_stable, unstable_timeout_action()},
        down_trend: {:quick_sell, quick_limit_sell_action()},
        positive: {:sell, limit_sell_action()},
        negative: {:sell, limit_sell_action()}
      },
      only_zar:
      %{
        stable: {:wait_stable, unstable_timeout_action()},
        up_trend: {:quick_buy, quick_limit_buy_action()},
        down_trend: {:wait_stable, unstable_timeout_action()},
        positive: {:wait_stable, unstable_timeout_action()},
        negative: {:wait_stable, unstable_timeout_action()}
      }
    }
  end

  def buy do
    %{
      btc_and_zar:
      %{
        stable: {:buy, limit_buy_action()},
        up_trend: {:quick_buy, quick_limit_buy_action()},
        down_trend: {:quick_sell, quick_limit_sell_action()},
        positive: {:buy, limit_buy_action()},
        negative: {:buy, limit_sell_action()}
      },
      only_btc:
      %{
        stable: {:wait_stable, unstable_timeout_action()},
        up_trend: {:wait_stable, unstable_timeout_action()},
        down_trend: {:quick_sell, quick_limit_sell_action()},
        positive: {:wait_stable, unstable_timeout_action()},
        negative: {:wait_stable, unstable_timeout_action()}
      },
      only_zar:
      %{
        stable: {:buy, limit_buy_action()},
        up_trend: {:quick_buy, quick_limit_buy_action()},
        down_trend: {:wait_stable, unstable_timeout_action()},
        positive: {:buy, limit_buy_action()},
        negative: {:buy, unstable_timeout_action()}
      }
    }
  end

  def quick_buy do
    %{
      btc_and_zar:
      %{
        stable: {:buy, limit_sell_action()},
        up_trend: {:quick_buy, quick_limit_buy_action()},
        down_trend: {:quick_sell, quick_limit_sell_action()},
        positive: {:buy, limit_sell_action()},
        negative: {:buy, limit_sell_action()}
      },
      only_btc:
      %{
        stable: {:wait_stable, unstable_timeout_action()},
        up_trend: {:wait_stable, unstable_timeout_action()},
        down_trend: {:quick_sell, quick_limit_sell_action()},
        positive: {:wait_stable, unstable_timeout_action()},
        negative: {:wait_stable, unstable_timeout_action()}
      },
      only_zar:
      %{
        stable: {:buy, limit_sell_action()},
        up_trend: {:quick_buy, quick_limit_buy_action()},
        down_trend: {:wait_stable, unstable_timeout_action()},
        positive: {:buy, limit_sell_action()},
        negative: {:buy, limit_sell_action()}
      }
    }
  end

end
