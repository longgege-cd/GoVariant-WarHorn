# 围困判定（v5.3规则）
#
# 围困 = 被有效包围 + 无两眼 + 圈内可合法落子的空点 < 4
# 活棋 = 非围困（规则6.2：非围困即活棋，非活棋即围困）
# 有效包围圈 = 由对方**活棋**围成的封闭几何边界（规则6.4，v6.2）
#   - 对方围困棋子不能构成有效包围圈（死棋围不成圈，被死棋围住的棋应活）
#   - 死活相互依赖（A 被 B 围、B 被 A 围），全盘判定用迭代不动点 solve_dead_alive()
# 不存在双活：双方互相包围时各自独立判定，均满足围困条件则双方都是围困
class_name SiegeDetector
extends RefCounted

# 全盘死活迭代求解（v6.2 有效包围圈语义）
# 返回 { "alive": Array[Dictionary], "sieged": Array[Dictionary] }
# 算法（不动点迭代）：
#   1. 初始假设全部组群为活棋
#   2. 每轮：以对方**活棋**组群为墙（围困棋子不作墙）计算外部集合
#      再判定每个组群是否围困（被有效包围 + 无两眼 + 合法空点<4）
#   3. 直到状态收敛；若出现状态循环（双活等互相包围僵局），
#      取历史中围困组群最多的状态（规则：均满足围困条件则双方都是围困）
static func solve_dead_alive(board: BoardModel) -> Dictionary:
	var groups: Array = board.all_groups()
	var res := { "alive": [], "sieged": [] }
	if groups.is_empty():
		return res
	var size: int = board.size
	# 初始全部活棋：sieged_set 空
	var sieged_set: Dictionary = {}  # 组群首子 idx -> true
	var state_log: Array = []        # 每轮 sieged_set 的深拷贝（循环检测用）
	var max_iter: int = groups.size() + 4
	for it in range(max_iter):
		# 构建每色「活棋墙」索引集合（围困组群不作墙）
		# opp_wall[color] = color 颜色的活棋棋子集合（作为对方判定时的墙）
		var opp_wall: Dictionary = { Const.BLACK: {}, Const.WHITE: {} }
		for g in groups:
			if sieged_set.has(g.stones[0].y * size + g.stones[0].x):
				continue
			for s in g.stones:
				opp_wall[g.color][s.y * size + s.x] = true
		# 每色外部集合（以该色活棋为墙；判定 g 时用对方颜色的墙）
		var outs: Dictionary = {
			Const.BLACK: compute_outside_by_wall(board, opp_wall[Const.BLACK]),
			Const.WHITE: compute_outside_by_wall(board, opp_wall[Const.WHITE]),
		}
		# 判定每个组群死活
		var new_sieged: Dictionary = {}
		for g in groups:
			var gkey: int = g.stones[0].y * size + g.stones[0].x
			var opp: int = Const.opponent(g.color)
			var surrounded: bool = _is_surrounded_by_wall(board, g, opp_wall[opp], outs[opp])
			if surrounded and not has_two_true_eyes(board, g) and count_legal_empty_points(board, g) < 4:
				new_sieged[gkey] = true
		# 收敛检查
		if _same_sieged(sieged_set, new_sieged):
			sieged_set = new_sieged
			break
		# 循环检测（双活僵局）：取已见状态中围困最多者
		var cycled := false
		for prev in state_log:
			if _same_sieged(prev, new_sieged):
				sieged_set = _max_sieged(state_log)
				cycled = true
				break
		if cycled:
			break
		state_log.append(new_sieged.duplicate())
		sieged_set = new_sieged
	# 组装结果
	var sieged_keys: Dictionary = sieged_set
	for g in groups:
		if sieged_keys.has(g.stones[0].y * size + g.stones[0].x):
			res.sieged.append(g)
		else:
			res.alive.append(g)
	return res

# 两个围困集合是否相同
static func _same_sieged(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	for k in a:
		if not b.has(k):
			return false
	return true

# 从状态历史中取围困组群最多的状态（循环僵局保守判死）
static func _max_sieged(states: Array) -> Dictionary:
	var best: Dictionary = {}
	for s in states:
		if s.size() > best.size():
			best = s
	return best

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
static func is_alive(board: BoardModel, group: Dictionary, outside: Dictionary = {}) -> bool:
	# 优先级1：未被包围（大多数组群在此返回，跳过昂贵的两眼判定）
	if not _is_surrounded_by_opponent(board, group, outside):
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
# outside: 对方墙的外部集合（缓存模式由调用方传入复用，避免每个组群重复全盘计算）
static func is_sieged(board: BoardModel, group: Dictionary, outside: Dictionary = {}) -> bool:
	return not is_alive(board, group, outside)

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

# 检查组群是否被对方包围（v6.2：被「有效包围圈」包围）
# 规则6.4："有效包围圈 = 由活棋围成的封闭几何边界"（v6.2）
#   - 墙 = 对方**活棋**棋子（由调用方传入 wall_set），对方围困棋子不作墙（flooding 可穿过）
#   - 组群气域反向 flooding：穿过空点+己方棋子+对方围困棋子，仅被对方活棋阻挡
# 外部定义（与 TerritoryDetector 一致）：以墙为界，含最多边缘点的非墙连通分量。
# 算法：
#   1. 计算墙的外部集合 O（含最多边缘点的非墙连通分量）
#   2. 组群气域 R 反向 flooding（穿过空点+己方棋子+对方围困棋子，仅被墙阻挡）
#   3. R 触及 O 中空点 → 与外部连通 → 不被包围（早退）
#   4. R 无法触及 O → 被对方棋子完全封闭 → 被包围
# wall_set: 对方活棋棋子索引集合（idx -> true）
static func _is_surrounded_by_wall(board: BoardModel, group: Dictionary, wall_set: Dictionary, outside: Dictionary = {}) -> bool:
	var stones: Array = group.stones
	var size: int = board.size

	# 墙的外部集合（含最多边缘点的非墙连通分量）
	var outside_set: Dictionary = outside
	if outside_set.is_empty():
		outside_set = compute_outside_by_wall(board, wall_set)

	# 反向 flooding：组群气域（穿过空点+己方棋子+对方围困棋子，仅被墙阻挡）
	var region: Dictionary = {}  # idx -> true（与墙隔绝的区域）
	var stack: Array = []
	for s in stones:
		for n in board.neighbors(s.y, s.x):
			var idx: int = n[0] * size + n[1]
			if wall_set.has(idx):
				continue  # 对方活棋（墙）阻挡
			if not region.has(idx):
				region[idx] = true
				stack.append([n[0], n[1]])
	while stack.size() > 0:
		var p = stack.pop_back()
		var pi: int = p[0] * size + p[1]
		if board.get_at(p[0], p[1]) == Const.EMPTY and outside_set.has(pi):
			# 气域触及外部开放空点 → 与外部连通 → 不被包围（早退）
			return false
		for n in board.neighbors(p[0], p[1]):
			var ni: int = n[0] * size + n[1]
			if wall_set.has(ni):
				continue  # 墙阻挡
			if not region.has(ni):
				region[ni] = true
				stack.append([n[0], n[1]])
	# 气域与外部不连通 → 被对方棋子完全封闭
	return true

# 纯几何包围判定（v5.3 兼容：以对方**全部**棋子为墙）
# 供 is_alive/is_sieged 单组群快速判定及测试使用；新规则（v6.2）全盘判定请用 solve_dead_alive()
static func _is_surrounded_by_opponent(board: BoardModel, group: Dictionary, outside: Dictionary = {}) -> bool:
	var opp: int = Const.opponent(group.color)
	var wall_set: Dictionary = {}
	for r in range(board.size):
		for c in range(board.size):
			if board.get_at(r, c) == opp:
				wall_set[r * board.size + c] = true
	return _is_surrounded_by_wall(board, group, wall_set, outside)

# 计算以 wall_color 棋子为墙时的「外部」连通分量
# 「外部」= 含最多边缘点的非墙连通分量（空点+非墙色棋子可穿过）
# 规则4.1：棋盘边缘是天然围墙，角部被封闭的小区域（如(0,0)）只含1~2个边缘点，
# 而开放大气含大量边缘点 → 通过「含最多边缘点」区分内部与外部
static func compute_outside(board: BoardModel, wall_color: int) -> Dictionary:
	var wall_set: Dictionary = {}
	for r in range(board.size):
		for c in range(board.size):
			if board.get_at(r, c) == wall_color:
				wall_set[r * board.size + c] = true
	return compute_outside_by_wall(board, wall_set)

# 计算以 wall_set（棋子索引集合）为墙时的「外部」连通分量（v6.2）
# 「外部」= 含最多边缘点的非墙连通分量（空点+非墙棋子可穿过）
# wall_set: 对方活棋棋子索引集合（idx -> true）
static func compute_outside_by_wall(board: BoardModel, wall_set: Dictionary) -> Dictionary:
	var size: int = board.size
	var visited: Dictionary = {}
	var best: Dictionary = {}
	var best_edge: int = -1
	for r in range(size):
		for c in range(size):
			var idx: int = r * size + c
			if visited.has(idx):
				continue
			if wall_set.has(idx):
				continue
			var comp: Dictionary = {}
			var stack: Array = [idx]
			var edge: int = 0
			while stack.size() > 0:
				var cur: int = stack.pop_back()
				if comp.has(cur) or visited.has(cur):
					continue
				visited[cur] = true
				comp[cur] = true
				var cr: int = cur / size
				var cc: int = cur % size
				if cr == 0 or cr == size - 1 or cc == 0 or cc == size - 1:
					edge += 1
				# 内联 4 方向邻居（避免 neighbors() 每次建数组）
				if cr > 0:
					var ni0: int = cur - size
					if not visited.has(ni0) and not wall_set.has(ni0):
						stack.append(ni0)
				if cr < size - 1:
					var ni1: int = cur + size
					if not visited.has(ni1) and not wall_set.has(ni1):
						stack.append(ni1)
				if cc > 0:
					var ni2: int = cur - 1
					if not visited.has(ni2) and not wall_set.has(ni2):
						stack.append(ni2)
				if cc < size - 1:
					var ni3: int = cur + 1
					if not visited.has(ni3) and not wall_set.has(ni3):
						stack.append(ni3)
			if edge > best_edge:
				best_edge = edge
				best = comp
	return best

# 真眼判定（规则6.4：模拟提吃）
# 独立真眼 = 空点 + 四周被己方棋子(或棋盘边界)包围 + 对方不能落子(禁入点) + 己方不能通过填眼提吃对方
# 判定方式与传统围棋一致：对方在该眼位落子后若无法存活(无气且不能提吃) → 禁入点 → 真眼
# 注意：眼位四邻允许分属多个同色组群（共享禁入点，如相邻两块棋共用的眼位）。
#   两块同色组群共享的禁入点，白棋同样无法下入，围住它的黑棋因此杀不死 → 应判活棋。
#   （条件2的禁入点判定已包含"对方能否提吃任一邻接组群"，保证该点确实无法被白棋占据）
static func _is_true_eye(board: BoardModel, row: int, col: int, group_set: Dictionary, color: int) -> bool:
	if board.get_at(row, col) != Const.EMPTY:
		return false
	var opp: int = Const.opponent(color)
	var size: int = board.size
	# 条件1：正交邻居全为己方棋子（可为多个同色组群，棋盘边界视为包围）
	for n in board.neighbors(row, col):
		if board.get_at(n[0], n[1]) != color:
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
