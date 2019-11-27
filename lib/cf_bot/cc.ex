defmodule CfBot.CC do

  def start_luno(hodl_amt, mode) do
    prep_luno(hodl_amt)
    set_mode(CfLuno, mode)
  end

  def prep_luno(hodl_amt) do
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
          review_time: 2000,
          dt_pct: 0.002,
          ut_pct: 0.002,
          stable_pct: 0.0005
        }
      }
    )
    CfBot.Statem.set_mode(CfLuno, "wait")
    CfBot.Statem.set_hodl_amt(CfLuno, "primary", hodl_amt)
    CfBot.Statem.set_sell_amt(CfLuno, 0.0)
  end

  def start_cb(hodl_amt, mode) do
    prep_cb(hodl_amt)
    set_mode(CfCb, mode)
  end

  def prep_cb(hodl_amt) do
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
          review_time: 50,
          dt_pct: 0.0005,
          ut_pct: 0.0005,
          stable_pct: 0.0001
        }
      }
    )
    CfBot.Statem.set_mode(CfCb, "wait")
    CfBot.Statem.set_hodl_amt(CfCb, "secondary", hodl_amt)
    CfBot.Statem.set_buy_amt(CfCb, 0.0)
  end

  def set_mode(statem, mode) do
    CfBot.Statem.set_mode(statem, mode)
  end

  def stop_dyn_sup_child() do
    [{_,pid,_,_}]=DynamicSupervisor.which_children(CfBot.DynSup)
    DynamicSupervisor.terminate_child(CfBot.DynSup,pid)
  end

end
