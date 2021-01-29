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
          dt_pct: 0.00025,
          ut_pct: 0.0005,
          bv_pct: 1,
          stable_pct: 0.00005,
          mode: mode,
          ws: true
        }
      }
    )
    CfBot.Statem.set_data(CfCb, :sec_hodl_amt, hodl_amt)
    CfBot.Statem.set_data(CfCb, :buy_amy, 0.0)
    CfBot.Statem.set_data(CfCb, :sell_amt, 0.0)
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
          bv_pct: 1,
          stable_pct: 0.000375,
          prim_hodl_amt: hodl_amt,
          mode: mode,
          ws: false
        }
      }
    )
    CfBot.Statem.set_data(CfLuno, :mode, "sell")
  end

  def start_luno_bot(s_amt, b_amt, p_hodl, s_hodl, mode) do
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
          dt_pct: 0.0035,
          ut_pct: 0.0035,
          bv_pct: 1,
          stable_pct: 0.0001,
          sell_amt: s_amt,
          buy_amt: b_amt,
          prim_hodl_amt: p_hodl,
          sec_hodl_amt: s_hodl,
          mode: mode,
          ws: false
        }
      }
    )
  end

  def start_luno_eth(hodl_amt, mode) do
    DynamicSupervisor.start_child(
      CfBot.DynSup,
      {
        CfBot.Statem,
        %{
          name: CfLunoEth,
          med_mod: CfLuno.Mediate,
          pair: "ETHZAR",
          ref_pair: "ETH-USD",
          min_incr: 1,
          long_review_time: 3000,
          short_review_time: 1000,
          dt_pct: 0.0015,
          ut_pct: 0.0015,
          bv_pct: 0.125,
          stable_pct: 0.000375,
          prim_hodl_amt: hodl_amt,
          mode: mode,
          ws: false
        }
      }
    )
    CfBot.Statem.set_data(CfLunoEth, :mode, "sell")
  end

  def start_luno_ltc(hodl_amt, mode) do
    DynamicSupervisor.start_child(
      CfBot.DynSup,
      {
        CfBot.Statem,
        %{
          name: CfLunoLtc,
          med_mod: CfLuno.Mediate,
          pair: "LTCZAR",
          ref_pair: "LTC-USD",
          min_incr: 1,
          long_review_time: 3000,
          short_review_time: 1000,
          dt_pct: 0.0015,
          ut_pct: 0.0015,
          bv_pct: 0.125,
          stable_pct: 0.000375,
          prim_hodl_amt: hodl_amt,
          mode: mode,
          ws: false
        }
      }
    )
    CfBot.Statem.set_data(CfLunoLtc, :mode, "sell")
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
          long_review_time: 8000,
          short_review_time: 5000,
          dt_pct: 0.0015,
          ut_pct: 0.0015,
          bv_pct: 1,
          stable_pct: 0.00025,
          prim_hodl_amt: hodl_amt,
          mode: mode,
          ws: true
        }
      }
    )
    CfBot.Statem.set_data(CfValr, :mode, "sell")
  end

  def stop_dyn_sup_child() do
    [{_, pid, _, _}] = DynamicSupervisor.which_children(CfBot.DynSup)
    DynamicSupervisor.terminate_child(CfBot.DynSup, pid)
  end

end
