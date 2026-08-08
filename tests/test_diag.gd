extends RefCounted
# 诊断测试：检查 GameSession 信号是否正常工作

func run(t: TestFramework) -> void:
	t.suite("信号诊断")

	var s := GameSession.new(Const.KOMI_DEFAULT, false)
	t.expect(s.emit_signals, "emit_signals 默认 true")

	# 用 Dictionary 收集（避免捕获语义问题）
	var state := {"move": 0, "score": 0, "last": {}}
	s.move_committed.connect(_on_move.bind(state))
	s.scores_changed.connect(_on_score.bind(state))

	var out = s.play_move(Const.BLACK, 9, 9)
	t.expect(out.ok, "落子合法")
	t.expect(out.has("placed"), "outcome 含 placed")
	t.expect_eq(state.move, 1, "move_committed 触发1次")
	t.expect_eq(state.score, 1, "scores_changed 触发1次")

func _on_move(outcome: Dictionary, state: Dictionary) -> void:
	state.move += 1
	state.last = outcome

func _on_score(_scores: Dictionary, state: Dictionary) -> void:
	state.score += 1
