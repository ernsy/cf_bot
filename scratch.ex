DynamicSupervisor.start_child(CfBot.DynSup,{CfBot.Statem,%{name: CfLuno, med_mod: CfLuno.TestMed, pair: "XBTZAR", ref_pair: "BTC-USD", min_incr: 1, review_time: 2000, dt_pct: 0.002, ut_pct: 0.002, stable_pct: 0.0005}})
DynamicSupervisor.start_child(CfBot.DynSup,{CfBot.Statem, %{name: CfCb, med_mod: CfCb.TestMed, pair: "BTC-GBP", ref_pair: "BTC-USD", min_incr: 0.01, review_time: 50, dt_pct: 0.0005, ut_pct: 0.0005, stable_pct: 0.0001}})
DynamicSupervisor.start_child(CfBot.DynSup,{CfBot.Statem, %{name: CfCb, med_mod: CfCb.Mediate, pair: "BTC-USD", ref_pair: "BTC-USD", min_incr: 0.01, review_time: 50, dt_pct: 0.0005, ut_pct: 0.0005, stable_pct: 0.0001}})

CfBot.CC.start_cb(0, "buy")

CfBot.Statem.set_hodl_amt(CfCb, "secondary", 2500)

CfBot.CC.prep_luno(0.359)

CfBot.CC.start_luno(0.359, "hodl")


CfLuno.Mediate.get_avail_bal("XBT")
CfBot.Statem.resume(CfLuno)



c("lib/cf_cb/mediate.ex")
c("lib/cf_luno/mediate.ex")
c("lib/cf_bot/statem.ex")

[{_,pid,_,_}]=Supervisor.which_children(CfBot.DynSup)
Supervisor.terminate_child(CfBot.DynSup,pid)
