# 围困判定（v5.3规则）
#
# 围困 = 被包围 + 无两眼 + 圈内可合法落子的空点 < 4
# 活棋 = 非围困（规则6.2：非围困即活棋，非活棋即围困）
# 不存在双活：双方互相包围时各自独立判定
# 围困分动态结算（v4.3：盘中实时计分）
class_name SiegeDetector
extends RefCounted

# 判定组群是否已做出两个真眼（活棋）
# group: {"stones": Array[Vector2i(x=col,y=row)], "color": int}
# 严格判定：只有实际做出两个真眼才算活棋（不接受"大眼空间"等近似）
static func has_two_true_eyes(board: BoardModel, group: Dictionary) -> bool:
	var stones: Array = group.stones
	var color: int = group.color
	if stones.is_empty():
		return false
	var size: int = board.size

	# 组群棋子索引集合
	var group_set: Dictionary = {}
	for s in stones:
		group_set[s.y * size + s.x] = true

	# 气域 R：从组群所有气出发，洪水填充空点
	var libs: Array = board.liberties(stones)
	var region: Dictionary = {}  # idx -> true
	var stack: Array = []
	for l in libs:
		stack.append([l.y, l.x])
	while stack.size() > 0:
		var p = stack.pop_back()
		var idx: int = p[0] * size + p[1]
		if region.has(idx):
			continue
		if board.get_at(p[0], p[1]) != Const.EMPTY:
			continue
		region[idx] = true
		for n in board.neighbors(p[0], p[1]):
			var ni: int = n[0] * size + n[1]
			if board.get_at(n[0], n[1]) == Const.EMPTY and not region.has(ni):
				stack.append(n)

	# 真眼数判定（规则7.3：做出两真眼=活棋）
	var true_eyes: int = 0
	for idx in region:
		var r: int = idx / size
		var c: int = idx % size
		if _is_true_eye(board, r, c, group_set, color):
			true_eyes += 1

	return true_eyes >= 2

# 活棋判定（v5.3规则：非围困即活棋）
# 围困三条件（全部满足才围困，任一不满足即活棋）：
#   1. 被包围（处于对方封闭包围圈内，纯几何判定）
#   2. 无两眼
#   3. 圈内可合法落子的空点 < 4
# 按性能优先级短路判定（大多数组群未被包围，第一步即返回）：
#   优先级1：未被包围 → 活棋（最便宜：2次洪水填充，无clone）
#   优先级2：被包围但合法空点≥4 → 活棋（短路：找到4个即返回）
#   优先级3：两眼 → 活棋（最贵：每个气域空点clone棋盘，最后检查）
#   以上都不满足 → 围困
static func is_alive(board: BoardModel, group: Dictionary) -> bool:
	# 优先级1：未被包围（大多数组群在此返回，跳过昂贵的两眼判定）
	if not _is_surrounded_by_opponent(board, group):
		return true
	# 优先级2：被包围但合法空点≥4（短路，快速返回）
	if count_legal_empty_points(board, group, 4) >= 4:
		return true
	# 优先级3：两眼判定（最贵，最后检查）
	if has_two_true_eyes(board, group):
		return true
	return false

# 围困判定（v4.1规则）
# 围困 = 被包围 + 无两眼 + 圈内可合法落子的空点 < 4
# 等价于 not is_alive
static func is_sieged(board: BoardModel, group: Dictionary) -> bool:
	return not is_alive(board, group)

# 统计圈内可合法落子的空点数（规则6.5）
# "圈内" = 被对手方棋子封闭的区域内的所有空点
# 使用flooding从组群出发（穿过空点+己方棋子，仅被对方棋子阻挡）
# 这样圈内被己方棋子分割的空点也能被正确计入
# "可合法落子" = 落子后有气，或虽无气但能立即提吃对方棋子（禁入点不计）
# early_return_at: 短路阈值，找到该数量即立即返回（-1=不短路，精确计数）
static func count_legal_empty_points(board: BoardModel, group: Dictionary, early_return_at: int = -1) -> int:
	var stones: Array = group.stones
	var color: int = group.color
	var opp: int = Const.opponent(color)
	var size: int = board.size

	# 从组群棋子出发flooding（穿过空点+己方棋子，仅被对方棋子阻挡）
	# 收集被对手方封闭的区域内的所有空点
	var region: Dictionary = {}  # idx -> true（区域内的空点）
	var visited: Dictionary = {}  # idx -> true（已访问的点，含棋子）
	var stack: Array = []
	for s in stones:
		stack.append([s.y, s.x])
	while stack.size() > 0:
		var p = stack.pop_back()
		var idx: int = p[0] * size + p[1]
		if visited.has(idx):
			continue
		var v: int = board.get_at(p[0], p[1])
		if v == opp:
			continue  # 对方棋子阻挡
		visited[idx] = true
		if v == Const.EMPTY:
			region[idx] = true
		# 己方棋子和空点都可以穿过
		for n in board.neighbors(p[0], p[1]):
			var ni: int = n[0] * size + n[1]
			if not visited.has(ni) and board.get_at(n[0], n[1]) != opp:
				stack.append(n)

	# 统计可合法落子的空点（短路：达到阈值即返回）
	var count: int = 0
	for idx in region:
		var r: int = idx / size
		var c: int = idx % size
		if _is_legal_move(board, r, c, color):
			count += 1
			if early_return_at > 0 and count >= early_return_at:
				return count
	return count

# 检查落子是否合法（规则6.5判定标准，不涉及劫争）
# 步骤1：落子后己方有气 → 可落子 ✅
# 步骤2：无气 → 能否提吃对方？
#   能提吃 → 模拟提吃后重新检查己方是否有气
#     提吃后有气 → 可落子 ✅
#     提吃后仍无气 → 禁入点 ❌
#   不能提吃 → 禁入点 ❌
# 关键原则：对方的眼位是禁入点，自己的眼位是可落子空点
# 性能优化：不 clone 全棋盘，仅局部模拟（四邻组群气数 + 候选空点判定）
static func _is_legal_move(board: BoardModel, row: int, col: int, color: int) -> bool:
	var sim: Dictionary = _simulate_place(board, row, col, color)
	return sim.own_alive

# 局部模拟在 (row,col) 落 color 子（前提：该点为空），不修改棋盘
# 返回 { "captures": Array[Vector2i], "own_alive": bool }
# captures: 被提吃的对方组群棋子；own_alive: 落子后己方连通块是否有气
static func _simulate_place(board: BoardModel, row: int, col: int, color: int) -> Dictionary:
	var opp: int = Const.opponent(color)
	var size: int = board.size
	# 快速路径：落子点有空邻居 → 落子后有气（无需模拟提吃）
	for n in board.neighbors(row, col):
		if board.get_at(n[0], n[1]) == Const.EMPTY:
			return { "captures": [], "own_alive": true }
	var own_seen: Dictionary = {}   # idx -> true（邻接己方组群成员）
	var opp_seen: Dictionary = {}   # idx -> true（邻接对方组群成员）
	var captured: Array = []
	for n in board.neighbors(row, col):
		var nv: int = board.get_at(n[0], n[1])
		var nidx: int = n[0] * size + n[1]
		if nv == opp:
			if opp_seen.has(nidx):
				continue
			var g: Dictionary = board.group_at(n[0], n[1])
			for s in g.stones:
				opp_seen[s.y * size + s.x] = true
			# 落子点原为空点且邻接该组群 → 必是其气之一；落子后该气消失
			# 排除落子点后无气 → 被提
			if _group_liberty_count_excluding(board, g, row, col) == 0:
				for s in g.stones:
					captured.append(Vector2i(s.x, s.y))
		elif nv == color:
			if own_seen.has(nidx):
				continue
			var g: Dictionary = board.group_at(n[0], n[1])
			for s in g.stones:
				own_seen[s.y * size + s.x] = true
	if not captured.is_empty() or not own_seen.is_empty():
		# 有提吃或连接己方 → 重新判定己方连通块是否有气
		return { "captures": captured, "own_alive": _connected_has_liberty(board, row, col, color, own_seen, captured) }
	return { "captures": [], "own_alive": false }

# 提吃/连接后的己方连通块（落子点 + 邻接己方组群 + 被提组群）是否有气
# 候选气点 = 连通块成员的四邻；落子后棋盘上为空 ⇔ 原为空点(≠落子点) 或 被提位置
static func _connected_has_liberty(board: BoardModel, row: int, col: int, color: int, own_seen: Dictionary, captured: Array) -> bool:
	var size: int = board.size
	var place_idx: int = row * size + col
	var captured_set: Dictionary = {}
	for cap in captured:
		captured_set[cap.y * size + cap.x] = true
	var candidates: Dictionary = {}  # idx -> 原值
	for n in board.neighbors(row, col):
		var ni: int = n[0] * size + n[1]
		if not candidates.has(ni):
			candidates[ni] = board.get_at(n[0], n[1])
	for idx in own_seen:
		var r: int = idx / size
		var c: int = idx % size
		for n in board.neighbors(r, c):
			var ni: int = n[0] * size + n[1]
			if not candidates.has(ni):
				candidates[ni] = board.get_at(n[0], n[1])
	for cap in captured:
		for n in board.neighbors(cap.y, cap.x):
			var ni: int = n[0] * size + n[1]
			if not candidates.has(ni):
				candidates[ni] = board.get_at(n[0], n[1])
	for idx in candidates:
		if idx == place_idx:
			continue  # 落子点被己方子占据，不算气
		var v: int = candidates[idx]
		if v == Const.EMPTY or captured_set.has(idx):
			return true
	return false

# 组群气数（排除落子点；该点原为空点，落子后不再计气）
static func _group_liberty_count_excluding(board: BoardModel, g: Dictionary, row: int, col: int) -> int:
	var size: int = board.size
	var excl_idx: int = row * size + col
	var seen: Dictionary = {}
	var count: int = 0
	for s in g.stones:
		for n in board.neighbors(s.y, s.x):
			var ni: int = n[0] * size + n[1]
			if ni == excl_idx:
				continue
			if board.get_at(n[0], n[1]) == Const.EMPTY and not seen.has(ni):
				seen[ni] = true
				count += 1
	return count

# 检查组群是否被对方包围（v5.3纯几何判定）
# 规则6.3条件1："被包围：处于对方的封闭包围圈内（纯几何判定）"
# 算法：组群气域 R 出发 flooding（穿过空点+己方棋子，仅被对方棋子阻挡）
#   若 R 到达棋盘边缘空点 → 与外部连通 → 不被包围
#   若 R 无法到达边缘空点 → 被对方棋子完全封闭 → 被包围
# 这正确处理：
#   - 大气域（覆盖大部分棋盘）→ R 触及边缘 → 不被包围
#   - 包围圈内组群 → R 被对方棋子封闭 → 被包围
#   - 角落组群被对方包围 → R 无路径到边缘空点 → 被包围
#   - 通过己方棋子链连接到外部 → flooding 穿过己方棋子可达 → 不被包围
# 性能优化：从组群气域反向 flooding 比从棋盘边缘正向 flooding 局部性好
#   （未被包围组群气域大，很快触及边缘提前返回；被包围组群只遍历封闭小区域）
static func _is_surrounded_by_opponent(board: BoardModel, group: Dictionary) -> bool:
	var stones: Array = group.stones
	var color: int = group.color
	var opp: int = Const.opponent(color)
	var size: int = board.size

	# 气域/连通域：从组群棋子出发，穿过空点+己方棋子，被对方棋子阻挡
	# 起点 = 组群棋子的非对方邻居（空点或己方棋子）
	var region: Dictionary = {}  # idx -> true（己方棋子+空点，与对方隔绝的区域）
	var stack: Array = []
	for s in stones:
		for n in board.neighbors(s.y, s.x):
			var v: int = board.get_at(n[0], n[1])
			if v == opp:
				continue
			var idx: int = n[0] * size + n[1]
			if not region.has(idx):
				region[idx] = true
				stack.append([n[0], n[1], v])
	while stack.size() > 0:
		var p = stack.pop_back()
		if p[2] == Const.EMPTY:
			# 空点到达棋盘边缘 → 与外部连通 → 不被包围
			if p[0] == 0 or p[0] == size - 1 or p[1] == 0 or p[1] == size - 1:
				return false
		# 穿过空点和己方棋子继续扩散（仅被对方棋子阻挡）
		for n in board.neighbors(p[0], p[1]):
			var v: int = board.get_at(n[0], n[1])
			if v == opp:
				continue
			var ni: int = n[0] * size + n[1]
			if not region.has(ni):
				region[ni] = true
				stack.append([n[0], n[1], v])
	# 气域与外部不连通 → 被对方棋子完全封闭
	return true

# 真眼判定（规则6.4：模拟提吃）
# 独立真眼 = 空点 + 四周被同块棋子(或棋盘边界)包围 + 对方不能落子(禁入点) + 该组不能通过填眼提吃对方
# 判定方式与传统围棋一致：对方在该眼位落子后若无法存活(无气且不能提吃) → 禁入点 → 真眼
static func _is_true_eye(board: BoardModel, row: int, col: int, group_set: Dictionary, color: int) -> bool:
	if board.get_at(row, col) != Const.EMPTY:
		return false
	var opp: int = Const.opponent(color)
	var size: int = board.size
	# 条件1：正交邻居全为该组棋子（棋盘边界视为包围）
	for n in board.neighbors(row, col):
		if not group_set.has(n[0] * size + n[1]):
			return false
	# 条件2：对方不能在该点落子（禁入点，规则6.4模拟提吃判定）
	# 对方若可合法落子 → 非真眼（对方可填入破坏眼位）
	if _is_legal_move(board, row, col, opp):
		return false
	# 条件3：该组不能通过放弃该眼提吃对方棋子（倒扑判定）
	# 若填眼可提吃对方 → 该点既是眼也是提子点 → 非独立真眼
	var sim: Dictionary = _simulate_place(board, row, col, color)
	if not sim.captures.is_empty():
		return false  # 填眼可提吃对方 → 非独立真眼
	return true

# 将气域 R 拆分为「仅被该组包围」的眼空间
# 返回 Array[Array[Vector2i]]
static func _split_eye_spaces(board: BoardModel, region: Dictionary, group_set: Dictionary, color: int) -> Array:
	var size: int = board.size
	var visited: Dictionary = {}
	var spaces: Array = []
	for idx in region:
		if visited.has(idx):
			continue
		# BFS 该空连通块
		var comp: Array = []
		var stack: Array = [idx]
		var bordered_by_other: bool = false
		while stack.size() > 0:
			var cur: int = stack.pop_back()
			if visited.has(cur):
				continue
			visited[cur] = true
			comp.append(cur)
			var r: int = cur / size
			var c: int = cur % size
			for n in board.neighbors(r, c):
				var ni: int = n[0] * size + n[1]
				var v: int = board.get_at(n[0], n[1])
				if v == Const.EMPTY:
					if region.has(ni) and not visited.has(ni):
						stack.append(ni)
				elif v == color:
					if not group_set.has(ni):
						bordered_by_other = true  # 其它己方组群接触
				else:
					bordered_by_other = true  # 对方接触
		if not bordered_by_other:
			# 仅被本组包围 → 眼空间
			var pts: Array = []
			for cidx in comp:
				pts.append(Vector2i(cidx % size, cidx / size))
			spaces.append(pts)
	return spaces
