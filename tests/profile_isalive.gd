# 深度剖析：拆解 is_alive 内部三步（被包围/合法空点/两眼）耗时
# 用法: godot --headless --script res://tests/profile_isalive.gd
extends SceneTree

func _init() -> void:
	var GameSessionClass = preload("res://scripts/core/GameSession.gd")
	var ConstClass = preload("res://scripts/core/Const.gd")
	var SiegeDetectorClass = preload("res://scripts/core/SiegeDetector.gd")

	var session = GameSessionClass.new(ConstClass.KOMI_DEFAULT, false, 152)
	session.emit_signals = false

	var t_surrounded: int = 0
	var t_count: int = 0
	var t_eyes: int = 0
	var t_all_groups: int = 0
	var n_groups: int = 0
	var n_surrounded: int = 0
	var n_count: int = 0
	var n_eyes: int = 0

	for ply in range(250):
		var color: int = session.to_move
		var placed: bool = false
		for row in range(19):
			for col in range(19):
				if session.board.get_at(row, col) != ConstClass.EMPTY:
					continue
				var out: Dictionary = session.play_move(color, row, col)
				if out.ok:
					placed = true
					break
			if placed:
				break
		if not placed:
			session.do_pass(color)
		# 落子后剖析 is_alive 内部三步
		var tg0: int = Time.get_ticks_usec()
		var groups: Array = session.board.all_groups()
		var tg1: int = Time.get_ticks_usec()
		t_all_groups += tg1 - tg0
		for g in groups:
			n_groups += 1
			var t0: int = Time.get_ticks_usec()
			var surrounded: bool = SiegeDetectorClass._is_surrounded_by_opponent(session.board, g)
			var t1: int = Time.get_ticks_usec()
			t_surrounded += t1 - t0
			if not surrounded:
				continue  # 活棋，优先级1短路
			n_surrounded += 1
			var c: int = SiegeDetectorClass.count_legal_empty_points(session.board, g, 4)
			var t2: int = Time.get_ticks_usec()
			t_count += t2 - t1
			n_count += 1
			if c >= 4:
				continue  # 优先级2短路
			SiegeDetectorClass.has_two_true_eyes(session.board, g)
			var t3: int = Time.get_ticks_usec()
			t_eyes += t3 - t2
			n_eyes += 1

	print("========== is_alive 深度剖析 ==========")
	print("组群总数(累计): %d, 被包围组群: %d, 走count步骤: %d, 走eyes步骤: %d" % [n_groups, n_surrounded, n_count, n_eyes])
	print("all_groups:          %7.1f ms (均 %.3f ms/手)" % [t_all_groups / 1000.0, t_all_groups / 1000.0 / 250.0])
	print("被包围判定:          %7.1f ms (均 %.2f ms/手)" % [t_surrounded / 1000.0, t_surrounded / 1000.0 / 250.0])
	print("  count合法空点:     %7.1f ms (均 %.3f ms/次)" % [t_count / 1000.0, t_count / 1000.0 / max(n_count, 1)])
	print("  两眼判定:          %7.1f ms (均 %.3f ms/次)" % [t_eyes / 1000.0, t_eyes / 1000.0 / max(n_eyes, 1)])
	print("======================================")
	quit()
