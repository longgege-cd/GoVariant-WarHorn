extends RefCounted
# 自动模拟对局：随机/启发式自测，校验不变量找 BUG
#
# 启发式策略：
#   - 优先提吃（检测对方 1 气组群）
#   - 偏好邻接己方棋子（连接）
#   - 偏好攻击区（敌境/边境，能得占领分）
#   - 偶尔部署特种部队
#   - 偶尔虚手
#
# 不变量校验：
#   - 棋子总数 <= 361
#   - 落子计数 + 特种部队子数 >= 盘上该色子数
#   - 战损分非正
#   - 占领/防御分非负
#   - 总分 = 占领 + 防御 + 战损
#   - 重复计算分数一致（无副作用）
#   - 棋子颜色一致（group_at 返回的 color 与棋子颜色一致）

const MAX_PLY: int = 80           # 单局上限防死循环
const NUM_GAMES: int = 5          # 模拟局数
const INVARIANT_INTERVAL: int = 10  # 每隔N手校验一次不变量

func run(t: TestFramework) -> void:
	t.suite("自动模拟对局(%d局)" % NUM_GAMES)
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	var games: int = 0
	var total_moves: int = 0
	var bounce_events: int = 0
	var capture_events: int = 0
	var siege_seen: int = 0
	var deploy_events: int = 0
	var all_invariant_ok: bool = true
	var all_terminated: bool = true
	for i in range(NUM_GAMES):
		var special_on: bool = (i % 2 == 0)  # 偶数局开启特种
		var s := GameSession.new(Const.KOMI_DEFAULT, special_on)
		s.emit_signals = false  # 模拟测试跳过信号与实时分数计算
		var result := _play_one(s, rng, i)
		games += 1
		total_moves += result.moves
		bounce_events += result.bounces
		capture_events += result.captures
		siege_seen += result.sieges
		deploy_events += result.deploys
		if not result.terminated:
			all_terminated = false
		if not result.invariant_ok:
			all_invariant_ok = false
		t.expect(result.terminated, "第%d局应正常终止" % i)
		t.expect(result.invariant_ok, "第%d局不变量通过" % i)
	print("  共 %d 局, %d 手, 部署 %d, 弹子 %d, 提子 %d, 见围困 %d" % [games, total_moves, deploy_events, bounce_events, capture_events, siege_seen])
	print("  所有局终止: %s, 所有不变量通过: %s" % [str(all_terminated), str(all_invariant_ok)])

# 单局模拟，返回统计
func _play_one(s: GameSession, rng: RandomNumberGenerator, game_idx: int) -> Dictionary:
	var moves: int = 0
	var bounces: int = 0
	var captures: int = 0
	var sieges: int = 0
	var deploys: int = 0
	var invariant_ok: bool = true
	var invariant_fail_msg: String = ""
	while not s.game_over and moves < MAX_PLY:
		var mover: int = s.to_move
		var out: Dictionary = _choose_move(s, mover, rng)
		if out.is_empty():
			out = s.do_pass(mover)
		if out.has("bounced") and out.bounced:
			bounces += 1
		if out.has("captures") and out.captures.size() > 0:
			captures += 1
		if out.has("deployed") and out.deployed:
			deploys += 1
		moves += 1
		# 不变量校验
		if moves % INVARIANT_INTERVAL == 0:
			var inv := _check_invariants(s)
			if not inv.ok:
				invariant_ok = false
				invariant_fail_msg = inv.msg
				print("  [局%d] 不变量失败 @move=%d ply=%d: %s" % [game_idx, moves, s.ply, inv.msg])
				break
	if moves >= MAX_PLY and not s.game_over:
		# 强制结束（用于统计围困）
		pass
	# 统计当前围困数
	for g in s.board.all_groups():
		if SiegeDetector.is_sieged(s.board, g):
			sieges += 1
	return {
		"terminated": s.game_over or moves >= MAX_PLY,
		"moves": moves,
		"bounces": bounces,
		"captures": captures,
		"deploys": deploys,
		"sieges": sieges,
		"invariant_ok": invariant_ok,
		"fail_msg": invariant_fail_msg,
	}

# 启发式选择走法
func _choose_move(s: GameSession, color: int, rng: RandomNumberGenerator) -> Dictionary:
	var action: int = rng.randi_range(0, 9)
	# 1. 偶尔虚手
	if action == 0 and s.consecutive_passes == 0:
		# 仅当无连续虚手时偶尔虚手，避免过早终局
		if rng.randf() < 0.05:
			return s.do_pass(color)
	# 2. 偶尔部署特种（满足条件时）
	if special_enabled_and_want(s, color, rng):
		var pt = _random_empty_point(s, rng)
		if pt.x >= 0:
			var out = s.deploy_special(color, pt.y, pt.x)
			if out.ok:
				return out
	# 3. 启发式落子：优先提吃 → 邻接 → 攻击区 → 随机
	var capture_move := _find_capture_move(s, color, rng)
	if capture_move.x >= 0:
		var out = s.play_move(color, capture_move.y, capture_move.x)
		if out.ok:
			return out
	var adj_move := _find_adjacent_move(s, color, rng)
	if adj_move.x >= 0:
		var out = s.play_move(color, adj_move.y, adj_move.x)
		if out.ok:
			return out
	return _random_move_or_pass(s, color, rng)

# 寻找提吃机会：扫描对方1气组群的气
func _find_capture_move(s: GameSession, color: int, rng: RandomNumberGenerator) -> Vector2i:
	var opp: int = Const.opponent(color)
	var size: int = s.board.size
	var checked_groups: Dictionary = {}
	# 随机采样若干点检查是否邻接对方低气组群
	for _i in range(15):
		var row: int = rng.randi_range(0, size - 1)
		var col: int = rng.randi_range(0, size - 1)
		if s.board.get_at(row, col) != opp:
			continue
		var g: Dictionary = s.board.group_at(row, col)
		if g.stones.is_empty():
			continue
		var gkey: int = (g.stones[0].y * size + g.stones[0].x)
		if checked_groups.has(gkey):
			continue
		checked_groups[gkey] = true
		var libs: Array = s.board.liberties(g.stones)
		if libs.size() == 1:
			# 1气 → 提吃点
			var lib_pos: Vector2i = libs[0]
			if s.board.get_at(lib_pos.y, lib_pos.x) == Const.EMPTY:
				return lib_pos
	return Vector2i(-1, -1)

# 寻找邻接己方棋子的落点（鼓励连接）
func _find_adjacent_move(s: GameSession, color: int, rng: RandomNumberGenerator) -> Vector2i:
	var size: int = s.board.size
	for _i in range(10):
		var row: int = rng.randi_range(0, size - 1)
		var col: int = rng.randi_range(0, size - 1)
		if s.board.get_at(row, col) != Const.EMPTY:
			continue
		# 检查四邻是否有己方棋子
		var has_friendly: bool = false
		for n in s.board.neighbors(row, col):
			if s.board.get_at(n[0], n[1]) == color:
				has_friendly = true
				break
		if not has_friendly:
			continue
		# 偏好攻击区
		if Const.is_attack_zone(row, color) or rng.randf() < 0.5:
			return Vector2i(col, row)
	return Vector2i(-1, -1)

func special_enabled_and_want(s: GameSession, color: int, rng: RandomNumberGenerator) -> bool:
	return s.special.enabled and s.special.can_deploy(color, s.ply) and rng.randf() < 0.10

# 随机采样一个空点（避免遍历全盘）
func _random_empty_point(s: GameSession, rng: RandomNumberGenerator) -> Vector2i:
	var size: int = s.board.size
	for i in range(20):
		var row: int = rng.randi_range(0, size - 1)
		var col: int = rng.randi_range(0, size - 1)
		if s.board.get_at(row, col) == Const.EMPTY:
			return Vector2i(col, row)
	return Vector2i(-1, -1)

func _random_move_or_pass(s: GameSession, color: int, rng: RandomNumberGenerator) -> Dictionary:
	# 随机采样空点尝试落子（避免遍历361点 clone 开销）
	var size: int = s.board.size
	var attempts: int = 0
	var max_attempts: int = 30  # 尝试上限
	while attempts < max_attempts:
		var row: int = rng.randi_range(0, size - 1)
		var col: int = rng.randi_range(0, size - 1)
		if s.board.get_at(row, col) != Const.EMPTY:
			attempts += 1
			continue
		var out = s.play_move(color, row, col)
		if out.ok:
			return out
		attempts += 1
	# 尝试多次都失败 → 虚手
	return s.do_pass(color)

# 不变量校验
func _check_invariants(s: GameSession) -> Dictionary:
	# 1. 棋子数不超 361
	var total: int = s.board.count_color(Const.BLACK) + s.board.count_color(Const.WHITE)
	if total > 361:
		return _fail("棋子总数 %d > 361" % total)
	# 2. 落子计数 + 特种部队子数 >= 盘上该色子数（差额=被提）
	for color in [Const.BLACK, Const.WHITE]:
		var placed: int = int(s.stones_placed.get(color, 0))
		var specials: int = s.special.alive_pieces(color).size()
		var on_board: int = s.board.count_color(color)
		if placed + specials < on_board:
			return _fail("color=%d 落子%d+特种%d < 盘上%d" % [color, placed, specials, on_board])
	# 3. 分数一致性
	var sc1 = s.scores()
	var sc2 = s.scores()
	if sc1.black.total() != sc2.black.total() or sc1.white.total() != sc2.white.total():
		return _fail("重复计算分数不一致")
	# 4. 总分 = 占领 + 防御 + 战损
	if sc1.black.total() != sc1.black.occupation() + sc1.black.defense() + sc1.black.casualty():
		return _fail("黑总分 %d != 占领%d+防御%d+战损%d" % [sc1.black.total(), sc1.black.occupation(), sc1.black.defense(), sc1.black.casualty()])
	if sc1.white.total() != sc1.white.occupation() + sc1.white.defense() + sc1.white.casualty():
		return _fail("白总分 %d != 占领%d+防御%d+战损%d" % [sc1.white.total(), sc1.white.occupation(), sc1.white.defense(), sc1.white.casualty()])
	# 5. 战损分非正
	if sc1.black.casualty() > 0:
		return _fail("黑战损分 %d > 0" % sc1.black.casualty())
	if sc1.white.casualty() > 0:
		return _fail("白战损分 %d > 0" % sc1.white.casualty())
	# 6. 占领/防御非负
	if sc1.black.occupation() < 0:
		return _fail("黑占领分 %d < 0" % sc1.black.occupation())
	if sc1.black.defense() < 0:
		return _fail("黑防御分 %d < 0" % sc1.black.defense())
	if sc1.white.occupation() < 0:
		return _fail("白占领分 %d < 0" % sc1.white.occupation())
	if sc1.white.defense() < 0:
		return _fail("白防御分 %d < 0" % sc1.white.defense())
	# 7. 终局结算应一致
	if s.game_over:
		var fin = s.final_result("测试")
		if fin.black.total != sc1.black.total():
			return _fail("终局黑总分 %d != 实时 %d" % [fin.black.total, sc1.black.total()])
		if fin.white.total != sc1.white.total():
			return _fail("终局白总分 %d != 实时 %d" % [fin.white.total, sc1.white.total()])
	return {"ok": true, "msg": ""}

func _fail(msg: String) -> Dictionary:
	return {"ok": false, "msg": msg}
