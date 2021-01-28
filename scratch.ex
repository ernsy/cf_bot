DynamicSupervisor.start_child(
  CfBot.DynSup,
  {
    CfBot.Statem,
    %{
      name: CfLuno,
      med_mod: CfLuno.TestMed,
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
DynamicSupervisor.start_child(
  CfBot.DynSup,
  {
    CfBot.Statem,
    %{
      name: CfCb,
      med_mod: CfCb.TestMed,
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
      review_time: 50,
      dt_pct: 0.0005,
      ut_pct: 0.0005,
      stable_pct: 0.0001
    }
  }
)

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

CfBot.CC.start_luno_bot(0.002, 0.00, 0.0225, 1000, "bot")
CfBot.Statem.set_mode(CfLuno, "bot")

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

18:34:23.313 [error] GenStateMachine CfLuno terminating
** (ArgumentError) argument error
    :erlang.float_to_binary(0, [decimals: 6])
    (cf_bot 0.1.0) lib/cf_bot/statem.ex:411: CfBot.Statem.place_limit_order/7
    (cf_bot 0.1.0) lib/cf_bot/statem.ex:168: CfBot.Statem.handle_event/4
    (stdlib 3.14) gen_statem.erl:1168: :gen_statem.loop_state_callback/11
    (stdlib 3.14) proc_lib.erl:226: :proc_lib.init_p_do_apply/3
State: {:sell, %{buy_amt: 7.24e-4, bv_pct: 1, dt_pct: 0.003, fee: 0.001, long_review_time: 3000, med_mod: CfLuno.Mediate, min_incr: 1, mode: "bot", name: CfLuno, old_amt: 0.0012749999999999999, oracle_queue: {{[{30118.3, ~U[2021-01-27 18:34:22.334717Z]}, {30122.6, ~U[2021-01-27 18:34:22.139973Z]}, {30122.6, ~U[2021-01-27 18:34:21.799126Z]}, {30122.68, ~U[2021-01-27 18:34:21.494902Z]}, {30122.43, ~U[2021-01-27 18:34:21.401165Z]}, {30122.68, ~U[2021-01-27 18:34:21.294565Z]}, {30122.68, ~U[2021-01-27 18:34:21.202261Z]}, {30118.35, ~U[2021-01-27 18:34:21.103754Z]}, {30122.43, ~U[2021-01-27 18:34:21.012998Z]}, {30122.11, ~U[2021-01-27 18:34:21.012998Z]}, {30120.79, ~U[2021-01-27 18:34:21.012998Z]}, {30115.79, ~U[2021-01-27 18:34:20.744034Z]}, {30118.27, ~U[2021-01-27 18:34:20.744034Z]}, {30123.22, ~U[2021-01-27 18:34:20.164061Z]}, {30123.22, ~U[2021-01-27 18:34:19.841733Z]}, {30123.21, ~U[2021-01-27 18:34:18.996703Z]}, {30117.77, ~U[2021-01-27 18:34:17.791638Z]}, {30118.63, ~U[2021-01-27 18:34:17.791638Z]}, {30122.61, ~U[2021-01-27 18:34:17.548243Z]}, {30121.11, ~U[2021-01-27 18:34:17.548243Z]}, {30127.02, ~U[2021-01-27 18:34:16.828853Z]}, {30109.67, ~U[2021-01-27 18:34:16.410217Z]}, {30109.67, ~U[2021-01-27 18:34:16.410217Z]}, {30109.67, ~U[2021-01-27 18:34:16.407070Z]}, {30109.67, ~U[2021-01-27 18:34:16.402369Z]}, {30109.67, ~U[2021-01-27 18:34:16.399101Z]}, {30109.67, ~U[2021-01-27 18:34:16.369005Z]}, {30109.66, ~U[2021-01-27 18:34:16.228052Z]}, {30109.66, ~U[2021-01-27 18:34:15.871452Z]}, {30109.67, ~U[2021-01-27 18:34:15.554578Z]}, {30105.11, ~U[2021-01-27 18:34:15.546940Z]}, {30106.86, ~U[2021-01-27 18:34:15.546940Z]}, {30106.86, ~U[2021-01-27 18:34:15.361142Z]}, {30107.0, ...}, {...}, ...], [{30148.29, ~U[2021-01-27 18:33:24.018631Z]}, {30143.78, ~U[2021-01-27 18:33:24.418097Z]}, {30148.29, ~U[2021-01-27 18:33:24.436876Z]}, {30143.4, ~U[2021-01-27 18:33:25.464779Z]}, {30141.54, ~U[2021-01-27 18:33:26.168156Z]}, {30141.54, ~U[2021-01-27 18:33:26.259234Z]}, {30136.52, ~U[2021-01-27 18:33:26.504344Z]}, {30130.01, ~U[2021-01-27 18:33:27.064033Z]}, {30130.0, ~U[2021-01-27 18:33:27.586772Z]}, {30128.79, ~U[2021-01-27 18:33:28.542821Z]}, {30127.36, ~U[2021-01-27 18:33:28.836985Z]}, {30127.39, ~U[2021-01-27 18:33:29.546041Z]}, {30127.33, ~U[2021-01-27 18:33:29.867383Z]}, {30126.38, ~U[2021-01-27 18:33:30.021398Z]}, {30127.55, ~U[2021-01-27 18:33:31.264670Z]}, {30127.88, ~U[2021-01-27 18:33:31.699909Z]}, {30122.87, ~U[2021-01-27 18:33:32.100450Z]}, {30129.62, ~U[2021-01-27 18:33:32.263816Z]}, {30130.87, ~U[2021-01-27 18:33:32.302868Z]}, {30119.62, ~U[2021-01-27 18:33:32.888015Z]}, {30120.7, ~U[2021-01-27 18:33:33.285850Z]}, {30124.38, ~U[2021-01-27 18:33:33.285850Z]}, {30125.7, ~U[2021-01-27 18:33:33.285850Z]}, {30119.2, ~U[2021-01-27 18:33:34.792689Z]}, {30119.2, ~U[2021-01-27 18:33:35.139752Z]}, {30120.97, ~U[2021-01-27 18:33:36.152296Z]}, {30121.65, ~U[2021-01-27 18:33:36.554822Z]}, {30121.65, ~U[2021-01-27 18:33:36.890826Z]}, {30121.65, ~U[2021-01-27 18:33:37.129706Z]}, {30116.48, ~U[2021-01-27 18:33:37.441868Z]}, {30114.63, ~U[2021-01-27 18:33:37.890657Z]}, {30114.63, ~U[2021-01-27 18:33:38.009571Z]}, {30119.86, ...}, {...}, ...]}, 19311}, oracle_ref: {30148.3, ~U[2021-01-27 18:33:23.754290Z]}, order_id: nil, order_price: 476862.0, order_time: 1611772430333, pair: "XBTZAR", prim_hodl_amt: 0.022, ref_pair: "BTC-USD", sec_hodl_amt: 1000, sell_amt: 0.0012749999999999999, short_review_time: 1000, stable_pct: 0.0001, ut_pct: 0.003, ws: false}}
