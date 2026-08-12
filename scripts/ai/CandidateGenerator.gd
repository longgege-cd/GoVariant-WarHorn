# 候选着法生成器（参考《AI对手算法设计文档》第二章）
#
# 从 361 个可选点中筛选出最有潜力的候选点，大幅缩小搜索空间。
# 候选点按战术分类并评分：
#   CAPTURE(90)   提吃对方棋子
#   RESCUE(85)    救援己方被围棋子
#   TRAP_COMPRESS(80) 压缩对方空间使其围困
#   ENCLOSURE(70) 形成/扩大包围圈
#   BORDER_LINE(65) 边境线要点
#   HARASS(55-)   敌后渗透（越深入越低分）
#   DEFEND(45)    己方领土防守要点
#   SPECIAL_FORCE(60+) 特种部队部署（可选规则）
#
# 两个接口：
#   generate_candidates: 完整战术分类（根节点搜索用，质量高）
#   generate_quick_candidates: 快速候选（alpha-beta 内层/MCTS 用，仅提子+救援+启发价值）
class_name CandidateGenerator
extends RefCounted

enum MoveCategory {
	BORDER_LINE, ENCLOSURE, TRAP_COMPRESS, RESCUE, CAPTURE, EXPAND, HARASS, DEFEND, SPECIAL_FORCE
}

const SEARCH_SLICE: int = 10  # alpha-beta 每层最多搜索的候选数

# ===== 完整战术分类候选 =====
func generate_candidates(session: GameSession, ai_color: int, max_n: int) -> Array:
	var scored_moves: Array = []
	# 1. 紧急战术点（优先级最高）
	scored_moves.append_array(_find_capture_moves(session, ai_color))
	scored_moves.append_array(_find_rescue_moves(session, ai_color))
	# 2. 围困相关点
	scored_moves.append_array(_find_trap_compression_moves(session, ai_color))
	# 3. 包围圈相关点
	scored_moves.append_array(_find_enclosure_moves(session, ai_color))
	# 4. 边境线要点
	scored_moves.append_array(_find_border_line_moves(session, ai_color))
	# 5. 敌后渗透点
	scored_moves.append_array(_find_infiltration_moves(session, ai_color))
	# 6. 防守要点
	scored_moves.append_array(_find_defensive_moves(session, ai_color))
	# 按评分降序去重截断
	var seen := {}
	var candidates: Array = []
	scored_moves.sort_custom(func(a, b): return a.score > b.score)
	for item in scored_moves:
		var key: String = "%d,%d" % [item.row, item.col]
		if seen.has(key):
			continue
		seen[key] = true
		candidates.append(item)
		if candidates.size() >= max_n:
			break
	# 7. 特种部队部署候选（可选规则开启时，优先级最高，计入总数上限）
	if session.special.enabled and session.special.can_deploy(ai_color, session.ply):
		var special_moves := _find_special_force_moves(session, ai_color)
		for m in special_moves:
			var key: String = "%d,%d" % [m.row, m.col]
			if seen.has(key):
				continue
			seen[key] = true
			candidates.push_front(m)
		if candidates.size() > max_n:
			candidates = candidates.slice(0, max_n)
	return candidates

# ===== 快速候选（搜索内层用） =====
# 只做提子/救援紧急点 + 启发式价值排序，避免每层重复全盘战术检测
func generate_quick_candidates(session: GameSession, color: int, max_n: int) -> Array:
	var moves: Array = []
	var b: BoardModel = _ai_view_board(session)
	# 紧急战术点优先（提子/救援）
	moves.append_array(_find_capture_moves(session, color))
	moves.append_array(_find_rescue_moves(session, color))
	var seen := {}
	for m in moves:
		seen["%d,%d" % [m.row, m.col]] = true
	# 启发式价值扫描
	var fallback: Array = []
	for r in range(b.size):
		for c in range(b.size):
			if b.get_at(r, c) != Const.EMPTY:
				continue
			if not GoRules.is_legal(b, r, c, color, session.ko_point):
				continue
			var val: float = _quick_value(session, b, r, c, color)
			fallback.append({"row": r, "col": c, "score": val, "category": MoveCategory.EXPAND, "reason": ""})
	fallback.sort_custom(func(a, b): return a.score > b.score)
	for m in fallback:
		var key: String = "%d,%d" % [m.row, m.col]
		if seen.has(key):
			continue
		seen[key] = true
		moves.append(m)
		if moves.size() >= max_n:
			break
	return moves

# ========== 各类候选点查找 ==========

# 提吃对方棋子的点（对方组群仅 1 气 → 提点）
func _find_capture_moves(session: GameSession, ai_color: int) -> Array:
	var moves: Array = []
	var opp: int = Const.opponent(ai_color)
	var b: BoardModel = _ai_view_board(session)
	for g in b.all_groups():
		if g.color != opp:
			continue
		var libs: Array = b.liberties(g.stones)
		if libs.size() != 1:
			continue
		var lib: Vector2i = libs[0]
		if not GoRules.is_legal(b, lib.y, lib.x, ai_color, session.ko_point):
			continue
		moves.append({
			"row": lib.y, "col": lib.x,
			"score": 90.0, "category": MoveCategory.CAPTURE,
			"reason": "提吃对方%d子" % g.stones.size(),
		})
	return moves

# 救援己方被围困棋子（己方组群仅 1 气 → 扩展气点）
func _find_rescue_moves(session: GameSession, ai_color: int) -> Array:
	var moves: Array = []
	var b: BoardModel = _ai_view_board(session)
	for g in b.all_groups():
		if g.color != ai_color:
			continue
		var libs: Array = b.liberties(g.stones)
		if libs.size() != 1:
			continue
		var lib: Vector2i = libs[0]
		if not GoRules.is_legal(b, lib.y, lib.x, ai_color, session.ko_point):
			continue
		# 验证落子后己方组群气数增加（真救援而非自杀）
		var test := b.clone()
		var res = GoRules.try_move(test, lib.y, lib.x, ai_color, session.ko_point)
		if not res.legal:
			continue
		var after_g: Dictionary = test.group_at(lib.y, lib.x)
		if test.liberties(after_g.stones).size() > 1:
			moves.append({
				"row": lib.y, "col": lib.x,
				"score": 85.0, "category": MoveCategory.RESCUE,
				"reason": "救援被围棋子",
			})
	return moves

# 压缩对方空间使其围困（对方被包围组群，合法空点 4-5）
func _find_trap_compression_moves(session: GameSession, ai_color: int) -> Array:
	var moves: Array = []
	var opp: int = Const.opponent(ai_color)
	var board: BoardModel = session.board
	for g in board.all_groups():
		if g.color != opp:
			continue
		if not SiegeDetector.is_sieged(board, g):
			continue
		var legal_empty: int = SiegeDetector.count_legal_empty_points(board, g, 6)
		if legal_empty < 4 or legal_empty > 5:
			continue
		# 圈内空点作为压缩候选
		var region: Array = _enclosed_region_points(board, g)
		for p in region:
			if not GoRules.is_legal(board, p.y, p.x, ai_color, session.ko_point):
				continue
			moves.append({
				"row": p.y, "col": p.x,
				"score": 80.0, "category": MoveCategory.TRAP_COMPRESS,
				"reason": "压缩对方空间(%d空点)" % legal_empty,
			})
	return moves

# 形成/扩大包围圈（己方围空圈边界棋子的邻接空点，位于敌境/边境）
func _find_enclosure_moves(session: GameSession, ai_color: int) -> Array:
	var moves: Array = []
	var b: BoardModel = _ai_view_board(session)
	for enc in TerritoryDetector.enclosures(b):
		if enc.color != ai_color:
			continue
		for idx in enc.border_stones_idx:
			var r: int = idx / b.size
			var c: int = idx % b.size
			# 边界棋子四邻空点（扩大包围圈）
			var neighbors: Array = b.neighbors(r, c)
			for n in neighbors:
				if b.get_at(n[0], n[1]) != Const.EMPTY:
					continue
				if not GoRules.is_legal(b, n[0], n[1], ai_color, session.ko_point):
					continue
				var zone: int = Const.zone_of_row(n[0])
				if zone == Const.enemy_zone(ai_color) or zone == Const.Zone.BORDER:
					moves.append({
						"row": n[0], "col": n[1],
						"score": 70.0, "category": MoveCategory.ENCLOSURE,
						"reason": "扩大包围圈",
					})
	return moves

# 边境线要点（BORDER_ROW 空点）
func _find_border_line_moves(session: GameSession, ai_color: int) -> Array:
	var moves: Array = []
	var b: BoardModel = _ai_view_board(session)
	var br: int = Const.BORDER_ROW
	for c in range(b.size):
		if b.get_at(br, c) != Const.EMPTY:
			continue
		if not GoRules.is_legal(b, br, c, ai_color, session.ko_point):
			continue
		moves.append({
			"row": br, "col": c,
			"score": 65.0, "category": MoveCategory.BORDER_LINE,
			"reason": "边境线要点",
		})
	return moves

# 敌后渗透（对方领土空点，越深入越低分）
func _find_infiltration_moves(session: GameSession, ai_color: int) -> Array:
	var moves: Array = []
	var b: BoardModel = _ai_view_board(session)
	var opp_zone: int = Const.enemy_zone(ai_color)
	for r in range(b.size):
		for c in range(b.size):
			if b.get_at(r, c) != Const.EMPTY:
				continue
			if Const.zone_of_row(r) != opp_zone:
				continue
			if not GoRules.is_legal(b, r, c, ai_color, session.ko_point):
				continue
			var depth: int = abs(r - Const.BORDER_ROW)
			var score: float = 55.0 - depth * 2.0
			moves.append({
				"row": r, "col": c,
				"score": score, "category": MoveCategory.HARASS,
				"reason": "敌后渗透",
			})
	return moves

# 己方领土防守要点（邻接对方棋子）
func _find_defensive_moves(session: GameSession, ai_color: int) -> Array:
	var moves: Array = []
	var b: BoardModel = _ai_view_board(session)
	var my_zone: int = Const.own_zone(ai_color)
	var opp: int = Const.opponent(ai_color)
	for r in range(b.size):
		for c in range(b.size):
			if b.get_at(r, c) != Const.EMPTY:
				continue
			if Const.zone_of_row(r) != my_zone:
				continue
			if not GoRules.is_legal(b, r, c, ai_color, session.ko_point):
				continue
			var neighbors: Array = b.neighbors(r, c)
			for n in neighbors:
				if b.get_at(n[0], n[1]) == opp:
					moves.append({
						"row": r, "col": c,
						"score": 45.0, "category": MoveCategory.DEFEND,
						"reason": "防守要点",
					})
					break
	return moves

# 特种部队部署候选（对方领土，越深入越安全但价值可能越低）
func _find_special_force_moves(session: GameSession, ai_color: int) -> Array:
	var moves: Array = []
	var b: BoardModel = _ai_view_board(session)
	var opp_zone: int = Const.enemy_zone(ai_color)
	for r in range(b.size):
		for c in range(b.size):
			if b.get_at(r, c) != Const.EMPTY:
				continue
			if Const.zone_of_row(r) != opp_zone:
				continue
			if not GoRules.is_legal(b, r, c, ai_color, session.ko_point):
				continue
			var depth: int = abs(r - Const.BORDER_ROW)
			var score: float = 60.0 + depth * 1.5
			moves.append({
				"row": r, "col": c,
				"score": score, "category": MoveCategory.SPECIAL_FORCE,
				"reason": "特种部队部署",
			})
	return moves

# ========== 辅助 ==========

# AI 视角棋盘：对手未现形隐子视为空点（规则：隐子对对手不可见）
func _ai_view_board(session: GameSession) -> BoardModel:
	var b: BoardModel = session.board.clone()
	if not session.special.enabled:
		return b
	var opp: int = Const.opponent(session.to_move)
	for p in session.special.pieces:
		if p.captured or not p.hidden:
			continue
		if p.color != opp:
			continue
		b.set_at(p.pos.y, p.pos.x, Const.EMPTY)
	return b

# 快速落子价值（提子/占领分/避免边角）
func _quick_value(session: GameSession, b: BoardModel, row: int, col: int, color: int) -> float:
	var value: float = 0.0
	var test = GoRules.try_move(b.clone(), row, col, color, session.ko_point)
	if test.legal:
		value += test.captured.size() * 10.0
		for cap in test.captured:
			if Const.is_defense_zone(cap.y, color):
				value += 5.0
	if Const.is_attack_zone(row, color):
		value += 2.0
	if row == 0 or row == b.size - 1 or col == 0 or col == b.size - 1:
		value -= 1.0
	return value

# 被包围组群圈内的空点（从组群出发 flooding 穿过空点+己方，被对方阻挡）
func _enclosed_region_points(board: BoardModel, group: Dictionary) -> Array:
	var size: int = board.size
	var opp: int = Const.opponent(group.color)
	var region: Dictionary = {}
	var stack: Array = []
	for s in group.stones:
		stack.append([s.y, s.x])
	while stack.size() > 0:
		var p = stack.pop_back()
		var idx: int = p[0] * size + p[1]
		if region.has(idx):
			continue
		if board.get_at(p[0], p[1]) == opp:
			continue  # 对方棋子阻挡
		region[idx] = true
		var neighbors: Array = board.neighbors(p[0], p[1])
		for n in neighbors:
			var ni: int = n[0] * size + n[1]
			if not region.has(ni) and board.get_at(n[0], n[1]) != opp:
				stack.append(n)
	var pts: Array = []
	for idx in region:
		var r: int = idx / size
		var c: int = idx % size
		if board.get_at(r, c) == Const.EMPTY:
			pts.append(Vector2i(c, r))
	return pts
