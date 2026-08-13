# SGF (Smart Game Format) 棋谱加载器
#
# 用途：解析标准 SGF 棋谱文件，提取主分支落子序列，供棋谱播放器使用
#
# 支持的 SGF 子集：
#   - GM[1] 围棋
#   - SZ[19] 棋盘大小
#   - B[xy]/W[xy] 落子（xy 为小写字母坐标，'a'-'s'）
#   - B[]/W[] 虚手
#   - 注释 C[...]（解析时跳过）
#   - 分支 (...)[...]（标准 SGF 语义：首个子分支 = 主谱延续，其余兄弟分支 = 变着跳过）
#   - AB[xy]/AW[xy] 让子/初始局面
#
# 主分支提取规则（标准 SGF 语义）：
#   - 节点序列内的 B/W → 主谱落子
#   - 节点的"首个子分支" → 主谱延续（覆盖链式嵌套与 CGoban 解说嵌套格式）
#   - 其余兄弟分支（变着）→ 整棵跳过，不污染主谱、不回退已解析走法
class_name SGFLoader
extends RefCounted

# 解析结果
# {
#   "ok": bool, "error": String,
#   "size": int,
#   "black_player": String, "white_player": String, "result": String,
#   "setup_black": Array[Vector2i], "setup_white": Array[Vector2i],
#   "moves": Array[Dictionary]  # [{"color": int, "pos": Vector2i, "pass": bool}, ...]
# }
static func parse(text: String) -> Dictionary:
	var result: Dictionary = {
		"ok": false,
		"error": "",
		"size": 19,
		"black_player": "",
		"white_player": "",
		"result": "",
		"date": "",
		"event": "",
		"setup_black": [],
		"setup_white": [],
		"moves": [],
	}
	text = text.strip_edges()
	if text.begins_with("\uFEFF"):
		text = text.substr(1)
	if text == "":
		result.error = "空文件"
		return result

	var p: int = 0
	var n: int = text.length()
	# 跳到第一个 '('
	while p < n and text[p] != '(':
		p += 1
	if p >= n:
		result.error = "未找到分支起始 '('"
		return result
	p += 1  # 跳过 '('

	# 递归下降解析主分支（标准 SGF 语义），兼容三种格式：
	#   1. 标准线性：(;B[qd];W[dp];B[pq];...)
	#   2. 链式嵌套：(;B[qd](;W[dp](;B[pq]...)))
	#   3. 解说嵌套：主分支每手后带 C[..] 注释与 (...) 变着（如 AlphaGo 官方棋谱）
	_parse_tree(text, p, result)

	result.ok = true
	return result

# 递归解析一棵 GameTree（pos 指向 '(' 之后），返回匹配 ')' 之后的位置。
# 标准 SGF 语义：首个子分支为主谱延续，其余兄弟分支（变着）整棵跳过。
static func _parse_tree(text: String, pos: int, result: Dictionary) -> int:
	var n: int = text.length()
	var recursed: bool = false  # 本层是否已进入过首个子分支
	while pos < n:
		var ch: String = text[pos]
		if ch == ';':
			pos = _parse_node(text, pos, result)
		elif ch == '(':
			if recursed:
				# 变着（第 2+ 个子分支）：整棵跳过
				pos = _skip_subtree(text, pos + 1)
			else:
				# 首个子分支 = 主谱延续
				recursed = true
				pos = _parse_tree(text, pos + 1, result)
		elif ch == ')':
			return pos + 1
		else:
			pos += 1
	return n

# 解析一个节点（pos 指向 ';'），应用属性，返回节点后位置
static func _parse_node(text: String, pos: int, result: Dictionary) -> int:
	var n: int = text.length()
	pos += 1  # 跳过 ';'
	# 跳过空白
	while pos < n and _is_ws(text[pos]):
		pos += 1
	# 解析该节点所有属性
	while pos < n and text[pos] != ';' and text[pos] != '(' and text[pos] != ')':
		# 读属性名
		var key: String = ""
		while pos < n and text[pos] != '[' and text[pos] != ';' and text[pos] != '(' and text[pos] != ')' and not _is_ws(text[pos]):
			key += text[pos]
			pos += 1
		if key == "":
			# 可能是空白或 '[' 单独出现，跳过
			if pos < n and text[pos] == '[':
				pos = _skip_value(text, pos)
			elif pos < n and _is_ws(text[pos]):
				pos += 1
			else:
				break
			continue
		# 读一个或多个 [value]
		var values: Array = []
		while pos < n and text[pos] == '[':
			var v: String = ""
			pos += 1
			while pos < n and text[pos] != ']':
				if text[pos] == '\\' and pos + 1 < n:
					v += text[pos + 1]
					pos += 2
				else:
					v += text[pos]
					pos += 1
			if pos < n:
				pos += 1  # 跳过 ']'
			values.append(v)
		# 处理属性
		_apply_property(result, key.to_upper(), values)
	return pos

# 从 '(' 之后的位置跳过整棵子树（含嵌套），返回其后位置。
# 必须跳过 [..] 内容：注释中可能含括号，不能计入括号深度。
static func _skip_subtree(text: String, pos: int) -> int:
	var depth: int = 1
	var n: int = text.length()
	while pos < n and depth > 0:
		var ch: String = text[pos]
		if ch == '(':
			depth += 1
		elif ch == ')':
			depth -= 1
		elif ch == '[':
			pos = _skip_value(text, pos)
			continue
		pos += 1
	return pos

static func _is_ws(ch: String) -> bool:
	return ch == ' ' or ch == '\n' or ch == '\r' or ch == '\t'

# 跳过单个 [value]，返回 ']' 后的位置
static func _skip_value(text: String, pos: int) -> int:
	var i: int = pos + 1
	var n: int = text.length()
	while i < n and text[i] != ']':
		if text[i] == '\\' and i + 1 < n:
			i += 2
		else:
			i += 1
	if i < n:
		i += 1
	return i

# 应用属性到结果
static func _apply_property(result: Dictionary, key: String, values: Array) -> void:
	match key:
		"SZ":
			if values.size() > 0:
				result.size = int(values[0])
		"PB":
			if values.size() > 0:
				result.black_player = values[0]
		"PW":
			if values.size() > 0:
				result.white_player = values[0]
		"RE":
			if values.size() > 0:
				result.result = values[0]
		"DT":
			if values.size() > 0:
				result.date = values[0]
		"EV":
			if values.size() > 0:
				result.event = values[0]
		"AB":
			for v in values:
				var coord := _sgf_to_coord(v, result.size)
				if coord.x >= 0:
					result.setup_black.append(coord)
		"AW":
			for v in values:
				var coord := _sgf_to_coord(v, result.size)
				if coord.x >= 0:
					result.setup_white.append(coord)
		"B":
			var mv: Dictionary = {"color": Const.BLACK, "pos": Vector2i(-1, -1), "pass": false}
			if values.is_empty() or values[0] == "":
				mv.pass = true
			else:
				var coord := _sgf_to_coord(values[0], result.size)
				if coord.x >= 0:
					mv.pos = coord
				else:
					mv.pass = true
			result.moves.append(mv)
		"W":
			var mv2: Dictionary = {"color": Const.WHITE, "pos": Vector2i(-1, -1), "pass": false}
			if values.is_empty() or values[0] == "":
				mv2.pass = true
			else:
				var coord2 := _sgf_to_coord(values[0], result.size)
				if coord2.x >= 0:
					mv2.pos = coord2
				else:
					mv2.pass = true
			result.moves.append(mv2)
		_:
			pass  # 忽略其它属性

# SGF 坐标 (如 "aa") → Vector2i(col, row)
# SGF 'a'-'s' = 0-18；左上为 aa；空串 → (-1, -1)
static func _sgf_to_coord(sgf: String, board_size: int) -> Vector2i:
	if sgf.length() < 2:
		return Vector2i(-1, -1)
	var col: int = sgf[0].to_ascii_buffer()[0] - ord('a')
	var row: int = sgf[1].to_ascii_buffer()[0] - ord('a')
	if col < 0 or col >= board_size or row < 0 or row >= board_size:
		return Vector2i(-1, -1)
	return Vector2i(col, row)

# 从文件路径加载 SGF
static func load_from_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		print("[REPLAY][SGF] 文件不存在: %s" % path)
		return {"ok": false, "error": "文件不存在: %s" % path}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		print("[REPLAY][SGF] 无法打开文件: %s" % path)
		return {"ok": false, "error": "无法打开文件"}
	var text: String = f.get_as_text()
	f.close()
	var file_size: int = text.length()
	var result: Dictionary = parse(text)
	if result.get("ok", false):
		var dt: String = result.get("date", "")
		var ev: String = result.get("event", "")
		var meta: String = ""
		if ev != "":
			meta += " 赛事=" + ev
		if dt != "":
			meta += " 日期=" + dt
		print("[REPLAY][SGF] 解析成功: %s (%d 字符 → %d 手%s)" % [
			path, file_size, result.moves.size(), meta])
	else:
		print("[REPLAY][SGF] 解析失败: %s - %s" % [path, result.get("error", "?")])
	return result
