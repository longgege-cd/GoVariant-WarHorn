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
#   - 分支 (...)[...]（仅取主分支，跳过子分支）
#   - AB[xy]/AW[xy] 让子/初始局面
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

	# 顺序扫描主分支
	# 支持两种 SGF 格式：
	#   1. 标准线性：(;B[qd];W[dp];B[pq];...)
	#   2. 链式嵌套：(;B[qd](;W[dp](;B[pq]...)))
	# 使用栈 branch_taken 跟踪每个层级是否已选过子分支：
	#   - 遇到 ( 时，如果当前层级已选过子分支 → 变着，回退第一个子分支的节点并跳过
	#   - 否则 → 进入子分支（链式嵌套或变着的第一个子分支）
	var branch_depth: int = 0  # 当前子分支深度（0=主分支）
	var branch_taken: Array = [false]  # branch_taken[d] = 当前深度 d 是否已选过子分支
	var branch_moves_len: Array = [0]  # 进入子分支前的 moves 长度（回退用）
	while p < n:
		var ch: String = text[p]
		if ch == '(':
			if branch_taken[branch_depth]:
				# 变着：回退第一个子分支中解析的节点，跳过当前子分支
				result.moves.resize(branch_moves_len[branch_depth])
				var skip_depth: int = 1
				p += 1
				while p < n and skip_depth > 0:
					if text[p] == '(':
						skip_depth += 1
					elif text[p] == ')':
						skip_depth -= 1
					p += 1
				continue
			else:
				# 第一个子分支 → 记录回退点，进入
				branch_taken[branch_depth] = true
				branch_moves_len[branch_depth] = result.moves.size()
				branch_depth += 1
				branch_taken.append(false)
				branch_moves_len.append(0)
				p += 1
				continue
		elif ch == ')':
			branch_depth -= 1
			branch_taken.pop_back()
			branch_moves_len.pop_back()
			if branch_depth < 0:
				break  # 主分支结束
			p += 1
			continue
		elif ch == ';':
			# 节点起始
			p += 1
			# 跳过空白
			while p < n and _is_ws(text[p]):
				p += 1
			# 解析该节点所有属性
			while p < n and text[p] != ';' and text[p] != '(' and text[p] != ')':
				# 读属性名
				var key: String = ""
				while p < n and text[p] != '[' and text[p] != ';' and text[p] != '(' and text[p] != ')' and not _is_ws(text[p]):
					key += text[p]
					p += 1
				if key == "":
					# 可能是空白或 '[' 单独出现，跳过
					if p < n and text[p] == '[':
						# 直接跳过 value
						p = _skip_value(text, p)
					elif p < n and _is_ws(text[p]):
						p += 1
					else:
						break
					continue
				# 读一个或多个 [value]
				var values: Array = []
				while p < n and text[p] == '[':
					var v: String = ""
					p += 1
					while p < n and text[p] != ']':
						if text[p] == '\\' and p + 1 < n:
							v += text[p + 1]
							p += 2
						else:
							v += text[p]
							p += 1
					if p < n:
						p += 1  # 跳过 ']'
					values.append(v)
				# 处理属性
				_apply_property(result, key.to_upper(), values)
			continue
		else:
			p += 1

	result.ok = true
	return result

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
