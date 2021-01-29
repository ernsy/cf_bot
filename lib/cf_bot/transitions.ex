defmodule CfBot.Transitions do

  @limit_sell_action {:next_event, :internal, :limit_sell}
  #@delayed_limit_sell_action {:state_timeout, 60000, :limit_sell}
  @limit_buy_action {:next_event, :internal, :limit_buy}
  #@delayed_limit_buy_action {:state_timeout, 60000, :limit_buy}
  @market_sell_action {:next_event, :internal, :market_sell}
  @market_buy_action {:next_event, :internal, :market_buy}
  @cancel_order_action {:next_event, :internal, :cancel_orders}

  def wait_stable() do
    %{
      buy_or_sell:
      %{
        stable: {:sell, @limit_sell_action},
        up_trend: {:quick_buy, @market_buy_action},
        down_trend: {:quick_sell, @market_sell_action},
        positive: {:quick_buy, @limit_buy_action},
        negative: {:quick_sell, @limit_sell_action}
      },
      sell:
      %{
        stable: {:sell, @limit_sell_action},
        up_trend: {:wait_stable, []},
        down_trend: {:quick_sell, @market_sell_action},
        positive: {:wait_stable, []},
        negative: {:quick_sell, @limit_sell_action}
      },
      buy:
      %{
        stable: {:buy, @limit_buy_action},
        up_trend: {:quick_buy, @market_buy_action},
        down_trend: {:wait_stable, []},
        positive: {:quick_buy, @limit_buy_action},
        negative: {:wait_stable, []}
      }
    }
  end

  def sell() do
    %{
      buy_or_sell:
      %{
        stable: {:sell, @limit_sell_action},
        up_trend: {:quick_buy, @market_buy_action},
        down_trend: {:quick_sell, @market_sell_action},
        positive: {:quick_buy, @limit_buy_action},
        negative: {:quick_sell, @limit_sell_action}
      },
      sell:
      %{
        stable: {:sell, @limit_sell_action},
        up_trend: {:wait_stable, @cancel_order_action},
        down_trend: {:quick_sell, @market_sell_action},
        positive: {:wait_stable, @cancel_order_action},
        negative: {:quick_sell, @limit_sell_action}
      },
      buy:
      %{
        stable: {:buy, @limit_buy_action},
        up_trend: {:quick_buy, @market_buy_action},
        down_trend: {:wait_stable, @cancel_order_action},
        positive: {:quick_buy, @limit_buy_action},
        negative: {:wait_stable, @cancel_order_action}
      }
    }
  end

  def quick_sell() do
    %{
      buy_or_sell:
      %{
        stable: {:buy, @limit_buy_action},
        up_trend: {:buy, @market_buy_action},
        down_trend: {:sell, @market_sell_action},
        positive: {:quick_buy, @limit_buy_action},
        negative: {:quick_sell, @limit_sell_action}
      },
      sell:
      %{
        stable: {:sell, @limit_sell_action},
        up_trend: {:wait_stable, @cancel_order_action},
        down_trend: {:sell, @market_sell_action},
        positive: {:wait_stable, @cancel_order_action},
        negative: {:quick_sell, @limit_sell_action}
      },
      buy:
      %{
        stable: {:buy, @limit_buy_action},
        up_trend: {:buy, @market_buy_action},
        down_trend: {:wait_stable, @cancel_order_action},
        positive: {:quick_buy, @limit_buy_action},
        negative: {:wait_stable, @cancel_order_action},
      }
    }
  end

  def buy() do
    %{
      buy_or_sell:
      %{
        stable: {:buy, @limit_buy_action},
        up_trend: {:quick_buy, @market_buy_action},
        down_trend: {:quick_sell, @market_sell_action},
        positive: {:quick_buy, @limit_buy_action},
        negative: {:quick_sell, @limit_sell_action}
      },
      sell:
      %{
        stable: {:sell, @limit_sell_action},
        up_trend: {:wait_stable, @cancel_order_action},
        down_trend: {:quick_sell, @market_sell_action},
        positive: {:wait_stable, @cancel_order_action},
        negative: {:quick_sell, @limit_sell_action}
      },
      buy:
      %{
        stable: {:buy, @limit_buy_action},
        up_trend: {:quick_buy, @market_buy_action},
        down_trend: {:wait_stable, @cancel_order_action},
        positive: {:quick_buy, @limit_buy_action},
        negative: {:wait_stable, @cancel_order_action}
      }
    }
  end

  def quick_buy() do
    %{
      buy_or_sell:
      %{
        stable: {:sell, @limit_sell_action},
        up_trend: {:buy, @market_buy_action},
        down_trend: {:sell, @market_sell_action},
        positive: {:quick_buy, @limit_buy_action},
        negative: {:quick_sell, @limit_sell_action}
      },
      sell:
      %{
        stable: {:sell, @limit_sell_action},
        up_trend: {:wait_stable, @cancel_order_action},
        down_trend: {:sell, @market_sell_action},
        positive: {:wait_stable, @cancel_order_action},
        negative: {:quick_sell, @limit_sell_action}
      },
      buy:
      %{
        stable: {:buy, @limit_buy_action},
        up_trend: {:buy, @market_buy_action},
        down_trend: {:wait_stable, @cancel_order_action},
        positive: {:quick_buy, @limit_buy_action},
        negative: {:wait_stable, @cancel_order_action}
      }
    }
  end

end
