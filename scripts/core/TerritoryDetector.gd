# 围空检测：找出所有「封闭包围圈」（v4.1 纯几何判定）
#
# 定义：一个空连通块，若其所有非空边界棋子均为同一色 C，则被 C 包围（C 的围空）。
#       棋盘边界视为可参与包围（不强制要求四色环绕）。
#       边界含两色 → 中立/争议空地，不计围空分。
#
# 关键防误判：仅 1~2 子时，整盘空块虽边界单色但并非真正「封闭包围圈」。
#   - 不触及棋盘边界的空块：边界单色即视为围空（被棋子完全包围）
#   - 触及棋盘边界的空块：要求边界棋子形成「闭合曲线」
#
# v4.1 规则 6.1：包围圈有效性不依赖围成棋子的死活状态（纯几何判定）。
#   死活判定和围空分扣除在终局时由 ScoreCalculator.compute_final 处理。
#
# 嵌套处理（规则 6.3）：内层区域从外层扣除，避免重复计分。
#   终局时若内层围成棋子被判定为围困，其区域归外层有效包围方（由 compute_final 处理）。
#
# 返回结构：Array[Dictionary]
#   { "color": int, "points": Array[Vector2i], "stones_inside": Array[Vector2i],
#     "border_stones_idx": Dictionary{idx->true} }
#   - points: 围空内的空点（已做嵌套去重）
#   - stones_inside: 圈内对方棋子（不做死活筛选，终局时由ScoreCalculator判定围困）
class_name TerritoryDetector
extends RefCounted

# 棋盘上所有空连通块（不论是否被包围）
# 返回 Array[Dictionary]：
#   { "empty": Array[Vector2i], "border_colors": Dictionary{color->count},
#     "touches_edge": bool, "border_stones": Dictionary{idx->true} }
static func all_empty_regions(board: BoardModel) -> Array:
	var size: int = board.size
	var visited: Dictionary = {}
	var regions: Array = []
	for row in range(size):
		for col in range(size):
			var idx: int = row * size + col
			if visited.has(idx) or board.get_at(row, col) != Const.EMPTY:
				continue
			# BFS 该空连通块
			var comp: Array = []          # 空点索引
			var border_colors: Dictionary = {}  # color -> count
			var border_stones: Dictionary = {}  # idx -> true（去重棋子位置）
			var touches_edge: bool = false
			var stack: Array = [idx]
			while stack.size() > 0:
				var cur: int = stack.pop_back()
				if visited.has(cur):
					continue
				visited[cur] = true
				comp.append(cur)
				var r: int = cur / size
				var c: int = cur % size
				if r == 0 or r == size - 1 or c == 0 or c == size - 1:
					touches_edge = true
				for n in board.neighbors(r, c):
					var ni: int = n[0] * size + n[1]
					var v: int = board.get_at(n[0], n[1])
					if v == Const.EMPTY:
						if not visited.has(ni):
							stack.append(ni)
					else:
						border_colors[v] = border_colors.get(v, 0) + 1
						border_stones[ni] = true
			# 转坐标
			var pts: Array = []
			for cidx in comp:
				pts.append(Vector2i(cidx % size, cidx / size))
			regions.append({
				"empty": pts,
				"border_colors": border_colors,
				"touches_edge": touches_edge,
				"border_stones": border_stones,
			})
	return regions

# 仅返回被单色包围的围空（v4.1纯几何判定）
# 包围圈有效性不依赖围成棋子的死活状态（规则6.1）
# stones_inside: 围空圈内的对方棋子（终局时由ScoreCalculator判定围困）
#
# 嵌套处理（规则6.3）：
#   1. 识别所有几何包围圈
#   2. 内层区域从外层扣除（避免重复计分）
#   3. 死活判定和围空分扣除在终局时由ScoreCalculator处理
static func enclosures(board: BoardModel) -> Array:
	var raw: Array = _collect_raw_enclosures(board)
	if raw.is_empty():
		return []
	# 按色分组，合并同色围空圈的 points（用于 stones_inside 判定）
	# 判定逻辑：组群所有气都在同色合并 points 内 → 计入 stones_inside
	# 这样做活的棋子（气在自己的围空圈/眼内）不会被计入对方围空
	var color_points: Dictionary = {}  # color -> Dictionary{idx->true}
	for enc in raw:
		if not color_points.has(enc.color):
			color_points[enc.color] = {}
		for p in enc.points:
			color_points[enc.color][p.y * board.size + p.x] = true
	# 对每个围空圈扫描圈内对方棋子
	for enc in raw:
		enc.stones_inside = _collect_stones_inside(board, enc, color_points[enc.color])
	# 按区域大小降序（外层大圈先处理）
	raw.sort_custom(func(a, b): return a.points.size() > b.points.size())
	# 标记每个圈覆盖的所有空点（用于外层去重）
	var covered: Dictionary = {}  # idx -> true（已被某圈覆盖）
	# 标记已被某圈计入的 stones_inside 位置（避免同一棋子被多个圈重复计入）
	var covered_stones: Dictionary = {}  # idx -> true
	var result: Array = []
	for enc in raw:
		# 扣除内层圈覆盖的区域（嵌套去重）
		var filtered_points: Array = []
		for p in enc.points:
			var pidx: int = p.y * board.size + p.x
			if covered.has(pidx):
				continue  # 已被内层圈覆盖
			filtered_points.append(p)
		# 标记该圈覆盖的区域
		for p in filtered_points:
			covered[p.y * board.size + p.x] = true
		# stones_inside 去重：同一棋子位置只被一个圈计入
		var filtered_stones: Array = []
		for s in enc.stones_inside:
			var sidx: int = s.y * board.size + s.x
			if covered_stones.has(sidx):
				continue  # 已被其他圈计入
			covered_stones[sidx] = true
			filtered_stones.append(s)
		result.append({
			"color": enc.color,
			"points": filtered_points,
			"stones_inside": filtered_stones,
			"border_stones_idx": enc.border_stones_idx,
		})
	return result

# 收集原始围空圈（未做嵌套去重，未扫描 stones_inside）
# 每个圈包含：color, points（空点）, border_stones_idx（边界棋子索引）
#
# 规则4.1：包围圈 = 由一方棋子形成的完全封闭的几何边界
# 算法（连通分量判定）：
#   - 对每个边界色 C，将所有 C 棋子视为「墙」
#   - 计算非墙点的连通分量，含最多边缘点的分量 = 「外部」
#   - 区域不在「外部」分量内 → 被 C 包围（C 的围空）
#   - 这正确处理对角线缺口（flooding正交移动，对角缺口两侧均为墙色棋子，阻挡flooding）
#   - 也正确处理角落包围（小区域在角落被墙+边缘封闭，大外部区域在「外部」分量中）
static func _collect_raw_enclosures(board: BoardModel) -> Array:
	var out: Array = []
	# 预建每色棋子索引墙
	var walls: Dictionary = {}  # color -> Dictionary{idx->true}
	for c in [Const.BLACK, Const.WHITE]:
		walls[c] = {}
	for r in range(board.size):
		for c in range(board.size):
			var v: int = board.get_at(r, c)
			if v == Const.BLACK or v == Const.WHITE:
				walls[v][r * board.size + c] = true
	# 预建每色「外部」集合（含最多边缘点的非墙连通分量）
	var outsides: Dictionary = {}  # color -> Dictionary{idx->true}
	for c in [Const.BLACK, Const.WHITE]:
		outsides[c] = _compute_outside(board, walls[c])
	for r in all_empty_regions(board):
		var bc: Dictionary = r.border_colors
		if bc.is_empty():
			continue  # 全盘空（开局）
		# 对每个边界色检查是否形成封闭包围圈
		var enclosing_color: int = -1
		for c in bc.keys():
			if _is_region_enclosed_by_wall(board, r, outsides[c]):
				enclosing_color = c
				break  # 至多一色可封闭，找到即停
		if enclosing_color < 0:
			continue
		out.append({
			"color": enclosing_color,
			"points": r.empty,
			"border_stones_idx": r.border_stones,
		})
	return out

# 计算非墙点的「外部」连通分量（含最多边缘点的分量）
# 非墙点 = 空点 + 对方棋子（可穿过），墙色棋子阻挡
# 「外部」= 含最多边缘点的连通分量 → 大区域/开放区域
# 「内部」= 其他分量 → 被墙包围的小区域
static func _compute_outside(board: BoardModel, wall: Dictionary) -> Dictionary:
	var size: int = board.size
	var visited: Dictionary = {}
	var best_outside: Dictionary = {}
	var best_edge_count: int = -1
	for r in range(size):
		for c in range(size):
			var idx: int = r * size + c
			if wall.has(idx) or visited.has(idx):
				continue
			# BFS 此连通分量（可穿过空点+对方棋子，仅被墙阻挡）
			var component: Dictionary = {}
			var stack: Array = [[r, c]]
			var edge_count: int = 0
			while stack.size() > 0:
				var p = stack.pop_back()
				var pi: int = p[0] * size + p[1]
				if component.has(pi):
					continue
				if wall.has(pi):
					continue
				component[pi] = true
				visited[pi] = true
				if p[0] == 0 or p[0] == size - 1 or p[1] == 0 or p[1] == size - 1:
					edge_count += 1
				for n in board.neighbors(p[0], p[1]):
					var ni: int = n[0] * size + n[1]
					if not component.has(ni) and not wall.has(ni):
						stack.append(n)
			# 跟踪含最多边缘点的分量
			if edge_count > best_edge_count:
				best_edge_count = edge_count
				best_outside = component
	return best_outside

# 判断空区域是否被墙包围
# 规则4.1：包围圈 = 完全封闭的几何边界
# 算法：区域不在「外部」连通分量内 → 被墙包围（返回 true）
#       区域在「外部」分量内 → 与外部连通 → 未被包围（返回 false）
static func _is_region_enclosed_by_wall(board: BoardModel, region: Dictionary, outside: Dictionary) -> bool:
	var size: int = board.size
	# 区域的任意空点不在「外部」分量内 → 被墙包围
	for p in region.empty:
		if not outside.has(p.y * size + p.x):
			return true
	return false

# 扫描围空圈内的对方棋子（v4.1：不做死活筛选，返回圈内所有对方棋子）
# 终局时由ScoreCalculator判定围困状态
# 判定：组群的所有气是否都在同色围空圈的合并 points 内
#   - 若组群有气在自己的围空圈（如做活的眼）或外部 → 不计入（组群做活或突破）
#   - 若组群所有气都在同色合并 points 内 → 计入（组群被围空方包围）
# 这样既不会漏算"对方棋子把大圈分割成多个小圈"的场景（气分散在多个同色围空圈），
# 也不会误算"做活两真眼"的棋子（气在自己的围空圈/眼内）。
static func _collect_stones_inside(board: BoardModel, enc: Dictionary, all_color_points: Dictionary) -> Array:
	var opp: int = Const.opponent(enc.color)
	var stones_inside: Array = []
	var seen: Dictionary = {}
	var size: int = board.size
	# 候选对方棋子位置集合
	var candidates: Dictionary = {}  # idx -> true
	# 1. 空区域边界上的对方棋子
	for idx in enc.border_stones_idx:
		var r: int = idx / size
		var c: int = idx % size
		if board.get_at(r, c) == opp:
			candidates[idx] = true
	# 2. 围空方边界棋子的邻居中的对方棋子（直接被包围场景）
	for idx in enc.border_stones_idx:
		var r: int = idx / size
		var c: int = idx % size
		if board.get_at(r, c) == enc.color:
			for n in board.neighbors(r, c):
				var ni: int = n[0] * size + n[1]
				if board.get_at(n[0], n[1]) == opp:
					candidates[ni] = true
	# 对每个候选组群收集成员
	for idx in candidates:
		if seen.has(idx):
			continue
		var r: int = idx / size
		var c: int = idx % size
		var g: Dictionary = board.group_at(r, c)
		if g.stones.is_empty():
			continue
		# 标记整个组群为已见
		for s in g.stones:
			seen[s.y * size + s.x] = true
		# 判定：组群的所有气是否都在同色围空圈的合并 points 内
		# 若组群有气在自己的围空圈（如做活的眼）或外部 → 不计入
		var libs: Array = board.liberties(g.stones)
		var all_inside: bool = true
		for l in libs:
			if not all_color_points.has(l.y * size + l.x):
				all_inside = false
				break
		if not all_inside:
			continue
		# 收集组群所有成员（不做死活筛选，终局时由ScoreCalculator判定）
		for s in g.stones:
			stones_inside.append(Vector2i(s.x, s.y))
	return stones_inside

# 指定色的围空（用于特种部队「参与围空」判定）
static func enclosures_of(board: BoardModel, color: int) -> Array:
	return enclosures(board).filter(func(e): return e.color == color)

# 判断某棋子是否参与指定色的围空（即该棋子是某围空的边界棋子之一）
# 规则：「参与围空」= 该棋子邻接某被该色包围的空块
static func stone_participates_in_enclosure(board: BoardModel, row: int, col: int, color: int) -> bool:
	# 该点必须是该色棋子
	if board.get_at(row, col) != color:
		return false
	for e in enclosures_of(board, color):
		# 检查该棋子是否邻接此围空的任一空点
		for p in e.points:
			for n in board.neighbors(p.y, p.x):
				if n[0] == row and n[1] == col:
					return true
	return false
