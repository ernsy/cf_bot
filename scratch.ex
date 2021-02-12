sell_amt= CfLuno.Mediate.get_avail_bal("XBT") - 0.000022*100; buy_amt = 0.00; CfBot.CC.start_luno_bot(sell_amt, buy_amt,  CfLuno.Mediate.get_avail_bal("XBT") - sell_amt - 0.0005, 0, "bot")
    {price, _} = CfLuno.Mediate.get_ticker("XBTZAR")["last_trade"] |> Float.parse()
    buy_amt = (CfLuno.Mediate.get_avail_bal("ZAR") - 500) / price
    fee_allowance =  (CfLuno.Mediate.get_avail_bal("XBT") + buy_amt) * fee * 100
CfBot.Statem.set_data(CfLuno, :mode, "bot")
CfBot.Statem.set_data(CfLuno,:bv_pct,0.1)
CfBot.Statem.set_data(CfLuno,:ut_pct,0.4/100)
CfBot.Statem.set_data(CfLuno,:dt_pct,0.4/100)
CfBot.Statem.set_data(CfLuno,:stable_pct,0.03/100)
CfBot.Statem.set_data(CfLuno,:j_pct,0.04/100)
CfBot.Statem.set_data(CfLuno,:aj_pct,0.04/100)
CfBot.Statem.set_data(CfLuno,:prim_hodl_amt,0)
CfBot.Statem.set_data(CfLuno,:profit,0)

c("lib/cf_luno/mediate.ex")
c("lib/cf_bot/statem.ex")
c("lib/cf_bot/transitions.ex")
c("lib/json_utils.ex")

CfBot.CC.start_cb(CfCb.Mediate.get_avail_bal("GBP") / 3 * 2, "buy")
CfBot.Statem.set_mode(CfCb, "buy")
CfBot.Statem.set_hodl_amt(CfCb, "secondary", CfCb.Mediate.get_avail_bal("GBP") / 2)
CfBot.Statem.set_hodl_amt(CfCb, "secondary", 0)

CfBot.CC.start_luno(0.05064741562, "hodl")
CfBot.Statem.set_mode(CfLuno, "sell")
CfBot.Statem.set_hodl_amt(CfLuno, "primary", 0.4598463976)
CfBot.Statem.set_hodl_amt(CfLuno, "primary", CfLuno.Mediate.get_avail_bal("XBT") - 0.26189576)
CfBot.Statem.set_sell_amt(CfLuno, 0.1195040383)
CfBot.Statem.resume(CfLuno)

CfBot.CC.start_luno_eth(3.5, "hodl")
CfBot.Statem.set_mode(CfLunoEth, "sell")
CfBot.Statem.set_hodl_amt(CfLunoEth, "primary", 3.5)

CfBot.CC.start_luno_ltc(0, "hodl")
CfBot.Statem.set_mode(CfLunoLtc, "sell")

CfBot.CC.start_valr(0.0, "hodl")
CfBot.Statem.set_mode(CfValr, "sell")
CfBot.Statem.set_hodl_amt(CfValr, "primary", 0.310203986)
CfBot.Statem.set_hodl_amt(CfValr, "primary", CfValr.Mediate.get_avail_bal("BTC") - 0.1100510911)
CfBot.Statem.set_sell_amt(CfValr, 0.06159683222)
CfBot.Statem.resume(CfValr)

CfLuno.Mediate.get_avail_bal("XBT")
CfValr.Mediate.get_avail_bal("BTC")
CfValr.Api.balances()

CfBot.CC.start_cb_test(6200, "buy")

CfBot.CC.stop_dyn_sup_child()

c("lib/cf_cb/mediate.ex")
c("lib/cf_luno/mediate.ex")
c("lib/cf_valr/mediate.ex")
c("lib/cf_bot/statem.ex")
c("lib/cf_bot/transitions.ex")
c("lib/json_utils.ex")

DynamicSupervisor.start_child(
  CfBot.DynSup,
  {
    CfBot.Statem,
    %{
      name: CfLuno,
      med_mod: CfLuno.Mediate,
      pair: "ETHXBT",
      ref_pair: "ETH-BTC",
      min_incr: 1,
      long_review_time: 3000,
      short_review_time: 1000,
      dt_pct: 0.0015,
      ut_pct: 0.0015,
      stable_pct: 0.000375,
      prim_hodl_amt: 0,
      mode: "sell",
      ws: false
    }
  }
)
CfBot.Statem.set_mode(CfLuno, "sell")