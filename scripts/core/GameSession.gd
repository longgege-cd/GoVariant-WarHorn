# 对局编排器：持有 board + counters + special，统一处理落子/虚手/部署/伏击/提子/计分/终局
# 纯逻辑层（RefCounted + signal），不依赖 Godot 节点，便于测试与 AI 克隆搜索
class_name GameSession
extends RefCounted

signal move_committed(outcome)   # 任意行棋后触发（含落子/虚手/部署/伏击）
signal scores_changed(scores)
signal game_ended(result)

var board: BoardModel
var komi: float = Const.KOMI_DEFAULT
var to_move: int = Const.BLACK
var ply: int = 0                  # 总手数（每方一手 +1）
var consecutive_passes: int = 0
var game_over: bool = false
var stones_placed: Dictionary = {}   # color -> 累计普通落子数（不可再生）
var counters: Dictionary = {}        # color -> {annihilate, normal_lost, special_lost, ambushed}
var special: SpecialForces
var last_outcome: Dictionary = {}
var emit_signals: bool = true     # false 时跳过信号触发与实时分数计算（AI/模拟用）
# 劫争状态：上一手产生的劫点，下一手禁着此点；NO_KO(-1,-1) 表示无劫
var ko_point: Vector2i = GoRules.NO_KO
# 性能缓存：落子后失效，查询时懒重建
# 注意：AI 搜索用的 clone session 禁用缓存（_use_cache=false），避免频繁失效开销
var _cached_scores: Dictionary = {}
var _cached_enclosures: Array = []
var _cached_sieged_groups: Array = []
var _cache_valid: bool = false
var _use_cache: bool = true  # AI clone 的 session 设为 false

func _init(k: float = Const.KOMI_DEFAULT, special_enabled: bool = false) -> void:
	komi = k
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
		Const.BLACK: { "annihilate": 0, "normal_lost": 0, "special_lost": 0, "ambushed": 0 },
		Const.WHITE: { "annihilate": 0, "normal_lost": 0, "special_lost": 0, "ambushed": 0 },
	}
	special.reset()
	last_outcome = {}
	ko_point = GoRules.NO_KO
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
	_cached_scores = ScoreCalculator.compute(board, counters)
	_cached_enclosures = TerritoryDetector.enclosures(board)
	# 围困组群 = 被对方包围且无两眼的棋子（独立判定，规则4.2）
	_cached_sieged_groups = []
	for g in board.all_groups():
		if SiegeDetector.is_sieged(board, g):
			_cached_sieged_groups.append(g)
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
	return Const.PIECE_LIMIT - int(stones_placed.get(color, 0))

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
# 落子（含伏击/暴露/提子全自动处理）
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

	# 1. 伏击检测：落子点是否有对方隐子
	var ambushed_piece: Dictionary = special.hidden_opponent_at(Vector2i(col, row), color)
	if not ambushed_piece.is_empty():
		# 伏击：落子被消灭，不实际落子
		special.reveal(ambushed_piece, "伏击")
		outcome.type = "ambush"
		outcome.ambush = true
		outcome.placed = Vector2i(col, row)  # 伏击发生位置（用于特效/视图）
		outcome.mover_color = color  # 被伏击方
		outcome.revealed = [ambushed_piece]
		counters[color].ambushed += 1
		# 同时检查四邻其它隐子暴露
		var adj := special.hidden_opponent_adjacent(board, Vector2i(col, row), color)
		for ap in adj:
			if not ap.is_empty() and ap.hidden:
				special.reveal(ap, "邻接")
				outcome.revealed.append(ap)
		# 伏击未实际落子，劫点清除（无新劫产生）
		ko_point = GoRules.NO_KO
		# 到期检查
		_advance_ply_and_expiry(outcome)
		_commit_turn(outcome, color, false)
		return outcome

	# 2. 邻接暴露：四邻对方隐子现形（无伏击）
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

	# 4. 处理被提子：区分普通子/特种部队子，累计战损与歼灭
	for cap_pos in res.captured:
		var cap_row: int = cap_pos.y
		var cap_col: int = cap_pos.x
		var captured_color: int = res.captured_color
		var was_special: bool = special.is_special_at(cap_pos)
		if was_special:
			special.mark_captured(cap_pos)
			counters[captured_color].special_lost += 1
		else:
			counters[captured_color].normal_lost += 1
		# 歼灭分：提吃发生在「提子方」的防御区（己境/边境）
		if Const.is_defense_zone(cap_row, color):
			counters[color].annihilate += 1

	# 5. 计数普通落子（不含特种）
	stones_placed[color] = int(stones_placed.get(color, 0)) + 1

	_advance_ply_and_expiry(outcome)
	_commit_turn(outcome, color, true)
	return outcome

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
	consecutive_passes += 1
	outcome.passed = true
	# 虚手不产生劫，清除劫点
	ko_point = GoRules.NO_KO
	_advance_ply_and_expiry(outcome)
	if consecutive_passes >= 2:
		_end_game("双方连续虚手")
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
		"ambush": false,
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
	# 任何实际行棋（落子/部署/伏击）取消连续虚手；虚手已在 pass() 中累计
	if not outcome.passed:
		consecutive_passes = 0
	ply += 1
	outcome.ply = ply
	to_move = Const.opponent(color)
	# 失效缓存（盘面或状态已变化）
	_invalidate_cache()
	# 强制终局依赖连续虚手或兵力用尽（避免每手 O(n²) 的 has_legal_move 开销）
	# 若双方均无法落子，模拟器/玩家会被迫虚手，连续虚手终局
	_emit_move(outcome)

func _emit_move(outcome: Dictionary) -> void:
	if not emit_signals:
		return
	emit_signal("move_committed", outcome)
	emit_signal("scores_changed", scores())

func _both_cannot_move() -> bool:
	# 双方都没有合法落子且无虚手余地？规则：双方均无法落子时强制终局
	# 这里判定：当前方与对方都无法落子（兵力用尽或无合法点）
	if has_legal_move(Const.BLACK) or has_legal_move(Const.WHITE):
		return false
	return true

func _end_game(reason: String) -> void:
	game_over = true
	last_outcome = final_result(reason)
	if emit_signals:
		emit_signal("game_ended", last_outcome)

# 终局结算（含特种部队成功奖励）
func final_result(reason: String = "终局") -> Dictionary:
	var rewards := _compute_special_rewards()
	var res := ScoreCalculator.compute_final(board, counters, komi, rewards)
	res.reason = reason
	res.ply = ply
	return res

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
				# 协助防御：该包围圈防御分翻倍（再加一次）
				var enc_def := _enclosure_defense_score(color, p.pos)
				out[color].def_siege_delta += enc_def
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

# 克隆（供 AI 搜索）
func clone() -> GameSession:
	var s := GameSession.new(komi, special.enabled)
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
	s._use_cache = false  # AI 搜索用，禁用缓存避免频繁失效开销
	return s
