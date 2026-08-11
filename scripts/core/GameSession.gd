# 对局编排器：持有 board + counters + special，统一处理落子/虚手/部署/弹子/提子/计分/终局
# 纯逻辑层（RefCounted + signal），不依赖 Godot 节点，便于测试与 AI 克隆搜索
class_name GameSession
extends RefCounted

signal move_committed(outcome)   # 任意行棋后触发（含落子/虚手/部署/弹子）
signal scores_changed(scores)
signal game_ended(result)

var board: BoardModel
var komi: float = Const.KOMI_DEFAULT
var piece_limit: int = Const.PIECE_LIMIT   # 每方兵力上限（可由游戏设置覆盖）
var to_move: int = Const.BLACK
var ply: int = 0                  # 总手数（每方一手 +1）
var consecutive_passes: int = 0
var game_over: bool = false
var stones_placed: Dictionary = {}   # color -> 累计普通落子数（不可再生）
var counters: Dictionary = {}        # color -> {annihilate, normal_lost, special_lost}
var special: SpecialForces
var last_outcome: Dictionary = {}
var emit_signals: bool = true     # false 时跳过信号触发与实时分数计算（AI/模拟用）
var skip_endgame: bool = false    # true 时跳过 do_pass 的终局判定（回放用，避免终局结算的 O(N⁴) 开销）
# 劫争状态：上一手产生的劫点，下一手禁着此点；NO_KO(-1,-1) 表示无劫
var ko_point: Vector2i = GoRules.NO_KO
# 历史棋盘状态（最多3个，用于全局同形劫争检测，规则8.1）
var board_history: Array = []     # Array[PackedByteArray]
# 终局劫争标记：终局时若存在未解劫，记录劫点供 final_result 处理
var pending_ko_at_endgame: Vector2i = GoRules.NO_KO
# 性能缓存：落子后失效，查询时懒重建
# 注意：AI 搜索用的 clone session 禁用缓存（_use_cache=false），避免频繁失效开销
var _cached_scores: Dictionary = {}
var _cached_enclosures: Array = []
var _cached_sieged_groups: Array = []
var _cache_valid: bool = false
var _use_cache: bool = true  # AI clone 的 session 设为 false
# 悔棋历史栈：每次成功行棋前快照盘面与状态，undo() 弹栈恢复
var _undo_stack: Array = []
var _pending_snap: Dictionary = {}  # 待提交快照（行棋开始时取，_commit_turn 时入栈）
const MAX_UNDO: int = 30  # 悔棋栈深度上限

func _init(k: float = Const.KOMI_DEFAULT, special_enabled: bool = false, p_limit: int = Const.PIECE_LIMIT) -> void:
	komi = k
	piece_limit = p_limit
	board = BoardModel.new()
	special = SpecialForces.new()
	special.enabled = special_enabled
	_reset_state()

func _reset_state() -> void:
	to_move = Const.BLACK
	ply = 0
	consecutive_passes = 0
	game_over = false
	stones_placed = { Const.BLACK: 0, Const.WHITE: 0 }
	counters = {
		Const.BLACK: { "annihilate": 0, "normal_lost": 0, "special_lost": 0 },
		Const.WHITE: { "annihilate": 0, "normal_lost": 0, "special_lost": 0 },
	}
	special.reset()
	last_outcome = {}
	ko_point = GoRules.NO_KO
	pending_ko_at_endgame = GoRules.NO_KO
	board_history.clear()
	_undo_stack.clear()
	_pending_snap = {}
	_invalidate_cache()

func reset() -> void:
	board = BoardModel.new()
	_reset_state()

# 失效缓存（落子/部署/虚手/提子后调用）
func _invalidate_cache() -> void:
	_cache_valid = false
	_cached_scores = {}
	_cached_enclosures = []
	_cached_sieged_groups = []

# 重建缓存
func _ensure_cache() -> void:
	if not _use_cache:
		return
	if _cache_valid:
		return
	# 先计算围困组群和围空（各一次遍历），供 ScoreCalculator 和缓存复用（避免重复遍历）
	_cached_sieged_groups = []
	for g in board.all_groups():
		if SiegeDetector.is_sieged(board, g):
			_cached_sieged_groups.append(g)
	_cached_enclosures = TerritoryDetector.enclosures(board)
	_cached_scores = ScoreCalculator.compute(board, counters, _cached_sieged_groups, _cached_enclosures)
	_cache_valid = true

# ===== 查询 =====
func scores() -> Dictionary:
	if _use_cache:
		_ensure_cache()
		return _cached_scores
	return ScoreCalculator.compute(board, counters)

# 缓存的围空（供 BoardView 渲染用，避免每次 _draw 重算）
func cached_enclosures() -> Array:
	if _use_cache:
		_ensure_cache()
		return _cached_enclosures
	return TerritoryDetector.enclosures(board)

# 缓存的被围困组群（供 BoardView 渲染用）
func cached_sieged_groups() -> Array:
	if _use_cache:
		_ensure_cache()
		return _cached_sieged_groups
	# 非缓存模式：独立判定
	var result: Array = []
	for g in board.all_groups():
		if SiegeDetector.is_sieged(board, g):
			result.append(g)
	return result

func pieces_left(color: int) -> int:
	return piece_limit - int(stones_placed.get(color, 0))

func can_place(color: int) -> bool:
	if game_over:
		return false
	return pieces_left(color) > 0

# 该色是否还有任意合法落子（用于强制终局判定）
func has_legal_move(color: int) -> bool:
	if not can_place(color):
		return false
	for row in range(board.size):
		for col in range(board.size):
			if board.get_at(row, col) != Const.EMPTY:
				continue
			# 隐子占点：对该色而言不可见但占点，is_legal 会判非法（点被占）
			if GoRules.is_legal(board, row, col, color, ko_point):
				return true
	return false

# ===== 行棋 =====
# 落子（含弹子/暴露/提子全自动处理）
func play_move(color: int, row: int, col: int) -> Dictionary:
	var outcome: Dictionary = _new_outcome("move")
	if game_over:
		outcome.ok = false
		outcome.reason = "对局已结束"
		return outcome
	if color != to_move:
		outcome.ok = false
		outcome.reason = "非该方行棋"
		return outcome
	if not can_place(color):
		outcome.ok = false
		outcome.reason = "兵力已用尽"
		return outcome
	if not board.in_bounds(row, col):
		outcome.ok = false
		outcome.reason = "越界"
		return outcome

	# 校验通过，取行棋前快照（供悔棋恢复；_commit_turn 入栈）
	_begin_undo_snapshot()

	# 1. 重叠检测：落子点是否有对方隐子（规则：隐子重叠→弹子）
	var overlapped_piece: Dictionary = special.hidden_opponent_at(Vector2i(col, row), color)
	if not overlapped_piece.is_empty():
		# 隐子现形
		special.reveal(overlapped_piece, "重叠")
		outcome.revealed = [overlapped_piece]
		# 寻找周围八格合法点（优先活形）
		var bounce_pos: Variant = _find_bounce_position(row, col, color)
		if bounce_pos == null:
			# 八格均不可落子 → 退回重下（不计战损、不切回合）
			outcome.ok = false
			outcome.reason = "撞隐子且八格均不可落子，请重新选择"
			outcome.type = "overlap_fail"
			outcome.bounced = false
			outcome.overlap_pos = Vector2i(col, row)
			# 不调用 _commit_turn，对手重下（不切换 to_move）
			_invalidate_cache()
			_emit_move(outcome)
			return outcome
		# 在 bounce_pos 落子（弹子成功）
		var bp: Vector2i = bounce_pos
		outcome.type = "bounce"
		outcome.bounced = true
		outcome.overlap_pos = Vector2i(col, row)
		outcome.placed = bp
		outcome.mover_color = color
		# 邻接暴露：弹子点四邻对方隐子现形
		var adj_b := special.hidden_opponent_adjacent(board, bp, color)
		for ap in adj_b:
			if not ap.is_empty() and ap.hidden:
				special.reveal(ap, "邻接")
				outcome.revealed.append(ap)
		# 执行落子（弹子点）
		var res = GoRules.try_move(board, bp.y, bp.x, color, ko_point)
		if not res.legal:
			# 不应发生（_find_bounce_position 已筛合法点）
			outcome.ok = false
			outcome.reason = "弹子点意外非法: " + res.reason
			_invalidate_cache()
			_emit_move(outcome)
			return outcome
		outcome.captures = res.captured
		outcome.captured_color = res.captured_color
		ko_point = res.ko_point
		# 处理被提子
		_process_captures(res, color)
		# 计数普通落子
		stones_placed[color] = int(stones_placed.get(color, 0)) + 1
		# 推进历史
		_push_board_history()
		_advance_ply_and_expiry(outcome)
		_commit_turn(outcome, color, true)
		return outcome

	# 2. 邻接暴露：四邻对方隐子现形（无重叠）
	var adj2 := special.hidden_opponent_adjacent(board, Vector2i(col, row), color)
	for ap in adj2:
		if not ap.is_empty() and ap.hidden:
			special.reveal(ap, "邻接")
			outcome.revealed.append(ap)

	# 3. 正常落子（隐子在 board 上为普通棋子，try_move 自动处理吃子+劫判定）
	var res = GoRules.try_move(board, row, col, color, ko_point)
	if not res.legal:
		outcome.ok = false
		outcome.reason = res.reason
		return outcome

	outcome.placed = res.placed
	outcome.mover_color = color
	outcome.captures = res.captured
	outcome.captured_color = res.captured_color
	# 更新劫点：本手产生的劫点（下一手禁着）；无劫则清除
	ko_point = res.ko_point

	# 4. 处理被提子
	_process_captures(res, color)

	# 5. 计数普通落子（不含特种）
	stones_placed[color] = int(stones_placed.get(color, 0)) + 1

	# 6. 推进历史（用于全局同形劫争检测）
	_push_board_history()

	_advance_ply_and_expiry(outcome)
	_commit_turn(outcome, color, true)
	return outcome

# 处理被提子：区分普通子/特种部队子，累计战损与歼灭
func _process_captures(res, mover_color: int) -> void:
	for cap_pos in res.captured:
		var cap_row: int = cap_pos.y
		var captured_color: int = res.captured_color
		var was_special: bool = special.is_special_at(cap_pos)
		if was_special:
			special.mark_captured(cap_pos)
			counters[captured_color].special_lost += 1
		else:
			counters[captured_color].normal_lost += 1
		# 歼灭分：提吃发生在「提子方」的防御区（己境/边境）
		if Const.is_defense_zone(cap_row, mover_color):
			counters[mover_color].annihilate += 1

# 寻找弹子点：对手落子撞隐子时，从周围八格选合法点（优先活形=气数最多）
# 返回 Vector2i 或 null
func _find_bounce_position(row: int, col: int, color: int) -> Variant:
	var best_pos: Variant = null
	var best_libs: int = -1
	for dr in [-1, 0, 1]:
		for dc in [-1, 0, 1]:
			if dr == 0 and dc == 0:
				continue
			var r: int = row + dr
			var c: int = col + dc
			if not board.in_bounds(r, c):
				continue
			if board.get_at(r, c) != Const.EMPTY:
				continue
			if not GoRules.is_legal(board, r, c, color, ko_point):
				continue
			# 模拟落子评估活形度（落子后己方组群气数）
			var test_board := board.clone()
			var test_res = GoRules.try_move(test_board, r, c, color, ko_point)
			if not test_res.legal:
				continue
			var g: Dictionary = test_board.group_at(r, c)
			var libs: int = test_board.liberties(g.stones).size()
			if libs > best_libs:
				best_libs = libs
				best_pos = Vector2i(c, r)
	return best_pos

# 推进历史棋盘状态（最多3个，用于全局同形劫争检测，规则8.1 + 程序化文档1.5）
func _push_board_history() -> void:
	board_history.append(board.grid.duplicate())
	if board_history.size() > 3:
		board_history.pop_front()

# 检查盘面是否与历史状态重复（全局同形劫争）
func _is_board_in_history() -> bool:
	var cur: PackedByteArray = board.grid
	for h in board_history:
		if cur.size() != h.size():
			continue
		var same: bool = true
		for i in cur.size():
			if cur[i] != h[i]:
				same = false
				break
		if same:
			return true
	return false

# 虚手（pass 是 GDScript 关键字，故用 do_pass）
func do_pass(color: int) -> Dictionary:
	var outcome: Dictionary = _new_outcome("pass")
	if game_over:
		outcome.ok = false
		outcome.reason = "对局已结束"
		return outcome
	if color != to_move:
		outcome.ok = false
		outcome.reason = "非该方行棋"
		return outcome
	# 校验通过，取行棋前快照（终局虚手不 push，因 _commit_turn 不被调用）
	_begin_undo_snapshot()
	consecutive_passes += 1
	outcome.passed = true
	# 虚手不产生劫，清除劫点
	ko_point = GoRules.NO_KO
	_advance_ply_and_expiry(outcome)
	# 规则9.1：双方连续虚手 → 终局
	# 规则9.2：一方171子用尽 且 双方连续虚手 → 强制终局（9.1 的特例）
	# 规则1.2：双方均无法落子 → 强制终局
	# skip_endgame=true 时跳过终局判定（回放用：避免 _both_cannot_move 的 O(N⁴) 遍历
	# 和 final_result 的终局结算开销，回放只需推进盘面）
	var end_reason: String = ""
	if not skip_endgame and consecutive_passes >= 2:
		var black_exhausted: bool = pieces_left(Const.BLACK) <= 0
		var white_exhausted: bool = pieces_left(Const.WHITE) <= 0
		if black_exhausted or white_exhausted:
			end_reason = "一方兵力用尽且双方连续虚手"
		elif _both_cannot_move():
			end_reason = "双方均无法落子"
		else:
			end_reason = "双方连续虚手"
	if end_reason != "":
		_end_game(end_reason)
		outcome.game_over = true
		outcome.result = last_outcome
		_emit_move(outcome)
		return outcome
	_commit_turn(outcome, color, false)
	return outcome

# 部署特种部队（消耗本回合行棋权，隐子真实占点）
func deploy_special(color: int, row: int, col: int) -> Dictionary:
	var outcome: Dictionary = _new_outcome("deploy")
	if game_over:
		outcome.ok = false
		outcome.reason = "对局已结束"
		return outcome
	if color != to_move:
		outcome.ok = false
		outcome.reason = "非该方行棋"
		return outcome
	if not special.can_deploy(color, ply):
		outcome.ok = false
		outcome.reason = "特种部队不可用（次数/冷却/未开启）"
		return outcome
	if not board.in_bounds(row, col):
		outcome.ok = false
		outcome.reason = "越界"
		return outcome
	if board.get_at(row, col) != Const.EMPTY:
		outcome.ok = false
		outcome.reason = "该点已有棋子"
		return outcome
	# 校验通过，取行棋前快照
	_begin_undo_snapshot()
	# 部署：隐子作为普通棋子置于 board
	var pos := Vector2i(col, row)
	special.deploy(pos, color, ply)
	board.set_at(row, col, color)
	# 部署不消耗 171 兵力；消耗本回合行棋权
	outcome.placed = pos
	outcome.mover_color = color
	outcome.deployed = true
	# 部署特种不产生劫（隐子占点，无提子）
	ko_point = GoRules.NO_KO
	# 部署也推进历史（保持劫争检测一致性）
	_push_board_history()
	_advance_ply_and_expiry(outcome)
	_commit_turn(outcome, color, false)
	return outcome

# ===== 内部 =====
func _new_outcome(t: String) -> Dictionary:
	return {
		"ok": true,
		"type": t,
		"reason": "",
		"placed": Vector2i(-1, -1),
		"captures": [],
		"captured_color": Const.EMPTY,
		"bounced": false,
		"overlap_pos": Vector2i(-1, -1),
		"revealed": [],
		"expired": [],
		"passed": false,
		"deployed": false,
		"game_over": false,
		"result": {},
		"ply": ply,
	}

func _advance_ply_and_expiry(outcome: Dictionary) -> void:
	# 到期现形（在换手前，基于当前 ply）
	var expired := special.check_expiry(ply + 1)
	outcome.expired = expired

func _commit_turn(outcome: Dictionary, color: int, did_place: bool) -> void:
	# 任何实际行棋（落子/部署/弹子）取消连续虚手；虚手已在 pass() 中累计
	if not outcome.passed:
		consecutive_passes = 0
	ply += 1
	outcome.ply = ply
	to_move = Const.opponent(color)
	# 悔棋栈：将行棋前快照入栈（若 _pending_snap 为空则跳过，如终局虚手不悔棋）
	if not _pending_snap.is_empty():
		_undo_stack.append(_pending_snap)
		_pending_snap = {}
		if _undo_stack.size() > MAX_UNDO:
			_undo_stack.pop_front()
	# 失效缓存（盘面或状态已变化）
	_invalidate_cache()
	_emit_move(outcome)

func _emit_move(outcome: Dictionary) -> void:
	if not emit_signals:
		return
	emit_signal("move_committed", outcome)
	emit_signal("scores_changed", scores())

# 双方均无法落子 → 强制终局（规则1.2）
func _both_cannot_move() -> bool:
	if has_legal_move(Const.BLACK) or has_legal_move(Const.WHITE):
		return false
	return true

func _end_game(reason: String) -> void:
	game_over = true
	last_outcome = final_result(reason)
	if emit_signals:
		emit_signal("game_ended", last_outcome)

# 终局结算（含特种部队奖励 + 终局劫争处理）
# 规则9.3：① 双方虚手 → ② 处理劫争 → ③ 最终死活判定 → ④ 冻结分数 → ⑤ 读取总分
func final_result(reason: String = "终局") -> Dictionary:
	# ② 处理终局劫争（规则8.3）：若有未解劫，模拟双方获胜取净增较大者
	_resolve_ko_at_endgame()
	# ③ 最终死活判定已由 SiegeDetector 在 compute 中完成
	# ④ 冻结分数：以下为终局分数（含特种奖励增量）
	var rewards := _compute_special_rewards()
	var res := ScoreCalculator.compute_final(board, counters, komi, rewards)
	res.reason = reason
	res.ply = ply
	return res

# 终局劫争处理（规则8.3 + 程序化文档6.2）
# 简化实现：若 ko_point 存在，模拟双方提劫，比较净分变化，取较大者应用
func _resolve_ko_at_endgame() -> void:
	if ko_point.x < 0 or ko_point.y < 0:
		return
	# 保存当前状态
	var saved_board := board.clone()
	var saved_counters := counters.duplicate(true)
	var saved_ko := ko_point
	# 模拟黑方提劫
	var black_net := _simulate_ko_win(Const.BLACK)
	# 还原
	board = saved_board.clone()
	counters = saved_counters.duplicate(true)
	ko_point = saved_ko
	# 模拟白方提劫
	var white_net := _simulate_ko_win(Const.WHITE)
	# 还原
	board = saved_board.clone()
	counters = saved_counters.duplicate(true)
	ko_point = saved_ko
	# 取净增较大者；相等则保留当前盘面（实际控制方）
	if black_net > white_net:
		_apply_ko_win(Const.BLACK)
	elif white_net > black_net:
		_apply_ko_win(Const.WHITE)
	# 相等则不应用（保留现状）
	ko_point = GoRules.NO_KO
	pending_ko_at_endgame = GoRules.NO_KO

# 模拟某方提劫后分数净变化（规则8.3）
# 净变化 = 模拟后 total - 模拟前 total（含歼灭、战损、活子、围空、围困）
func _simulate_ko_win(winner: int) -> int:
	var before: Dictionary = ScoreCalculator.compute(board, counters)
	var before_total: int = (before[winner] as ScoreCalculator.Breakdown).total()
	_apply_ko_win(winner)
	var after: Dictionary = ScoreCalculator.compute(board, counters)
	var after_total: int = (after[winner] as ScoreCalculator.Breakdown).total()
	return after_total - before_total

# 应用某方提劫（修改 board/counters）
func _apply_ko_win(winner: int) -> void:
	if ko_point.x < 0 or ko_point.y < 0:
		return
	var kp_row: int = ko_point.y
	var kp_col: int = ko_point.x
	# 模拟提劫：在 ko_point 落 winner 子（如果合法）
	if not board.in_bounds(kp_row, kp_col):
		return
	if board.get_at(kp_row, kp_col) != Const.EMPTY:
		# ko 点已被占 → 无需模拟
		return
	var res = GoRules.try_move(board, kp_row, kp_col, winner, GoRules.NO_KO)
	if not res.legal:
		return
	# 处理被提子（不计特种区分，简化为普通战损）
	for cap_pos in res.captured:
		var captured_color: int = res.captured_color
		var was_special: bool = special.is_special_at(cap_pos)
		if was_special:
			special.mark_captured(cap_pos)
			counters[captured_color].special_lost += 1
		else:
			counters[captured_color].normal_lost += 1
		if Const.is_defense_zone(cap_pos.y, winner):
			counters[winner].annihilate += 1
	ko_point = GoRules.NO_KO
	_invalidate_cache()

# 计算特种部队终局奖励增量
# 返回 { color: { occ_live_delta, occ_territ_delta, def_siege_delta } }
func _compute_special_rewards() -> Dictionary:
	var out: Dictionary = {
		Const.BLACK: { "occ_live_delta": 0, "occ_territ_delta": 0, "def_siege_delta": 0 },
		Const.WHITE: { "occ_live_delta": 0, "occ_territ_delta": 0, "def_siege_delta": 0 },
	}
	for color in [Const.BLACK, Const.WHITE]:
		for p in special.alive_pieces(color):
			var row: int = p.pos.y
			var zone: int = Const.zone_of_row(row)
			var in_opp: bool = zone == Const.enemy_zone(color)
			var in_own: bool = zone == Const.own_zone(color)
			# 活棋判定
			var g: Dictionary = board.group_at(row, p.pos.x)
			if g.stones.is_empty():
				continue
			if SiegeDetector.is_sieged(board, g):
				continue
			var participates: bool = TerritoryDetector.stone_participates_in_enclosure(board, row, p.pos.x, color)
			if in_opp and participates:
				# 敌后渗透：该包围圈围空分翻倍（再加一次）
				var enc_terr := _enclosure_territory_score(color, p.pos)
				out[color].occ_territ_delta += enc_terr
			elif in_opp and not participates:
				# 潜伏存活：+3 替代 +1 → 增量 +2
				out[color].occ_live_delta += 2
			elif in_own and participates:
				# 协助防御（边境建功）：该包围圈防御分总额 +50%（向上取整）
				# 注意：仅在边境线上才触发（规则：边境建功要求该子在边境线）
				if row == Const.BORDER_ROW:
					var enc_def := _enclosure_defense_score(color, p.pos)
					# 规则：该包围圈产生的防御分总额增加 50%（向上取整）
					out[color].def_siege_delta += int(ceil(enc_def * 0.5))
	return out

# 某色、某参与棋子所在围空的围空分（空点在攻击区 *2）
func _enclosure_territory_score(color: int, piece_pos: Vector2i) -> int:
	var best: int = 0
	for e in TerritoryDetector.enclosures_of(board, color):
		var hit: bool = false
		for p in e.points:
			for n in board.neighbors(p.y, p.x):
				if n[0] == piece_pos.y and n[1] == piece_pos.x:
					hit = true
					break
			if hit:
				break
		if not hit:
			continue
		var s: int = 0
		for p in e.points:
			if Const.is_attack_zone(p.y, color):
				s += 2
		best = max(best, s)
	return best

# 某色、某参与棋子所在围空的防御分（圈内被围困的对方子在防御区 *1）
func _enclosure_defense_score(color: int, piece_pos: Vector2i) -> int:
	var best: int = 0
	for e in TerritoryDetector.enclosures_of(board, color):
		var hit: bool = false
		for p in e.points:
			for n in board.neighbors(p.y, p.x):
				if n[0] == piece_pos.y and n[1] == piece_pos.x:
					hit = true
					break
			if hit:
				break
		if not hit:
			continue
		# 圈内对方子（被该围空包围的空块边界外的对方子？这里取围空空点四邻的对方子）
		var s: int = 0
		var seen: Dictionary = {}
		for p in e.points:
			for n in board.neighbors(p.y, p.x):
				var ni: int = n[0] * board.size + n[1]
				if seen.has(ni):
					continue
				var v: int = board.get_at(n[0], n[1])
				if v == Const.opponent(color):
					seen[ni] = true
					# 该子是否被围困（在防御区）
					var og: Dictionary = board.group_at(n[0], n[1])
					if not og.stones.is_empty() and SiegeDetector.is_sieged(board, og) and Const.is_defense_zone(n[0], color):
						s += 1
		best = max(best, s)
	return best

# ===== 悔棋 =====
# 取当前状态快照（行棋开始前调用，_commit_turn 时入栈）
func _take_snapshot() -> Dictionary:
	return {
		"board": board.clone(),
		"to_move": to_move,
		"ply": ply,
		"consecutive_passes": consecutive_passes,
		"game_over": game_over,
		"stones_placed": stones_placed.duplicate(true),
		"counters": counters.duplicate(true),
		"special": special.clone(),
		"ko_point": ko_point,
		"pending_ko_at_endgame": pending_ko_at_endgame,
		"board_history": board_history.duplicate(true),
	}

# 在行棋开始（校验通过后、修改前）调用：暂存快照，等 _commit_turn 入栈
func _begin_undo_snapshot() -> void:
	_pending_snap = _take_snapshot()

# 是否可悔棋
func can_undo() -> bool:
	return not _undo_stack.is_empty() and not game_over

# 悔棋：恢复到上一手前状态
func undo() -> Dictionary:
	var outcome: Dictionary = _new_outcome("undo")
	if game_over:
		outcome.ok = false
		outcome.reason = "对局已结束，无法悔棋"
		return outcome
	if _undo_stack.is_empty():
		outcome.ok = false
		outcome.reason = "无可悔棋历史"
		return outcome
	var snap: Dictionary = _undo_stack.pop_back()
	board = snap.board
	to_move = snap.to_move
	ply = snap.ply
	consecutive_passes = snap.consecutive_passes
	game_over = snap.game_over
	stones_placed = snap.stones_placed
	counters = snap.counters
	special = snap.special
	ko_point = snap.ko_point
	pending_ko_at_endgame = snap.pending_ko_at_endgame
	board_history = snap.board_history
	_pending_snap = {}
	_invalidate_cache()
	outcome.ok = true
	outcome.undid = true
	outcome.mover_color = to_move  # 悔棋后轮到该方
	if emit_signals:
		emit_signal("move_committed", outcome)
		emit_signal("scores_changed", scores())
	return outcome

# 克隆（供 AI 搜索）
func clone() -> GameSession:
	var s := GameSession.new(komi, special.enabled, piece_limit)
	s.board = board.clone()
	s.to_move = to_move
	s.ply = ply
	s.consecutive_passes = consecutive_passes
	s.game_over = game_over
	s.stones_placed = stones_placed.duplicate(true)
	s.counters = counters.duplicate(true)
	s.special = special.clone()
	s.last_outcome = last_outcome.duplicate(true)
	s.ko_point = ko_point  # 劫点状态同步（AI 搜索需正确判定劫禁着）
	s.board_history = board_history.duplicate(true)
	s.pending_ko_at_endgame = pending_ko_at_endgame
	s._use_cache = false  # AI 搜索用，禁用缓存避免频繁失效开销
	return s

# 创建 AI 视角的公平克隆：移除对手未现形隐子（规则：隐子对对手不可见）
# AI 不应知晓对手隐子位置，故在克隆中将其从棋盘与特种列表中剔除。
# 用于 AI 决策（候选生成/合法性/搜索），不影响真实 session。
func clone_for_ai(ai_color: int) -> GameSession:
	var s := clone()
	if not s.special.enabled:
		return s
	var opp := Const.opponent(ai_color)
	# 倒序遍历移除对手隐子，避免删除时索引错位
	for i in range(s.special.pieces.size() - 1, -1, -1):
		var p: Dictionary = s.special.pieces[i]
		if p.captured or not p.hidden:
			continue
		if p.color != opp:
			continue
		# 从棋盘移除（视为空点）
		s.board.set_at(p.pos.y, p.pos.x, Const.EMPTY)
		s.special.pieces.remove_at(i)
	s._invalidate_cache()
	return s
