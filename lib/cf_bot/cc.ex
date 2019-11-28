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
          review_time: 50,
          dt_pct: 0.0005,
          ut_pct: 0.0005,
          stable_pct: 0.0001 ,
          mode: mode
        }
      }
    )
    CfBot.Statem.set_hodl_amt(CfCb, "secondary", hodl_amt)
    CfBot.Statem.set_buy_amt(CfCb, 0.0)
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
          review_time: 2000,
          dt_pct: 0.002,
          ut_pct: 0.002,
          stable_pct: 0.0005,
          prim_hodl_amt: hodl_amt,
          mode: mode
        }
      }
    )
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
          review_time: 5000,
          dt_pct: 0.002,
          ut_pct: 0.002,
          stable_pct: 0.0005,
          prim_hodl_amt: hodl_amt,
          mode: mode
        }
      }
    )
  end

  def stop_dyn_sup_child() do
    [{_, pid, _, _}] = DynamicSupervisor.which_children(CfBot.DynSup)
    DynamicSupervisor.terminate_child(CfBot.DynSup, pid)
  end

end
