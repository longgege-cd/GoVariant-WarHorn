# 棋盘数据模型：纯数据，无 Node 依赖，可独立测试与克隆（供 AI 搜索使用）
# 仅负责状态存储与基本查询（取色、置子、组群与气），不涉及规则判定
class_name BoardModel
extends RefCounted

var size: int = Const.BOARD_SIZE
# 一维数组，索引 = row * size + col，值 = Const.EMPTY/BLACK/WHITE
var grid: PackedByteArray = PackedByteArray()

func _init(s: int = Const.BOARD_SIZE) -> void:
	size = s
	grid.resize(size * size)
	grid.fill(Const.EMPTY)

func index_of(row: int, col: int) -> int:
	return row * size + col

func in_bounds(row: int, col: int) -> bool:
	return row >= 0 and row < size and col >= 0 and col < size

func get_at(row: int, col: int) -> int:
	return grid[index_of(row, col)]

func set_at(row: int, col: int, color: int) -> void:
	grid[index_of(row, col)] = color

func is_empty(row: int, col: int) -> bool:
	return get_at(row, col) == Const.EMPTY

# 深拷贝
func clone() -> BoardModel:
	var b := BoardModel.new(size)
	b.grid = grid.duplicate()
	return b

# 四邻（边界自动忽略）
func neighbors(row: int, col: int) -> Array:
	var out: Array = []
	if row > 0: out.append([row - 1, col])
	if row < size - 1: out.append([row + 1, col])
	if col > 0: out.append([row, col - 1])
	if col < size - 1: out.append([row, col + 1])
	return out

# 对角四邻
func diagonals(row: int, col: int) -> Array:
	var out: Array = []
	for dr in [-1, 1]:
		for dc in [-1, 1]:
			var r: int = row + dr
			var c: int = col + dc
			if in_bounds(r, c):
				out.append([r, c])
	return out

# 取包含 (row,col) 的同色连通组群（不含空点；若该点为空返回空数组）
# 返回 Dictionary: { "stones": Array[Vector2i], "color": int }
func group_at(row: int, col: int) -> Dictionary:
	var color: int = get_at(row, col)
	if color == Const.EMPTY:
		return { "stones": [], "color": Const.EMPTY }
	var stones: Array = []
	var seen: Dictionary = {}
	var stack: Array = [[row, col]]
	while stack.size() > 0:
		var p = stack.pop_back()
		var key: int = p[0] * size + p[1]
		if seen.has(key):
			continue
		seen[key] = true
		stones.append(Vector2i(p[1], p[0]))  # (x=col, y=row)
		for n in neighbors(p[0], p[1]):
			if get_at(n[0], n[1]) == color and not seen.has(n[0] * size + n[1]):
				stack.append(n)
	return { "stones": stones, "color": color }

# 组群的气（去重的空邻接点）
func liberties(stones: Array) -> Array:
	var libs: Dictionary = {}
	for s in stones:
		var row: int = s.y
		var col: int = s.x
		for n in neighbors(row, col):
			if get_at(n[0], n[1]) == Const.EMPTY:
				libs[n[0] * size + n[1]] = true
	return libs.keys().map(func(k): return Vector2i(k % size, k / size))

# 组群气数
func liberty_count(stones: Array) -> int:
	return liberties(stones).size()

# 全盘某色棋子数
func count_color(color: int) -> int:
	var n: int = 0
	for i in range(size * size):
		if grid[i] == color:
			n += 1
	return n

# 统计全部连通组群
func all_groups() -> Array:
	var seen: Dictionary = {}
	var groups: Array = []
	for row in range(size):
		for col in range(size):
			var key: int = row * size + col
			if seen.has(key):
				continue
			var color: int = get_at(row, col)
			if color == Const.EMPTY:
				continue
			var g := group_at(row, col)
			for s in g.stones:
				seen[s.y * size + s.x] = true
			groups.append(g)
	return groups

# 用于日志/调试的字符串
func to_string_compact() -> String:
	var s: String = ""
	for row in range(size):
		for col in range(size):
			var v: int = get_at(row, col)
			s += "." if v == Const.EMPTY else ("B" if v == Const.BLACK else "W")
		s += "\n"
	return s
