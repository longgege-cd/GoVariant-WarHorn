extends SceneTree
# 读取 user://logs/game_YYYYMMDD.log（最新日期），解析落子序列重建盘面并显示得分/围空圈
# 运行：Godot_v4.7-stable_win64_console.exe --headless --path . --script res://tests/diag_readboard.gd

func _init() -> void:
	# 优先最新 game_*.log；为空则回退最新 godot 控制台日志（含落子行）
	var candidates: Array = []
	var dir := DirAccess.open("user://logs/")
	if dir == null:
		print("无日志目录")
		quit(1)
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.begins_with("game_") and fname.ends_with(".log"):
			candidates.append(fname)
		elif fname.begins_with("godot20") and fname.ends_with(".log"):
			candidates.append(fname)
		fname = dir.get_next()
	candidates.sort()
	var path := ""
	var best_n := 0
	for cand in candidates:
		var moves: Array = _parse_moves("user://logs/" + cand)
		if moves.size() > best_n:
			best_n = moves.size()
			path = "user://logs/" + cand
			_moves = moves
	if path == "" or _moves.is_empty():
		print("无含落子记录的日志")
		quit(1)
		return
	print("读取日志: %s（%d 手）" % [path, _moves.size()])
	# 重放
	var s := GameSession.new()
	for m in _moves:
		var out: Dictionary = s.play_move(m[0], m[1], m[2])
		if not out.ok:
			print("!!! 落子失败 @(%d,%d): %s" % [m[1], m[2], out])
	# 打印盘面
	print("      0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8")
	for r in range(19):
		var line := "%2d  " % r
		for c in range(19):
			var v: int = s.board.get_at(r, c)
			line += ("● " if v == Const.BLACK else "○ " if v == Const.WHITE else ". ")
		print(line)
	var sc: Dictionary = s.scores()
	print("")
	print("黑: 活子=%d 围空=%d 围困=%d 歼灭=%d 战损=%d 总=%d" % [sc.black.occupation_live, sc.black.occupation_territory, sc.black.defense_siege, sc.black.defense_annihilate, -sc.black.casualty_loss, sc.black.total()])
	print("白: 活子=%d 围空=%d 围困=%d 歼灭=%d 战损=%d 总=%d" % [sc.white.occupation_live, sc.white.occupation_territory, sc.white.defense_siege, sc.white.defense_annihilate, -sc.white.casualty_loss, sc.white.total()])
	for e in TerritoryDetector.enclosures(s.board):
		print("围空圈 色=%s pts=%d si=%d" % ["黑" if e.color == Const.BLACK else "白", e.points.size(), e.stones_inside.size()])
	quit(0)

var _moves: Array = []

func _parse_moves(path: String) -> Array:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var moves: Array = []
	var re := RegEx.new()
	re.compile("落子 ply=\\d+ (黑|白)@\\((\\d+),(\\d+)\\)")
	while not f.eof_reached():
		var line: String = f.get_line()
		var m := re.search(line)
		if m != null:
			var color: int = Const.BLACK if m.get_string(1) == "黑" else Const.WHITE
			moves.append([color, int(m.get_string(2)), int(m.get_string(3))])
	f.close()
	return moves
