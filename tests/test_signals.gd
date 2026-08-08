extends RefCounted
# 信号触发测试：验证 GameSession 在 emit_signals=true 时正确发出信号
# 这是 UI 集成的基础测试，确保 GameScreen 能收到正确的信号

var _state: Dictionary = {}

func run(t: TestFramework) -> void:
	t.suite("信号触发")

	# 1. 落子信号
	_state = {"move": 0, "score": 0, "pass": 0, "end": 0, "deploy": 0, "ambush": 0,
		"last": {}, "end_result": {}, "captures": []}
	var s := GameSession.new(Const.KOMI_DEFAULT, false)
	s.move_committed.connect(_on_move)
	s.scores_changed.connect(_on_score)
	s.game_ended.connect(_on_end)
	var out = s.play_move(Const.BLACK, 9, 9)  # 边境
	t.expect(out.ok, "落子合法")
	t.expect_eq(_state.move, 1, "落子后触发1次 move_committed")
	t.expect_eq(_state.score, 1, "落子后触发1次 scores_changed")
	t.expect(_state.last.has("placed"), "outcome 含 placed")
	t.expect_eq(_state.last.mover_color, Const.BLACK, "mover_color=BLACK")
	t.expect_eq(_state.last.placed, Vector2i(9, 9), "placed=(9,9)")

	# 2. 虚手信号 + 终局信号
	_state = {"move": 0, "score": 0, "pass": 0, "end": 0, "deploy": 0, "ambush": 0,
		"last": {}, "end_result": {}, "captures": []}
	s = GameSession.new(Const.KOMI_DEFAULT, false)
	s.move_committed.connect(_on_move)
	s.scores_changed.connect(_on_score)
	s.game_ended.connect(_on_end)
	s.do_pass(Const.BLACK)
	s.do_pass(Const.WHITE)
	t.expect_eq(_state.pass, 2, "2次虚手")
	t.expect_eq(_state.end, 1, "终局信号触发1次")
	t.expect(_state.end_result.has("winner"), "终局结果含 winner")
	t.expect(s.game_over, "game_over=true")

	# 3. 提子信号
	_state = {"move": 0, "score": 0, "pass": 0, "end": 0, "deploy": 0, "ambush": 0,
		"last": {}, "end_result": {}, "captures": []}
	s = GameSession.new(Const.KOMI_DEFAULT, false)
	s.move_committed.connect(_on_move)
	s.scores_changed.connect(_on_score)
	s.game_ended.connect(_on_end)
	s.play_move(Const.BLACK, 4, 5)
	s.play_move(Const.WHITE, 5, 5)
	s.play_move(Const.BLACK, 6, 5)
	s.play_move(Const.WHITE, 18, 18)
	s.play_move(Const.BLACK, 5, 4)
	s.play_move(Const.WHITE, 18, 17)
	var cap_out = s.play_move(Const.BLACK, 5, 6)  # 提白(5,5)
	t.expect(cap_out.ok, "提子合法")
	t.expect_eq(_state.captures.size(), 1, "提子事件 1 次")
	if _state.captures.size() == 1:
		t.expect_eq(_state.captures[0].captures.size(), 1, "提1子")
		t.expect_eq(_state.captures[0].mover_color, Const.BLACK, "提子方=BLACK")

	# 4. 部署特种部队信号
	_state = {"move": 0, "score": 0, "pass": 0, "end": 0, "deploy": 0, "ambush": 0,
		"last": {}, "end_result": {}, "captures": []}
	s = GameSession.new(Const.KOMI_DEFAULT, true)
	s.move_committed.connect(_on_move)
	s.scores_changed.connect(_on_score)
	s.game_ended.connect(_on_end)
	out = s.deploy_special(Const.BLACK, 5, 5)
	t.expect(out.ok, "部署合法")
	t.expect_eq(_state.deploy, 1, "部署事件 1 次")
	t.expect_eq(_state.last.mover_color, Const.BLACK, "部署 mover=BLACK")

	# 5. 伏击信号
	_state = {"move": 0, "score": 0, "pass": 0, "end": 0, "deploy": 0, "ambush": 0,
		"last": {}, "end_result": {}, "captures": []}
	s = GameSession.new(Const.KOMI_DEFAULT, true)
	s.move_committed.connect(_on_move)
	s.scores_changed.connect(_on_score)
	s.game_ended.connect(_on_end)
	s.deploy_special(Const.BLACK, 5, 5)  # 黑隐子
	out = s.play_move(Const.WHITE, 5, 5)  # 白撞隐子
	t.expect(out.ambush, "触发伏击")
	t.expect_eq(_state.ambush, 1, "伏击事件 1 次")
	t.expect_eq(_state.last.mover_color, Const.WHITE, "被伏击方=WHITE")
	t.expect_eq(_state.last.placed, Vector2i(5, 5), "伏击位置=(5,5)")

	# 6. 实时计分信号：每次行棋都应触发 scores_changed
	_state = {"move": 0, "score": 0, "pass": 0, "end": 0, "deploy": 0, "ambush": 0,
		"last": {}, "end_result": {}, "captures": []}
	s = GameSession.new(Const.KOMI_DEFAULT, false)
	s.move_committed.connect(_on_move)
	s.scores_changed.connect(_on_score)
	s.game_ended.connect(_on_end)
	s.play_move(Const.BLACK, 9, 9)
	s.play_move(Const.WHITE, 9, 10)
	s.do_pass(Const.BLACK)
	s.do_pass(Const.WHITE)
	t.expect_eq(_state.score, 4, "4次行棋=4次 scores_changed")

# 信号回调
func _on_move(outcome: Dictionary) -> void:
	_state.move += 1
	_state.last = outcome
	if outcome.get("passed", false):
		_state.pass += 1
	if outcome.get("deployed", false):
		_state.deploy += 1
	if outcome.get("ambush", false):
		_state.ambush += 1
	if outcome.captures.size() > 0:
		_state.captures.append(outcome)

func _on_score(_scores: Dictionary) -> void:
	_state.score += 1

func _on_end(result: Dictionary) -> void:
	_state.end += 1
	_state.end_result = result
