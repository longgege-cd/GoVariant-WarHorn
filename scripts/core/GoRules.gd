# 围棋式行棋规则：合法性、提子、自杀判定、基本劫
# 劫规则：基本劫（禁止立即回提造成盘面重复），符合"吃子规则与围棋相同"
# ko_point: 上一手提单子且本手刚落子只有1气时，被提位置为劫点，下一手禁着
class_name GoRules
extends RefCounted

const NO_KO: Vector2i = Vector2i(-1, -1)  # 无劫点

# 落子结果
class MoveResult:
	extends RefCounted
	var legal: bool = false
	var reason: String = ""
	var placed: Vector2i = Vector2i.ZERO   # (col, row)
	var color: int = Const.EMPTY
	var captured: Array = []               # Array[Vector2i] 被提子坐标
	var captured_color: int = Const.EMPTY
	var ko_point: Vector2i = NO_KO         # 本手产生的劫点（下一手禁着点）
	static func make_illegal(why: String) -> MoveResult:
		var r := MoveResult.new()
		r.legal = false
		r.reason = why
		return r

# 检查并执行落子（会修改 board）。color 为落子方
# ko_point: 当前劫点（上一手产生的），落此点非法；默认 NO_KO 无劫
# 返回 MoveResult。若非法，board 不变。
static func try_move(board: BoardModel, row: int, col: int, color: int, ko_point: Vector2i = NO_KO) -> MoveResult:
	if not board.in_bounds(row, col):
		return MoveResult.make_illegal("越界")
	if board.get_at(row, col) != Const.EMPTY:
		return MoveResult.make_illegal("该点已有棋子")
	# 劫争禁着：禁止下在劫点（避免立即回提造成盘面重复）
	if ko_point.x >= 0 and ko_point.y >= 0 and Vector2i(col, row) == ko_point:
		return MoveResult.make_illegal("劫争禁着")

	var opp: int = Const.opponent(color)
	# 先放下
	board.set_at(row, col, color)

	# 检查相邻对方组群是否被提
	var captured: Array = []
	var seen_groups: Dictionary = {}
	for n in board.neighbors(row, col):
		var nr: int = n[0]
		var nc: int = n[1]
		if board.get_at(nr, nc) != opp:
			continue
		var gkey: int = nr * board.size + nc
		if seen_groups.has(gkey):
			continue
		var g: Dictionary = board.group_at(nr, nc)
		for s in g.stones:
			seen_groups[s.y * board.size + s.x] = true
		var libs: Array = board.liberties(g.stones)
		if libs.is_empty():
			for s in g.stones:
				board.set_at(s.y, s.x, Const.EMPTY)
				captured.append(s)

	# 检查自杀：己方组群是否无气（且未提子）
	var own_g: Dictionary = board.group_at(row, col)
	var own_libs: Array = board.liberties(own_g.stones)
	if own_libs.is_empty():
		# 自杀（无气且没提子）
		board.set_at(row, col, Const.EMPTY)
		# 理论上若 captured 非空，own_libs 不会为空；防御性还原
		if not captured.is_empty():
			for s in captured:
				board.set_at(s.y, s.x, opp)
		return MoveResult.make_illegal("自杀禁着")

	var res := MoveResult.new()
	res.legal = true
	res.placed = Vector2i(col, row)
	res.color = color
	res.captured = captured
	res.captured_color = opp
	# 基本劫判定：本手提单子，且本手落的子只有1气 → 被提位置为劫点
	if captured.size() == 1 and own_libs.size() == 1:
		res.ko_point = captured[0]
	return res

# 仅判定是否合法（不修改 board）
static func is_legal(board: BoardModel, row: int, col: int, color: int, ko_point: Vector2i = NO_KO) -> bool:
	var test := board.clone()
	return try_move(test, row, col, color, ko_point).legal

# 是否存在任意合法落子（用于判断「无法落子」）
static func has_any_legal_move(board: BoardModel, color: int, ko_point: Vector2i = NO_KO) -> bool:
	for row in range(board.size):
		for col in range(board.size):
			if board.get_at(row, col) != Const.EMPTY:
				continue
			if is_legal(board, row, col, color, ko_point):
				return true
	return false

