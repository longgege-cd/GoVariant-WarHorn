extends SceneTree
# 调试：包围圈内空间被黑白棋子分割后的围困判定

func _init():
	var board := BoardModel.new()
	var size := board.size

	print("=== 场景1：黑方包围圈内，白方两组被黑子分隔 ===")
	# 黑方大包围圈（行10-14, 列10-14）
	board = BoardModel.new()
	for c in range(10, 15):
		board.set_at(10, c, Const.BLACK)
		board.set_at(14, c, Const.BLACK)
	for r in range(11, 14):
		board.set_at(r, 10, Const.BLACK)
		board.set_at(r, 14, Const.BLACK)
	# 圈内白方两组，被黑子分隔
	# 左白组：(11,11)(11,12)，气域={(12,11)(12,12)} = 2空点
	board.set_at(11, 11, Const.WHITE)
	board.set_at(11, 12, Const.WHITE)
	# 分隔黑子：(11,13)
	board.set_at(11, 13, Const.BLACK)
	# 右白组：(11,13)已经是黑子了... 换个布局
	# 右白组：(13,11)(13,12)
	board.set_at(13, 11, Const.WHITE)
	board.set_at(13, 12, Const.WHITE)
	# 圈内空点：(12,11)(12,12)(12,13)
	# (12,13)被黑子(11,13)分隔，但在同一空连通块吗？
	_print_siege_status(board, "场景1")

	print("\n=== 场景2：黑方包围圈内，白方大组+圈内黑子分割空间 ===")
	board = BoardModel.new()
	for c in range(10, 18):
		board.set_at(10, c, Const.BLACK)
		board.set_at(14, c, Const.BLACK)
	for r in range(11, 14):
		board.set_at(r, 10, Const.BLACK)
		board.set_at(r, 17, Const.BLACK)
	# 白方大组：(11,11)-(11,16) + (13,11)-(13,16)
	for c in range(11, 17):
		board.set_at(11, c, Const.WHITE)
		board.set_at(13, c, Const.WHITE)
	# 圈内黑子：(12,14) 分割空间
	board.set_at(12, 14, Const.BLACK)
	# 圈内空点：(12,11)(12,12)(12,13) 和 (12,15)(12,16)
	# 被黑子(12,14)分割成3+2
	_print_siege_status(board, "场景2")

	print("\n=== 场景3：黑方包围圈内，白方棋子+黑子混合分割 ===")
	board = BoardModel.new()
	for c in range(8, 17):
		board.set_at(8, c, Const.BLACK)
		board.set_at(16, c, Const.BLACK)
	for r in range(9, 16):
		board.set_at(r, 8, Const.BLACK)
		board.set_at(r, 16, Const.BLACK)
	# 白方组群A：(9,9)(9,10)(9,11)
	board.set_at(9, 9, Const.WHITE)
	board.set_at(9, 10, Const.WHITE)
	board.set_at(9, 11, Const.WHITE)
	# 圈内黑子：(10,12)
	board.set_at(10, 12, Const.BLACK)
	# 白方组群B：(13,13)(13,14)
	board.set_at(13, 13, Const.WHITE)
	board.set_at(13, 14, Const.WHITE)
	# 圈内黑子：(11,13)
	board.set_at(11, 13, Const.BLACK)
	# 圈内空点：各种位置
	_print_siege_status(board, "场景3")

	print("\n=== 场景4：圈内空间被白子分割（白方两组不连通） ===")
	board = BoardModel.new()
	for c in range(10, 17):
		board.set_at(10, c, Const.BLACK)
		board.set_at(14, c, Const.BLACK)
	for r in range(11, 14):
		board.set_at(r, 10, Const.BLACK)
		board.set_at(r, 16, Const.BLACK)
	# 白方组群A：(11,11)(12,11) — 左侧
	board.set_at(11, 11, Const.WHITE)
	board.set_at(12, 11, Const.WHITE)
	# 白方组群B：(11,15)(12,15) — 右侧
	board.set_at(11, 15, Const.WHITE)
	board.set_at(12, 15, Const.WHITE)
	# 圈内空点：(11,12)(11,13)(11,14)(12,12)(12,13)(12,14)(13,11)-(13,15)
	# 两组不连通，各自独立判定
	_print_siege_status(board, "场景4")

	print("\n=== 场景5：圈内黑子把白方气域分割成<4（应围困） ===")
	board = BoardModel.new()
	for c in range(8, 15):
		board.set_at(8, c, Const.BLACK)
		board.set_at(14, c, Const.BLACK)
	for r in range(9, 14):
		board.set_at(r, 8, Const.BLACK)
		board.set_at(r, 14, Const.BLACK)
	# 白方大组：(9,9)-(9,13) + (13,9)-(13,13)
	for c in range(9, 14):
		board.set_at(9, c, Const.WHITE)
		board.set_at(13, c, Const.WHITE)
	# 圈内黑子分割：(11,9)(11,11)(11,13) — 把空间分成小份
	board.set_at(11, 9, Const.BLACK)
	board.set_at(11, 11, Const.BLACK)
	board.set_at(11, 13, Const.BLACK)
	# 圈内空点被分割
	_print_siege_status(board, "场景5")

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
		# 气域
		var region = _get_region(board, stones)
		print("  组群%d: %s方 %d子, 气=%d, 气域=%d点, legal=%d, 被包围=%s, 两眼=%s → 围困=%s" % [
			i, color_name, stones.size(), libs.size(), region.size(), legal_pts,
			str(surrounded), str(two_eyes), str(sieged)
		])
	# 包围圈
	var encs = TerritoryDetector.enclosures(board)
	print("  包围圈数: %d" % encs.size())
	for i in range(encs.size()):
		var e = encs[i]
		var color_name = "黑" if e.color == Const.BLACK else "白"
		print("  围空圈%d: %s方, 空点=%d, 圈内棋子=%d" % [i, color_name, e.points.size(), e.stones_inside.size()])

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
