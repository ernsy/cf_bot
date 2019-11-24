DynamicSupervisor.start_child(CfBot.DynSup,{CfBot.Statem,%{name: CfLuno, med_mod: CfLuno.TestMed, pair: "XBTZAR", ref_pair: "BTC-USD", min_incr: 1, review_time: 2000, dt_pct: 0.002, ut_pct: 0.002, stable_pct: 0.0005}})
DynamicSupervisor.start_child(CfBot.DynSup,{CfBot.Statem, %{name: CfCb, med_mod: CfCb.TestMed, pair: "BTC-GBP", ref_pair: "BTC-USD", min_incr: 0.01, review_time: 50, dt_pct: 0.0005, ut_pct: 0.0005, stable_pct: 0.0001}})
DynamicSupervisor.start_child(CfBot.DynSup,{CfBot.Statem, %{name: CfCb, med_mod: CfCb.Mediate, pair: "BTC-USD", ref_pair: "BTC-USD", min_incr: 0.01, review_time: 50, dt_pct: 0.0005, ut_pct: 0.0005, stable_pct: 0.0001}})

DynamicSupervisor.start_child(CfBot.DynSup,{CfBot.Statem, %{name: CfCb, med_mod: CfCb.Mediate, pair: "BTC-GBP", ref_pair: "BTC-USD", min_incr: 0.01, review_time: 50, dt_pct: 0.0005, ut_pct: 0.0005, stable_pct: 0.0001}})
DynamicSupervisor.start_child(CfBot.DynSup,{CfBot.Statem,%{name: CfLuno, med_mod: CfLuno.Mediate, pair: "XBTZAR", ref_pair: "BTC-USD", min_incr: 1, review_time: 2000, dt_pct: 0.002, ut_pct: 0.002, stable_pct: 0.0005}})
CfBot.Statem.set_mode(CfLuno,"normal")

CfBot.Statem.set_hodl_amt(CfLuno, "primary", 0.65697933)
CfBot.Statem.set_sell_amt(CfLuno,0.0)
CfBot.Statem.set_mode(CfLuno,"hodl")

CfBot.Statem.set_hodl_amt(CfCb, "secondary", 0.0)
CfBot.Statem.set_buy_amt(CfCb,0.0)
CfBot.Statem.set_mode(CfCb,"buy")

CfBot.Statem.set_buy_amt(CfCb,0.1)

c("lib/cf_cb/mediate.ex")
c("lib/cf_luno/mediate.ex")

[{_,pid,_,_}]=Supervisor.which_children(CfBot.DynSup)
Supervisor.terminate_child(CfBot.DynSup,pid)
