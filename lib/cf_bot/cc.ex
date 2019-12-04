defmodule CfBot.CC do

  def start_cb(hodl_amt, mode) do
    DynamicSupervisor.start_child(
      CfBot.DynSup,
      {
        CfBot.Statem,
        %{
          name: CfCb,
          med_mod: CfCb.Mediate,
          pair: "BTC-GBP",
          ref_pair: "BTC-USD",
          min_incr: 0.01,
          short_review_time: 50,
          long_review_time: 50,
          dt_pct: 0.0005,
          ut_pct: 0.0005,
          stable_pct: 0.0001,
          mode: mode,
          ws: false
        }
      }
    )
    CfBot.Statem.set_hodl_amt(CfCb, "secondary", hodl_amt)
    CfBot.Statem.set_buy_amt(CfCb, 0.0)
    CfBot.Statem.set_sell_amt(CfCb, 0.0)
  end

  def start_luno(hodl_amt, mode) do
    DynamicSupervisor.start_child(
      CfBot.DynSup,
      {
        CfBot.Statem,
        %{
          name: CfLuno,
          med_mod: CfLuno.Mediate,
          pair: "XBTZAR",
          ref_pair: "BTC-USD",
          min_incr: 1,
          long_review_time: 3000,
          short_review_time: 1000,
          dt_pct: 0.0015,
          ut_pct: 0.0015,
          stable_pct: 0.00025,
          prim_hodl_amt: hodl_amt,
          mode: mode,
          ws: false
        }
      }
    )
    CfBot.Statem.set_buy_amt(CfLuno, 0.0)
  end

  def start_valr(hodl_amt, mode) do
    DynamicSupervisor.start_child(
      CfBot.DynSup,
      {
        CfBot.Statem,
        %{
          name: CfValr,
          med_mod: CfValr.Mediate,
          pair: "BTCZAR",
          ref_pair: "BTC-USD",
          min_incr: 1,
          long_review_time: 5500,
          short_review_time: 3000,
          dt_pct: 0.001,
          ut_pct: 0.001,
          stable_pct: 0.00025,
          prim_hodl_amt: hodl_amt,
          mode: mode,
          ws: true
        }
      }
    )
    CfBot.Statem.set_mode(CfValr, "sell")
    CfBot.Statem.set_buy_amt(CfValr, 0.0)
  end

  def start_cb_test(hodl_amt, mode) do
    DynamicSupervisor.start_child(
      CfBot.DynSup,
      {
        CfBot.Statem,
        %{
          name: CfCb,
          med_mod: CfCb.Mediate,
          pair: "BTC-USD",
          ref_pair: "BTC-USD",
          min_incr: 0.01,
          short_review_time: 50,
          long_review_time: 50,
          dt_pct: 0.0005,
          ut_pct: 0.0005,
          stable_pct: 0.0001,
          mode: mode,
          ws: true
        }
      }
    )
    CfBot.Statem.set_hodl_amt(CfCb, "secondary", hodl_amt)
    CfBot.Statem.set_buy_amt(CfCb, 0.0)
    CfBot.Statem.set_sell_amt(CfCb, 0.0)
  end

  def stop_dyn_sup_child() do
    [{_, pid, _, _}] = DynamicSupervisor.which_children(CfBot.DynSup)
    DynamicSupervisor.terminate_child(CfBot.DynSup, pid)
  end

end
