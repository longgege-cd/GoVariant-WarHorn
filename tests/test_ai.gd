extends RefCounted
# AI 测试：验证五级 AI 引擎都能正常行棋，且不产生非法操作
# 用法: godot --headless --script res://tests/run_all.gd（已集成）

const AIManager = preload("res://scripts/ai/AIManager.gd")

func run(t: TestFramework) -> void:
	t.suite("AI 行棋")

	# 1. 简单 AI（深度1启发搜索）能行棋且不非法
	var session := GameSession.new(Const.KOMI_DEFAULT, true)
	session.emit_signals = false
	var ai_easy = AIManager.create(AIManager.Difficulty.EASY, Const.WHITE)
	ai_easy.search_budget_sec = 0.15  # 测试缩短时限
	t.expect(ai_easy != null, "简单 AI 创建成功")
	var moves_played: int = 0
	for i in 20:
		# 黑方随机行棋
		_play_random(session, Const.BLACK)
		if session.game_over:
			break
		# 白方 AI 行棋
		var out: Dictionary = AIManager.play_ai_turn(session, ai_easy)
		t.expect(out.ok, "简单 AI 行棋合法 (第%d手)" % (i + 1))
		if out.ok:
			moves_played += 1
		if session.game_over:
			break
	t.expect(moves_played > 0, "简单 AI 至少行棋 1 手")

	# 2. 普通 AI（深度2搜索）能行棋
	session = GameSession.new(Const.KOMI_DEFAULT, true)
	session.emit_signals = false
	var ai_normal = AIManager.create(AIManager.Difficulty.NORMAL, Const.WHITE)
	ai_normal.search_budget_sec = 0.3  # 测试缩短时限
	t.expect(ai_normal != null, "普通 AI 创建成功")
	moves_played = 0
	for i in 10:
		_play_random(session, Const.BLACK)
		if session.game_over:
			break
		var out: Dictionary = AIManager.play_ai_turn(session, ai_normal)
		t.expect(out.ok, "普通 AI 行棋合法 (第%d手)" % (i + 1))
		if out.ok:
			moves_played += 1
		if session.game_over:
			break
	t.expect(moves_played > 0, "普通 AI 至少行棋 1 手")

	# 3. 困难 AI（深度3搜索）能行棋
	session = GameSession.new(Const.KOMI_DEFAULT, true)
	session.emit_signals = false
	var ai_hard = AIManager.create(AIManager.Difficulty.HARD, Const.WHITE)
	ai_hard.search_budget_sec = 0.3  # 测试缩短时限
	t.expect(ai_hard != null, "困难 AI 创建成功")
	moves_played = 0
	for i in 8:
		_play_random(session, Const.BLACK)
		if session.game_over:
			break
		var out: Dictionary = AIManager.play_ai_turn(session, ai_hard)
		t.expect(out.ok, "困难 AI 行棋合法 (第%d手)" % (i + 1))
		if out.ok:
			moves_played += 1
		if session.game_over:
			break
	t.expect(moves_played > 0, "困难 AI 至少行棋 1 手")

	# 4. AI vs AI 对局能完整结束（简单 vs 简单）
	session = GameSession.new(Const.KOMI_DEFAULT, false)
	session.emit_signals = false
	var ai_b = AIManager.create(AIManager.Difficulty.EASY, Const.BLACK)
	var ai_w = AIManager.create(AIManager.Difficulty.EASY, Const.WHITE)
	ai_b.search_budget_sec = 0.1
	ai_w.search_budget_sec = 0.1
	var ply: int = 0
	while not session.game_over and ply < 100:
		ply += 1
		var ai = ai_b if session.to_move == Const.BLACK else ai_w
		var out: Dictionary = AIManager.play_ai_turn(session, ai)
		if not out.ok:
			t.expect(false, "AI vs AI 第%d手非法: %s" % [ply, out.reason])
			break
	t.expect(session.game_over or ply >= 100, "AI vs AI 对局正常结束或达手数上限")

# 随机行棋（用于测试中模拟对手）
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
	# 70% 随机落子，30% 虚手（加速终局）
	if randf() < 0.3:
		session.do_pass(color)
	else:
		var m = candidates[randi() % candidates.size()]
		session.play_move(color, m[0], m[1])
