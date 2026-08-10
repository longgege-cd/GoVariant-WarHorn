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
# 按优先级短路判定：
#   优先级1：两眼 → 活棋
#   优先级2：未被包围 → 活棋
#   优先级3：被包围但空点≥4 → 活棋
#   以上都不满足 → 围困
static func is_alive(board: BoardModel, group: Dictionary) -> bool:
	# 优先级1：两眼判定
	if has_two_true_eyes(board, group):
		return true
	# 优先级2：未被包围
	if not _is_surrounded_by_opponent(board, group):
		return true
	# 优先级3：被包围但空点≥4
	var legal_points: int = count_legal_empty_points(board, group)
	return legal_points >= 4

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
static func count_legal_empty_points(board: BoardModel, group: Dictionary) -> int:
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

	# 统计可合法落子的空点
	var count: int = 0
	for idx in region:
		var r: int = idx / size
		var c: int = idx % size
		if _is_legal_move(board, r, c, color):
			count += 1
	return count

# 检查落子是否合法（规则6.5判定标准，不涉及劫争）
# 步骤1：落子后己方有气 → 可落子 ✅
# 步骤2：无气 → 能否提吃对方？
#   能提吃 → 模拟提吃后重新检查己方是否有气
#     提吃后有气 → 可落子 ✅
#     提吃后仍无气 → 禁入点 ❌
#   不能提吃 → 禁入点 ❌
# 关键原则：对方的眼位是禁入点，自己的眼位是可落子空点
static func _is_legal_move(board: BoardModel, row: int, col: int, color: int) -> bool:
	var opp: int = Const.opponent(color)
	# 快速检查：落子点有空邻居 → 落子后有气 → 可落子（无需clone）
	for n in board.neighbors(row, col):
		if board.get_at(n[0], n[1]) == Const.EMPTY:
			return true
	# 无直接空邻居：clone棋盘模拟落子
	var test := board.clone()
	test.set_at(row, col, color)
	# 步骤1：检查落子后己方连通块是否有气（含通过连接己方组群获得气）
	var own_g: Dictionary = test.group_at(row, col)
	var own_libs: Array = test.liberties(own_g.stones)
	if not own_libs.is_empty():
		return true  # 有气 → 可落子
	# 步骤2：无气 → 检查能否提吃相邻对方棋子
	var captured: Array = []
	for n in test.neighbors(row, col):
		if test.get_at(n[0], n[1]) != opp:
			continue
		var g: Dictionary = test.group_at(n[0], n[1])
		var glibs: Array = test.liberties(g.stones)
		if glibs.is_empty():
			for s in g.stones:
				captured.append(s)
	if captured.is_empty():
		return false  # 不能提吃 → 禁入点
	# 模拟提吃后重新检查己方是否有气（规则6.5步骤2）
	for s in captured:
		test.set_at(s.y, s.x, Const.EMPTY)
	var own_g2: Dictionary = test.group_at(row, col)
	var own_libs2: Array = test.liberties(own_g2.stones)
	return not own_libs2.is_empty()

# 检查组群是否被对方包围（v5.3纯几何判定）
# 规则6.3条件1："被包围：处于对方的封闭包围圈内（纯几何判定）"
# 算法：从棋盘边缘出发flooding（穿过空点+己方棋子，仅被对方棋子阻挡）
#   若flooding能到达组群的气域 → 与外部连通 → 不被包围
#   若flooding无法到达气域 → 被对方棋子完全封闭 → 被包围
# 这正确处理：
#   - 大气域（覆盖大部分棋盘）→ flooding从边缘可达 → 不被包围
#   - 包围圈内组群 → flooding被对方棋子阻挡 → 被包围
#   - 角落组群被对方包围 → 边缘无空点或被对方棋子封死 → 被包围
#   - 通过己方棋子链连接到外部 → flooding穿过己方棋子可达 → 不被包围
static func _is_surrounded_by_opponent(board: BoardModel, group: Dictionary) -> bool:
	var stones: Array = group.stones
	var color: int = group.color
	var opp: int = Const.opponent(color)
	var size: int = board.size

	var libs: Array = board.liberties(stones)
	if libs.is_empty():
		return true  # 没有气，被包围

	# 气域 R：从组群所有气出发，洪水填充空连通块
	var region: Dictionary = {}
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

	# 从棋盘边缘的空点出发flooding（穿过空点+己方棋子，仅被对方棋子阻挡）
	# 注意：起始点必须是边缘空点，不是边缘己方棋子
	# 这样角落组群（边缘全是己方棋子）被对方包围时，flooding无法出发→被包围
	var outside: Dictionary = {}
	var flood_stack: Array = []
	for c in range(size):
		for r in [0, size - 1]:
			if board.get_at(r, c) == Const.EMPTY:
				flood_stack.append([r, c])
	for r in range(size):
		for c in [0, size - 1]:
			if board.get_at(r, c) == Const.EMPTY:
				flood_stack.append([r, c])
	while flood_stack.size() > 0:
		var p = flood_stack.pop_back()
		var idx: int = p[0] * size + p[1]
		if outside.has(idx):
			continue
		var v: int = board.get_at(p[0], p[1])
		if v == opp:
			continue  # 对方棋子阻挡
		outside[idx] = true
		# 到达气域 → 与外部连通 → 不被包围
		if region.has(idx):
			return false
		# 穿过空点和己方棋子
		for n in board.neighbors(p[0], p[1]):
			var ni: int = n[0] * size + n[1]
			if not outside.has(ni) and board.get_at(n[0], n[1]) != opp:
				flood_stack.append(n)

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
	var test := board.clone()
	test.set_at(row, col, color)
	for n in test.neighbors(row, col):
		if test.get_at(n[0], n[1]) == opp:
			var g: Dictionary = test.group_at(n[0], n[1])
			if test.liberties(g.stones).is_empty():
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
