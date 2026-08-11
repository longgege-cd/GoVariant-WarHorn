# 验证计时器为总时间累计制：switch_to 不重置该方已消耗时间
extends RefCounted

const TimerSystem = preload("res://scripts/core/TimerSystem.gd")
const Const = preload("res://scripts/core/Const.gd")

func run(t) -> void:
	# 1. 基本总时间累计：黑先走，消耗 10s 后切换白，黑剩余时间应继续保留
	var timer := TimerSystem.new()
	var cfg := {
		Const.BLACK: {"main": 60.0, "byoyomi": 0, "byoyomi_duration": 0.0},
		Const.WHITE: {"main": 60.0, "byoyomi": 0, "byoyomi_duration": 0.0},
	}
	timer.reset(cfg)
	timer.switch_to(Const.BLACK)
	timer.tick(10.0)
	timer.switch_to(Const.WHITE)
	var t_black_after_switch := timer.get_time(Const.BLACK)
	t.expect_eq(int(t_black_after_switch.main), 50, "黑方总时间：走10s后切白，黑剩余50s")
	
	# 2. 白方也消耗时间后切回黑，黑仍保持 50s，白开始减少
	timer.tick(5.0)
	timer.switch_to(Const.BLACK)
	t.expect_eq(int(timer.get_time(Const.BLACK).main), 50, "黑方总时间：切回后仍为50s")
	t.expect_eq(int(timer.get_time(Const.WHITE).main), 55, "白方总时间：走5s后剩余55s")
	
	# 3. 读秒配置下主时间耗尽后进入读秒，切换不影响读秒次数
	var timer2 := TimerSystem.new()
	var cfg2 := {
		Const.BLACK: {"main": 10.0, "byoyomi": 3, "byoyomi_duration": 30.0},
		Const.WHITE: {"main": 10.0, "byoyomi": 3, "byoyomi_duration": 30.0},
	}
	timer2.reset(cfg2)
	timer2.switch_to(Const.BLACK)
	timer2.tick(10.0)
	var t2 := timer2.get_time(Const.BLACK)
	t.expect(t2.in_byoyomi, "黑方主时间耗尽后进入读秒")
	t.expect_eq(t2.byoyomi_left, 3, "进入读秒时剩余读秒次数=3")
	timer2.tick(20.0)
	timer2.switch_to(Const.WHITE)
	var t2_after := timer2.get_time(Const.BLACK)
	t.expect_eq(t2_after.byoyomi_left, 3, "读秒消耗20s后切白，黑读秒剩余3次")
	t.expect_eq(int(t2_after.byoyomi_time), 10, "读秒消耗20s后剩余10s")
	# 继续消耗，触发一次读秒重置
	timer2.switch_to(Const.BLACK)
	timer2.tick(10.0)
	var t2_after2 := timer2.get_time(Const.BLACK)
	t.expect_eq(t2_after2.byoyomi_left, 2, "读秒再消耗10s后，黑读秒剩余2次")
	t.expect_eq(int(t2_after2.byoyomi_time), 30, "读秒再消耗10s后重置为30s")
