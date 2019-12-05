defmodule CfBot.Transitions do
  
  @limit_sell_action {:limit_sell, []}
  @limit_buy_action {:limit_buy, []}
  @cancel_order_action :cancel_orders

  def wait_stable() do
    %{
      buy_or_sell:
      %{
        stable: {:wait_stable, []},
        up_trend: {:quick_buy, @limit_buy_action},
        down_trend: {:quick_sell, @limit_sell_action},
        positive: {:wait_stable, []},
        negative: {:wait_stable, []}
      },
      sell:
      %{
        stable: {:sell, @limit_sell_action},
        up_trend: {:wait_stable, []},
        down_trend: {:quick_sell, @limit_sell_action},
        positive: {:wait_stable, []},
        negative: {:sell, @limit_sell_action}
      },
      buy:
      %{
        stable: {:buy, @limit_buy_action},
        up_trend: {:quick_buy, @limit_buy_action},
        down_trend: {:wait_stable, []},
        positive: {:buy, @limit_buy_action},
        negative: {:wait_stable, []}
      }
    }
  end

  def sell() do
    %{
      buy_or_sell:
      %{
        stable: {:sell, @limit_sell_action},
        up_trend: {:quick_buy, [@cancel_order_action, @limit_buy_action]},
        down_trend: {:quick_sell, @limit_sell_action},
        positive: {:sell, @limit_sell_action},
        negative: {:sell, @limit_sell_action}
      },
      sell:
      %{
        stable: {:sell, @limit_sell_action},
        up_trend: {:wait_stable, @cancel_order_action},
        down_trend: {:quick_sell, @limit_sell_action},
        positive: {:sell, @limit_sell_action},
        negative: {:sell, @limit_sell_action}
      },
      buy:
      %{
        stable: {:sell, []},
        up_trend: {:quick_buy, @limit_buy_action},
        down_trend: {:quick_sell, []},
        positive: {:sell,[]},
        negative: {:sell, []}
      }
    }
  end

    def quick_sell() do
    %{
      buy_or_sell:
      %{
        stable: {:sell, @limit_sell_action},
        up_trend: {:quick_buy, [@cancel_order_action, @limit_buy_action]},
        down_trend: {:quick_sell, @limit_sell_action},
        positive: {:sell, @limit_sell_action},
        negative: {:quick_sell, @limit_sell_action}
      },
      sell:
      %{
        stable: {:sell, @limit_sell_action},
        up_trend: {:wait_stable, @cancel_order_action},
        down_trend: {:quick_sell, @limit_sell_action},
        positive: {:sell, @limit_sell_action},
        negative: {:quick_sell, @limit_sell_action}
      },
      buy:
      %{
        stable: {:sell, []},
        up_trend: {:quick_buy, @limit_buy_action},
        down_trend: {:quick_sell, []},
        positive: {:sell, []},
        negative: {:quick_sell, []}
      }
    }
  end

  def buy() do
    %{
      buy_or_sell:
      %{
        stable: {:buy, @limit_buy_action},
        up_trend: {:quick_buy, @limit_buy_action},
        down_trend: {:quick_sell, [@cancel_order_action, @limit_sell_action]},
        positive: {:buy, @limit_buy_action},
        negative: {:buy, @limit_buy_action}
      },
      sell:
      %{
        stable: {:buy, []},
        up_trend: {:quick_buy, []},
        down_trend: {:quick_sell, @limit_sell_action},
        positive: {:buy, []},
        negative: {:buy, []}
      },
      buy:
      %{
        stable: {:buy, @limit_buy_action},
        up_trend: {:quick_buy, @limit_buy_action},
        down_trend: {:wait_stable, @cancel_order_action},
        positive: {:buy, @limit_buy_action},
        negative: {:buy, @limit_buy_action}
      }
    }
  end

    def quick_buy() do
    %{
      buy_or_sell:
      %{
        stable: {:buy, @limit_buy_action},
        up_trend: {:quick_buy, @limit_buy_action},
        down_trend: {:quick_sell, [@cancel_order_action, @limit_sell_action]},
        positive: {:quick_buy, @limit_buy_action},
        negative: {:buy, @limit_buy_action}
      },
      sell:
      %{
        stable: {:buy, []},
        up_trend: {:quick_buy, []},
        down_trend: {:quick_sell, @limit_sell_action},
        positive: {:quick_buy, []},
        negative: {:buy, []}
      },
      buy:
      %{
        stable: {:buy, @limit_buy_action},
        up_trend: {:quick_buy, @limit_buy_action},
        down_trend: {:wait_stable, @cancel_order_action},
        positive: {:quick_buy, @limit_buy_action},
        negative: {:buy, @limit_buy_action}
      }
    }
  end

end
