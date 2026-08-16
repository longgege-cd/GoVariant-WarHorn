extends RefCounted
# 信号触发测试：验证 GameSession 在 emit_signals=true 时正确发出信号
# 这是 UI 集成的基础测试，确保 GameScreen 能收到正确的信号

var _state: Dictionary = {}

func run(t: TestFramework) -> void:
	t.suite("信号触发")

	# 1. 落子信号
	_state = {"move": 0, "score": 0, "pass": 0, "end": 0, "deploy": 0, "bounce": 0,
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
	_state = {"move": 0, "score": 0, "pass": 0, "end": 0, "deploy": 0, "bounce": 0,
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
	_state = {"move": 0, "score": 0, "pass": 0, "end": 0, "deploy": 0, "bounce": 0,
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
	_state = {"move": 0, "score": 0, "pass": 0, "end": 0, "deploy": 0, "bounce": 0,
		"last": {}, "end_result": {}, "captures": []}
	s = GameSession.new(Const.KOMI_DEFAULT, true)
	s.move_committed.connect(_on_move)
	s.scores_changed.connect(_on_score)
	s.game_ended.connect(_on_end)
	out = s.deploy_special(Const.BLACK, 5, 5)
	t.expect(out.ok, "部署合法")
	t.expect_eq(_state.deploy, 1, "部署事件 1 次")
	t.expect_eq(_state.last.mover_color, Const.BLACK, "部署 mover=BLACK")

	# 5. 弹子信号（隐子重叠→弹子）
	_state = {"move": 0, "score": 0, "pass": 0, "end": 0, "deploy": 0, "bounce": 0,
		"last": {}, "end_result": {}, "captures": []}
	s = GameSession.new(Const.KOMI_DEFAULT, true)
	s.move_committed.connect(_on_move)
	s.scores_changed.connect(_on_score)
	s.game_ended.connect(_on_end)
	s.deploy_special(Const.BLACK, 5, 5)  # 黑隐子
	out = s.play_move(Const.WHITE, 5, 5)  # 白撞隐子
	t.expect(out.bounced, "触发弹子")
	t.expect_eq(_state.bounce, 1, "弹子事件 1 次")
	t.expect_eq(_state.last.mover_color, Const.WHITE, "弹子方=WHITE")
	t.expect_eq(_state.last.overlap_pos, Vector2i(5, 5), "重叠位置=(5,5)")

	# 6. 实时计分信号：每次行棋都应触发 scores_changed
	_state = {"move": 0, "score": 0, "pass": 0, "end": 0, "deploy": 0, "bounce": 0,
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

	# 7. 悔棋：恢复上一手前状态，触发信号
	_state = {"move": 0, "score": 0, "pass": 0, "end": 0, "deploy": 0, "bounce": 0,
		"last": {}, "end_result": {}, "captures": []}
	s = GameSession.new(Const.KOMI_DEFAULT, false)
	s.move_committed.connect(_on_move)
	s.scores_changed.connect(_on_score)
	s.game_ended.connect(_on_end)
	# 开局无可悔棋
	t.expect(not s.can_undo(), "开局无可悔棋")
	# 黑下(10,10) → 黑在白境活子+1
	s.play_move(Const.BLACK, 10, 10)
	t.expect(s.can_undo(), "行棋后可悔棋")
	var sc_before = s.scores()
	t.expect_eq(sc_before.black.occupation_live, 1, "悔棋前黑活子+1")
	# 白下(11,11)
	s.play_move(Const.WHITE, 11, 11)
	# 悔棋一手 → 恢复到白下(11,11)前
	var undo_out = s.undo()
	t.expect(undo_out.ok, "悔棋成功")
	t.expect(undo_out.undid, "undid=true")
	t.expect_eq(s.to_move, Const.WHITE, "悔棋后轮到白方")
	t.expect_eq(s.board.get_at(11, 11), Const.EMPTY, "悔棋后(11,11)为空")
	t.expect_eq(s.board.get_at(10, 10), Const.BLACK, "悔棋后(10,10)仍为黑")
	var sc_after = s.scores()
	t.expect_eq(sc_after.white.occupation_live, 0, "悔棋后白活子恢复0")
	t.expect_eq(s.ply, 1, "悔棋后 ply=1")
	# 再悔一手 → 恢复到开局
	s.undo()
	t.expect(not s.can_undo(), "悔到开局后无可悔棋")
	t.expect_eq(s.board.get_at(10, 10), Const.EMPTY, "悔到开局(10,10)为空")
	t.expect_eq(s.ply, 0, "悔到开局 ply=0")
	t.expect_eq(s.to_move, Const.BLACK, "悔到开局轮到黑方")

	# 8. 悔棋恢复提子与战损
	s = GameSession.new(Const.KOMI_DEFAULT, false)
	s.emit_signals = false
	# 构造提子：黑提白(4,4)
	s.play_move(Const.BLACK, 3, 4)
	s.play_move(Const.WHITE, 4, 4)
	s.play_move(Const.BLACK, 5, 4)
	s.play_move(Const.WHITE, 18, 18)
	s.play_move(Const.BLACK, 4, 3)
	s.play_move(Const.WHITE, 18, 17)
	s.play_move(Const.BLACK, 4, 5)  # 提白(4,4)
	t.expect_eq(s.board.get_at(4, 4), Const.EMPTY, "提子后(4,4)为空")
	t.expect_eq(s.counters[Const.WHITE].normal_lost, 1, "提子后白战损1")
	# 悔棋 → 恢复白(4,4)在盘上，战损归0
	s.undo()
	t.expect_eq(s.board.get_at(4, 4), Const.WHITE, "悔棋后白(4,4)恢复")
	t.expect_eq(s.counters[Const.WHITE].normal_lost, 0, "悔棋后白战损恢复0")
	t.expect_eq(s.counters[Const.BLACK].annihilate, 0, "悔棋后黑歼灭分恢复0")

	# 9. 悔棋恢复特种部队状态
	s = GameSession.new(Const.KOMI_DEFAULT, true)
	s.emit_signals = false
	s.deploy_special(Const.BLACK, 5, 5)  # 部署隐子
	t.expect_eq(s.special.uses_left(Const.BLACK), 1, "部署后剩余1次")
	t.expect(s.special.has_hidden_at(Vector2i(5, 5)), "隐子存在")
	s.undo()
	t.expect_eq(s.special.uses_left(Const.BLACK), 2, "悔棋后剩余次数恢复2")
	t.expect(not s.special.has_hidden_at(Vector2i(5, 5)), "悔棋后隐子不存在")

	# 10. 终局后不可悔棋
	s = GameSession.new(Const.KOMI_DEFAULT, false)
	s.emit_signals = false
	s.do_pass(Const.BLACK)
	s.do_pass(Const.WHITE)  # 双方虚手 → 终局
	t.expect(s.game_over, "双方虚手终局")
	t.expect(not s.can_undo(), "终局后不可悔棋")
	var fail_undo = s.undo()
	t.expect(not fail_undo.ok, "终局后悔棋失败")

	# 11. 虚手冷却：自上次虚手后需 2 个己方回合才能再次虚手
	s = GameSession.new(Const.KOMI_DEFAULT, false)
	s.emit_signals = false
	var p1 = s.do_pass(Const.BLACK)
	t.expect(p1.ok, "PASS1: 黑首次虚手成功（初始冷却=2）")
	t.expect_eq(s.to_move, Const.WHITE, "PASS1: 虚手后轮到白")
	t.expect_eq(p1.mover_color, Const.BLACK, "PASS1: 虚手 outcome 记录行棋方为黑（日志颜色修正回归）")
	t.expect_eq(p1.placed, Vector2i(-1, -1), "PASS1: 虚手 placed=(-1,-1)")
	t.expect_eq(s.pass_cooldown[Const.BLACK], 0, "PASS1: 虚手后黑冷却重置为0")
	# 黑立即虚手被拒（冷却中，0<2）
	s.to_move = Const.BLACK  # 强制轮到黑验证守卫
	var p2 = s.do_pass(Const.BLACK)
	t.expect(not p2.ok, "PASS2: 黑连续虚手被拒（冷却中）")
	t.expect(p2.reason.contains("冷却"), "PASS2: 拒绝原因含'冷却'（%s）" % p2.reason)
	t.expect_eq(s.pass_cooldown[Const.BLACK], 0, "PASS2: 黑冷却仍为0")
	t.expect_eq(s.consecutive_passes, 1, "PASS2: 连续虚手计数未增加")
	# 白落子 → 白冷却不变（白从未虚过手，初始即满=2）；黑冷却也不变
	s.to_move = Const.WHITE
	var w1 = s.play_move(Const.WHITE, 9, 9)
	t.expect(w1.ok, "PASS3: 白落子成功")
	t.expect_eq(s.pass_cooldown[Const.WHITE], 2, "PASS3: 白落子后白冷却仍=2（白从未虚过手）")
	t.expect_eq(s.pass_cooldown[Const.BLACK], 0, "PASS3: 黑冷却仍为0（白落子不增加黑冷却）")
	# 黑虚手被拒（冷却0<2，还需2个己方回合）
	var p3 = s.do_pass(Const.BLACK)
	t.expect(not p3.ok, "PASS4: 黑虚手被拒（还需2个己方回合）")
	t.expect(p3.reason.contains("2"), "PASS4: 拒绝原因含'2'（%s）" % p3.reason)
	t.expect_eq(s.to_move, Const.BLACK, "PASS4: 拒后仍轮到黑（未成手）")
	# 黑落子1次 → 冷却=1
	s.play_move(Const.BLACK, 10, 10)
	s.play_move(Const.WHITE, 11, 11)
	t.expect_eq(s.pass_cooldown[Const.BLACK], 1, "PASS5: 黑落子1次后冷却=1")
	# 黑虚手被拒（冷却1<2，还需1个己方回合）
	var p4 = s.do_pass(Const.BLACK)
	t.expect(not p4.ok, "PASS6: 黑虚手被拒（还需1个己方回合）")
	t.expect(p4.reason.contains("1"), "PASS6: 拒绝原因含'1'（%s）" % p4.reason)
	# 黑落子2次 → 冷却=2，可虚手
	s.play_move(Const.BLACK, 8, 8)
	s.play_move(Const.WHITE, 12, 12)
	t.expect_eq(s.pass_cooldown[Const.BLACK], 2, "PASS7: 黑落子2次后冷却=2")
	var p5 = s.do_pass(Const.BLACK)
	t.expect(p5.ok, "PASS8: 冷却满2回合后黑可再次虚手")
	t.expect_eq(s.pass_cooldown[Const.BLACK], 0, "PASS8: 虚手后冷却重置为0")

	# 12. 双方连续虚手 → 终局
	s = GameSession.new(Const.KOMI_DEFAULT, false)
	s.emit_signals = false
	s.do_pass(Const.BLACK)
	var w2 = s.do_pass(Const.WHITE)  # 白首次虚手（白冷却初始=2，可虚手）
	t.expect(w2.ok, "PASS9: 白首次虚手成功")
	t.expect(s.game_over, "PASS9: 双方连续虚手→终局")
	var p6 = s.do_pass(Const.BLACK)
	t.expect(not p6.ok, "PASS10: 终局后虚手被拒")

	# 13. 悔棋恢复虚手冷却状态
	s = GameSession.new(Const.KOMI_DEFAULT, false)
	s.emit_signals = false
	s.do_pass(Const.BLACK)                      # 黑虚手，冷却[BLACK]=0
	s.play_move(Const.WHITE, 9, 9)              # 白落子，冷却[WHITE]=1
	t.expect_eq(s.pass_cooldown[Const.BLACK], 0, "PASS11: 悔棋前黑冷却=0")
	s.undo()                                    # 悔掉白落子
	t.expect_eq(s.pass_cooldown[Const.BLACK], 0, "PASS11: 悔棋后黑冷却仍=0（黑虚手状态恢复）")
	t.expect_eq(s.to_move, Const.WHITE, "PASS11: 悔棋后轮到白")
	s.undo()                                    # 悔掉黑虚手
	t.expect_eq(s.pass_cooldown[Const.BLACK], 2, "PASS11: 悔到黑虚手前冷却=2（初始值）")

	# 14. clone 同步虚手冷却 + skip_pass_limits 绕过（回放旧棋谱）
	s = GameSession.new(Const.KOMI_DEFAULT, false)
	s.emit_signals = false
	s.do_pass(Const.BLACK)                      # 黑虚手，冷却[BLACK]=0
	var cloned = s.clone()
	t.expect_eq(cloned.pass_cooldown[Const.BLACK], 0, "PASS12: clone 同步黑冷却=0")
	cloned.to_move = Const.BLACK
	var pc = cloned.do_pass(Const.BLACK)
	t.expect(not pc.ok and pc.reason.contains("冷却"), "PASS12: clone 上黑连续虚手同样被拒")
	s = GameSession.new(Const.KOMI_DEFAULT, false)
	s.emit_signals = false
	s.skip_pass_limits = true
	s.do_pass(Const.BLACK)                      # 黑虚手（绕过冷却限制）
	var sp1 = s.do_pass(Const.WHITE)             # 白虚手
	t.expect(sp1.ok, "PASS13: skip_pass_limits 下白虚手成功")
	t.expect(s.game_over, "PASS13: 双方连续虚手（旧规则）→终局")

# 信号回调
func _on_move(outcome: Dictionary) -> void:
	_state.move += 1
	_state.last = outcome
	if outcome.get("passed", false):
		_state.pass += 1
	if outcome.get("deployed", false):
		_state.deploy += 1
	if outcome.get("bounced", false):
		_state.bounce += 1
	if outcome.captures.size() > 0:
		_state.captures.append(outcome)

func _on_score(_scores: Dictionary) -> void:
	_state.score += 1

func _on_end(result: Dictionary) -> void:
	_state.end += 1
	_state.end_result = result
