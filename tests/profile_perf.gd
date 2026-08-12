# 性能剖析：拆解落子与缓存计算热点
# 用法: godot --headless --script res://tests/profile_perf.gd
extends SceneTree

func _init() -> void:
	var GameSessionClass = preload("res://scripts/core/GameSession.gd")
	var ConstClass = preload("res://scripts/core/Const.gd")
	var SiegeDetectorClass = preload("res://scripts/core/SiegeDetector.gd")
	var TerritoryDetectorClass = preload("res://scripts/core/TerritoryDetector.gd")
	var ScoreCalculatorClass = preload("res://scripts/core/ScoreCalculator.gd")

	var session = GameSessionClass.new(ConstClass.KOMI_DEFAULT, false, 152)
	session.emit_signals = false  # 手动控制缓存计算计时（play_move 不再自动触发 scores()）

	var t_fail: int = 0
	var t_move: int = 0
	var t_sieged: int = 0
	var t_encs: int = 0
	var t_score: int = 0
	var n_fail: int = 0
	var n_move: int = 0
	var n_cache: int = 0
	var total_moves: int = 0

	var start_all: int = Time.get_ticks_usec()
	for ply in range(250):
		var color: int = session.to_move
		var placed: bool = false
		for row in range(19):
			for col in range(19):
				if session.board.get_at(row, col) != ConstClass.EMPTY:
					continue
				var t0: int = Time.get_ticks_usec()
				var out: Dictionary = session.play_move(color, row, col)
				var t1: int = Time.get_ticks_usec()
				if out.ok:
					t_move += t1 - t0
					n_move += 1
					total_moves += 1
					# 手动复现 _ensure_cache 分块计时
					var ta: int = Time.get_ticks_usec()
					var sieged: Array = []
					for g in session.board.all_groups():
						if SiegeDetectorClass.is_sieged(session.board, g):
							sieged.append(g)
					var tb: int = Time.get_ticks_usec()
					var encs: Array = TerritoryDetectorClass.enclosures(session.board)
					var tc: int = Time.get_ticks_usec()
					ScoreCalculatorClass.compute(session.board, session.counters, sieged, encs)
					var td: int = Time.get_ticks_usec()
					t_sieged += tb - ta
					t_encs += tc - tb
					t_score += td - tc
					n_cache += 1
					placed = true
					break
				else:
					t_fail += t1 - t0
					n_fail += 1
			if placed:
				break
		if not placed:
			session.do_pass(color)

	var elapsed_ms: float = (Time.get_ticks_usec() - start_all) / 1000.0
	print("========== 性能剖析 ==========")
	print("成功落子: %d 手, 失败尝试: %d 次, 缓存计算: %d 次" % [n_move, n_fail, n_cache])
	print("总耗时: %.1f ms" % elapsed_ms)
	print("--- 分段累计耗时 ---")
	print("核心落子 play_move:    %7.1f ms (均 %.2f ms/手)" % [t_move / 1000.0, t_move / 1000.0 / max(n_move, 1)])
	print("围困判定 sieged:       %7.1f ms (均 %.2f ms/手)" % [t_sieged / 1000.0, t_sieged / 1000.0 / max(n_cache, 1)])
	print("围空检测 enclosures:   %7.1f ms (均 %.2f ms/手)" % [t_encs / 1000.0, t_encs / 1000.0 / max(n_cache, 1)])
	print("计分 compute:          %7.1f ms (均 %.2f ms/手)" % [t_score / 1000.0, t_score / 1000.0 / max(n_cache, 1)])
	print("失败尝试(非法落子):    %7.1f ms (均 %.3f ms/次)" % [t_fail / 1000.0, t_fail / 1000.0 / max(n_fail, 1)])
	var per_move_ms: float = (t_move + t_sieged + t_encs + t_score) / 1000.0 / max(n_move, 1)
	print("--- 真实每手开销(仅1次成功落子+缓存) ---")
	print("合计: %.2f ms/手" % per_move_ms)
	print("==================================")
	quit()
