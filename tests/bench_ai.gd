# AI 引擎性能基准：各难度一手思考耗时
# 用法: godot --headless --script res://tests/bench_ai.gd
extends SceneTree

func _init() -> void:
	var AIManager = preload("res://scripts/ai/AIManager.gd")
	print("========== AI 性能基准 ==========")
	var diffs := [
		AIManager.Difficulty.EASY,
		AIManager.Difficulty.NORMAL,
		AIManager.Difficulty.HARD,
		AIManager.Difficulty.EXPERT,
		AIManager.Difficulty.MASTER,
	]
	for d in diffs:
		var session: GameSession = GameSession.new(Const.KOMI_DEFAULT, true)
		session.emit_signals = false
		# 先走 10 手让局面非空
		for i in 10:
			if session.game_over:
				break
			_play_random(session, session.to_move)
		var ai = AIManager.create(d, session.to_move)
		var t0: int = Time.get_ticks_msec()
		var move: Dictionary = ai.choose_move(session)
		var elapsed: int = Time.get_ticks_msec() - t0
		print("难度%d (%s): %d ms  move=%s" % [d, AIManager.difficulty_name(d), elapsed, move.get("type", "")])
	quit()

func _play_random(session: GameSession, color: int) -> void:
	if session.game_over or session.to_move != color:
		return
	var b: BoardModel = session.board
	var candidates: Array = []
	for r in range(b.size):
		for c in range(b.size):
			if b.get_at(r, c) != Const.EMPTY:
				continue
			if GoRules.is_legal(b, r, c, color):
				candidates.append([r, c])
	if candidates.is_empty():
		session.do_pass(color)
		return
	var m = candidates[randi() % candidates.size()]
	session.play_move(color, m[0], m[1])
