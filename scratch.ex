DynamicSupervisor.start_child(CfBot.DynSup,{CfBot.Statem,%{name: CfLuno, med_mod: CfLuno.TestMed, pair: "XBTZAR", ref_pair: "BTC-USD", min_incr: 1, review_time: 2000, dt_pct: 0.002, ut_pct: 0.002, stable_pct: 0.0005}})
DynamicSupervisor.start_child(CfBot.DynSup,{CfBot.Statem, %{name: CfCb, med_mod: CfCb.TestMed, pair: "BTC-GBP", ref_pair: "BTC-USD", min_incr: 0.01, review_time: 50, dt_pct: 0.0005, ut_pct: 0.0005, stable_pct: 0.0001}})
DynamicSupervisor.start_child(CfBot.DynSup,{CfBot.Statem, %{name: CfCb, med_mod: CfCb.Mediate, pair: "BTC-USD", ref_pair: "BTC-USD", min_incr: 0.01, review_time: 50, dt_pct: 0.0005, ut_pct: 0.0005, stable_pct: 0.0001}})

CfBot.CC.start_cb(CfCb.Mediate.get_avail_bal("GBP")/3*2, "buy")
CfBot.Statem.set_mode(CfCb, "buy")
CfBot.Statem.set_hodl_amt(CfCb, "secondary", CfCb.Mediate.get_avail_bal("GBP")/2)
CfBot.Statem.set_hodl_amt(CfCb, "secondary", 0)

CfBot.CC.start_luno(0.003772151353, "hodl")
CfBot.Statem.set_mode(CfLuno, "sell")
CfBot.Statem.set_hodl_amt(CfLuno, "primary", 0.4132060862)
CfBot.Statem.set_hodl_amt(CfLuno, "primary", CfLuno.Mediate.get_avail_bal("XBT") - 0.26189576)
CfBot.Statem.set_sell_amt(CfLuno, 0.1195040383)
CfBot.Statem.resume(CfLuno)

CfBot.CC.start_luno_eth(0.003772151353, "hodl")
CfBot.Statem.set_mode(CfLunoEth, "sell")
CfBot.Statem.set_hodl_amt(CfLunoEth, "primary", 11.46828307)

CfBot.CC.start_valr(0.18540817, "hodl")
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