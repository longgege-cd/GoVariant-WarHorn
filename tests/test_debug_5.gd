extends SceneTree
# 调试：场景5详细分析

func _init():
	var board := BoardModel.new()
	print("=== 场景5：圈内4空点全部连通（应活棋） ===")
	for c in range(8, 13):
		board.set_at(8, c, Const.BLACK)
		board.set_at(12, c, Const.BLACK)
	for r in range(9, 12):
		board.set_at(r, 8, Const.BLACK)
		board.set_at(r, 12, Const.BLACK)
	# 圈内白方5子，剩4空点全连通
	board.set_at(9, 9, Const.WHITE)
	board.set_at(9, 10, Const.WHITE)
	board.set_at(10, 9, Const.WHITE)
	board.set_at(10, 11, Const.WHITE)
	board.set_at(11, 11, Const.WHITE)
	# 圈内空点：(9,11)(10,10)(11,9)(11,10) = 4空点

	# 打印棋盘
	print("棋盘(行8-12, 列8-12):")
	for r in range(8, 13):
		var row_str = ""
		for c in range(8, 13):
			var v = board.get_at(r, c)
			if v == Const.BLACK:
				row_str += "X "
			elif v == Const.WHITE:
				row_str += "O "
			else:
				row_str += ". "
		print("  行%d: %s" % [r, row_str])

	# 打印所有包围圈（原始和去重后）
	print("\n--- 原始包围圈(_collect_raw_enclosures) ---")
	# _collect_raw_enclosures 是私有的，用 enclosures() 代替
	var encs = TerritoryDetector.enclosures(board)
	print("包围圈数: %d" % encs.size())
	for i in range(encs.size()):
		var e = encs[i]
		var color_name = "黑" if e.color == Const.BLACK else "白"
		var pts_str = []
		for p in e.points:
			pts_str.append("(%d,%d)" % [p.y, p.x])
		var stones_str = []
		for s in e.stones_inside:
			stones_str.append("(%d,%d)" % [s.y, s.x])
		print("  围空圈%d: %s方, 空点=%d%s, 圈内棋子=%d%s" % [
			i, color_name, e.points.size(), str(pts_str), e.stones_inside.size(), str(stones_str)
		])

	# 白方组群详情
	var groups = board.all_groups()
	print("\n--- 白方组群 ---")
	for g in groups:
		if g.color != Const.WHITE:
			continue
		var stones = g.stones
		var legal_pts = SiegeDetector.count_legal_empty_points(board, g)
		print("  白方 %d子, legal=%d" % [stones.size(), legal_pts])
		# 检查包围圈是否包含该组群
		var opp = Const.opponent(g.color)
		var group_set = {}
		for s in stones:
			group_set[s.y * board.size + s.x] = true
		for i in range(encs.size()):
			var e = encs[i]
			if e.color != opp:
				continue
			var contains = false
			for s in e.stones_inside:
				if group_set.has(s.y * board.size + s.x):
					contains = true
					break
			if contains:
				var pts_str = []
				for p in e.points:
					pts_str.append("(%d,%d)" % [p.y, p.x])
				print("    在围空圈%d中, 该圈空点=%d%s" % [i, e.points.size(), str(pts_str)])

	quit()
