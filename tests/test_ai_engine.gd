extends RefCounted
# AI 引擎组件测试：候选生成器 / 评估函数 / 搜索引擎 / MCTS / 5档难度配置
# 用法: godot --headless --script res://tests/run_all.gd（已集成）

const AIDifficultyScript = preload("res://scripts/ai/AIDifficulty.gd")
const CandidateGenerator = preload("res://scripts/ai/CandidateGenerator.gd")
const EvaluationFunction = preload("res://scripts/ai/EvaluationFunction.gd")
const MCTSScript = preload("res://scripts/ai/MCTS.gd")
const AIManager = preload("res://scripts/ai/AIManager.gd")

func run(t: TestFramework) -> void:
	t.suite("AI 引擎组件")

	# 1. 5 档难度配置
	var diffs := [
		AIDifficultyScript.Difficulty.EASY,
		AIDifficultyScript.Difficulty.NORMAL,
		AIDifficultyScript.Difficulty.HARD,
		AIDifficultyScript.Difficulty.EXPERT,
		AIDifficultyScript.Difficulty.MASTER,
	]
	for d in diffs:
		var cfg: Dictionary = AIDifficultyScript.get_config(d)
		t.expect(int(cfg.get("max_candidates", 0)) > 0, "难度%d 候选数>0" % d)
		t.expect(int(cfg.get("search_depth", 0)) >= 1, "难度%d 搜索深度>=1" % d)
		t.expect(int(cfg.get("think_time_ms", 0)) > 0, "难度%d 思考时间>0" % d)
	t.expect_eq(AIDifficultyScript.name_of(AIDifficultyScript.Difficulty.HARD), "困难", "困难难度名")
	t.expect_eq(AIDifficultyScript.name_of(AIDifficultyScript.Difficulty.MASTER), "大师", "大师难度名")

	# 2. 候选生成器：合法、去重、不超上限
	var session := GameSession.new(Const.KOMI_DEFAULT, true)
	session.emit_signals = false
	var gen = CandidateGenerator.new()
	var cands: Array = gen.generate_candidates(session, Const.BLACK, 20)
	t.expect(cands.size() <= 20, "候选数不超上限")
	t.expect(cands.size() > 0, "开局有候选")
	var seen := {}
	var all_legal: bool = true
	for m in cands:
		var key: String = "%d,%d" % [m.row, m.col]
		if seen.has(key):
			all_legal = false
			break
		seen[key] = true
		if not GoRules.is_legal(session.board, m.row, m.col, Const.BLACK, session.ko_point):
			all_legal = false
			break
	t.expect(all_legal, "候选均合法且去重")

	# 3. 评估函数可计算（数值有限）
	var ev = EvaluationFunction.new()
	var val: float = ev.evaluate(session, Const.BLACK)
	t.expect(is_finite(val), "评估函数返回数值")

	# 4. 5 档难度引擎均可创建并行棋
	for d in diffs:
		var ai = AIManager.create(d, Const.WHITE)
		ai.search_budget_sec = 0.2  # 测试缩短时限
		var s2 := GameSession.new(Const.KOMI_DEFAULT, true)
		s2.emit_signals = false
		_play_random(s2, Const.BLACK)
		var move: Dictionary = ai.choose_move(s2)
		t.expect(move.has("type"), "难度%d 返回 move 字典" % d)
		var out: Dictionary = AIManager.play_ai_turn(s2, ai)
		t.expect(out.ok, "难度%d AI 行棋合法" % d)

	# 5. MCTS 直接搜索返回可执行 move
	var mcts = MCTSScript.new()
	mcts.candidate_generator = gen
	mcts.evaluator = ev
	var s3 := GameSession.new(Const.KOMI_DEFAULT, true)
	s3.emit_signals = false
	_play_random(s3, Const.BLACK)
	_play_random(s3, Const.WHITE)
	var mv: Dictionary = mcts.search(s3, Const.BLACK, 30, 0.3)
	t.expect(mv.has("type") and mv.get("type", "") != "", "MCTS 返回 move")
	if mv.get("type", "pass") == "move":
		var out3: Dictionary = s3.play_move(Const.BLACK, mv.row, mv.col)
		t.expect(out3.ok, "MCTS move 可执行")

# 随机行棋（模拟对手推进局面）
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
