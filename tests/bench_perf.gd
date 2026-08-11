# 性能基准：模拟满盘对局，测量落子耗时
# 用法: godot --headless --script res://tests/bench_perf.gd
extends SceneTree

func _init() -> void:
	var GameSessionClass = preload("res://scripts/core/GameSession.gd")
	var ConstClass = preload("res://scripts/core/Const.gd")

	# 模拟满盘对局：双方交替落子至棋盘接近填满
	var session = GameSessionClass.new(ConstClass.KOMI_DEFAULT, false, 152)
	var total_moves: int = 0
	var start_time: float = Time.get_ticks_usec()

	# 交替落子，模拟真实对局（含围空/围困/提子判定）
	for ply in range(250):
		var color: int = session.to_move
		# 找一个合法点落子
		var placed: bool = false
		for row in range(19):
			for col in range(19):
				if session.board.get_at(row, col) != ConstClass.EMPTY:
					continue
				var out: Dictionary = session.play_move(color, row, col)
				if out.ok:
					placed = true
					total_moves += 1
					break
			if placed:
				break
		if not placed:
			# 无合法点，pass
			session.do_pass(color)

	var elapsed_ms: float = (Time.get_ticks_usec() - start_time) / 1000.0
	print("========== 性能基准 ==========")
	print("总落子数: %d" % total_moves)
	print("总耗时: %.1f ms" % elapsed_ms)
	print("平均每手: %.2f ms" % (elapsed_ms / max(total_moves, 1)))
	# 验证分数计算可正常完成
	var sc: Dictionary = session.scores()
	print("黑方总分: %d" % sc.black.total())
	print("白方总分: %d" % sc.white.total())
	print("==============================")
	quit()
