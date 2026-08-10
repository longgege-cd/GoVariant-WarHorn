extends SceneTree
# 调试：圈内空点有4点但被误判为围困

func _init():
	var board := BoardModel.new()

	print("=== 场景1：黑方4x4墙，圈内4空点（应活棋） ===")
	# 黑方 5x5 围墙（行8-12, 列8-12），圈内 3x3=9 空点
	# 但放5个白子，剩4空点
	board = BoardModel.new()
	for c in range(8, 13):
		board.set_at(8, c, Const.BLACK)
		board.set_at(12, c, Const.BLACK)
	for r in range(9, 12):
		board.set_at(r, 8, Const.BLACK)
		board.set_at(r, 12, Const.BLACK)
	# 圈内白方5子（剩4空点）
	board.set_at(9, 9, Const.WHITE)
	board.set_at(9, 10, Const.WHITE)
	board.set_at(9, 11, Const.WHITE)
	board.set_at(10, 9, Const.WHITE)
	board.set_at(10, 10, Const.WHITE)
	# 圈内空点：(10,11)(11,9)(11,10)(11,11) = 4空点
	_print_siege_status(board, "场景1: 4空点")

	print("\n=== 场景2：黑方4x4墙，圈内5空点（应活棋） ===")
	board = BoardModel.new()
	for c in range(8, 13):
		board.set_at(8, c, Const.BLACK)
		board.set_at(12, c, Const.BLACK)
	for r in range(9, 12):
		board.set_at(r, 8, Const.BLACK)
		board.set_at(r, 12, Const.BLACK)
	# 圈内白方4子（剩5空点）
	board.set_at(9, 9, Const.WHITE)
	board.set_at(9, 10, Const.WHITE)
	board.set_at(9, 11, Const.WHITE)
	board.set_at(10, 9, Const.WHITE)
	# 圈内空点：(10,10)(10,11)(11,9)(11,10)(11,11) = 5空点
	_print_siege_status(board, "场景2: 5空点")

	print("\n=== 场景3：黑方4x4墙，圈内3空点+1白子（应围困） ===")
	board = BoardModel.new()
	for c in range(8, 12):
		board.set_at(8, c, Const.BLACK)
		board.set_at(11, c, Const.BLACK)
	for r in range(9, 11):
		board.set_at(r, 8, Const.BLACK)
		board.set_at(r, 11, Const.BLACK)
	# 圈内白方1子
	board.set_at(9, 9, Const.WHITE)
	# 圈内空点：(9,10)(10,9)(10,10) = 3空点
	_print_siege_status(board, "场景3: 3空点")

	print("\n=== 场景4：黑方大墙，圈内空点被白子分割，每组≥4 ===")
	# 黑方 6x6 围墙（行8-13, 列8-13），圈内 4x4=16 空点
	board = BoardModel.new()
	for c in range(8, 14):
		board.set_at(8, c, Const.BLACK)
		board.set_at(13, c, Const.BLACK)
	for r in range(9, 13):
		board.set_at(r, 8, Const.BLACK)
		board.set_at(r, 13, Const.BLACK)
	# 圈内白方两组，被黑子分隔
	# 左白组：(9,9)(10,9) + 空点(9,10)(10,10)(11,9)(11,10)
	board.set_at(9, 9, Const.WHITE)
	board.set_at(10, 9, Const.WHITE)
	# 分隔黑子：(9,11)
	board.set_at(9, 11, Const.BLACK)
	# 右白组：(9,12)(10,12) + 空点(10,11)(11,11)(11,12)
	board.set_at(9, 12, Const.WHITE)
	board.set_at(10, 12, Const.WHITE)
	_print_siege_status(board, "场景4: 分割")

	print("\n=== 场景5：圈内4空点全部连通（应活棋） ===")
	board = BoardModel.new()
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
	_print_siege_status(board, "场景5: 4空点连通")

	quit()

func _print_siege_status(board: BoardModel, label: String) -> void:
	var groups := board.all_groups()
	print("[%s] 棋子组群数: %d" % [label, groups.size()])
	for i in range(groups.size()):
		var g = groups[i]
		var stones = g.stones
		var color_name = "黑" if g.color == Const.BLACK else "白"
		var libs = board.liberties(stones)
		var sieged = SiegeDetector.is_sieged(board, g)
		var surrounded = SiegeDetector._is_surrounded_by_opponent(board, g)
		var two_eyes = SiegeDetector.has_two_true_eyes(board, g)
		var legal_pts = SiegeDetector.count_legal_empty_points(board, g)
		var region = _get_region(board, stones)
		print("  组群%d: %s方 %d子, 气=%d, 气域=%d点, legal=%d, 被包围=%s, 两眼=%s → 围困=%s" % [
			i, color_name, stones.size(), libs.size(), region.size(), legal_pts,
			str(surrounded), str(two_eyes), str(sieged)
		])
		# 打印气域空点坐标
		if g.color == Const.WHITE:
			var pts = []
			for idx in region:
				var r = idx / board.size
				var c = idx % board.size
				pts.append("(%d,%d)" % [r, c])
			print("    气域空点: %s" % str(pts))
			# 打印每个空点的legal判定
			for idx in region:
				var r = idx / board.size
				var c = idx % board.size
				var legal = SiegeDetector._is_legal_move(board, r, c, g.color)
				print("    (%d,%d) legal=%s" % [r, c, str(legal)])

func _get_region(board: BoardModel, stones: Array) -> Dictionary:
	var size = board.size
	var libs = board.liberties(stones)
	var region = {}
	var stack = []
	for l in libs:
		stack.append([l.y, l.x])
	while stack.size() > 0:
		var p = stack.pop_back()
		var idx = p[0] * size + p[1]
		if region.has(idx):
			continue
		if board.get_at(p[0], p[1]) != Const.EMPTY:
			continue
		region[idx] = true
		for n in board.neighbors(p[0], p[1]):
			var ni = n[0] * size + n[1]
			if board.get_at(n[0], n[1]) == Const.EMPTY and not region.has(ni):
				stack.append(n)
	return region
