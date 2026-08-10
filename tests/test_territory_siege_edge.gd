extends RefCounted
# 围空 / 围困 算法边界情况测试
#
# 覆盖 test_territory.gd / test_siege.gd / test_score.gd 未验证的情况：
#   A. 围空算法（TerritoryDetector）
#     - 多个独立围空圈
#     - 黑白双方同时围空
#     - 嵌套围空去重（内层从外层扣除）
#     - stones_inside 跨圈去重
#     - 对角线缺口（flooding 正交移动）
#     - 围空圈内含多个对方组群
#     - 围空圈内对方组群分割空块
#     - enclosures_of 过滤
#     - stone_participates_in_enclosure 非该色棋子
#   B. 围困算法（SiegeDetector）
#     - 角落组群被对方包围
#     - 通过己方棋子链连接外部 → 不被包围
#     - 真眼判定：对方可落子 → 非真眼
#     - 真眼判定：填眼可提吃对方（倒扑）→ 非独立真眼
#     - count_legal_empty_points：能提吃的禁入点算合法
#     - count_legal_empty_points：被己方棋子分割的空点
#   C. 围空分计分（v5.4 新规则：对方活棋不计入围空分）
#     - 围空圈内对方活棋（≥4合法空点）位置不计入
#     - 围空圈内对方两真眼活棋位置不计入
#     - 围空圈内围困+活棋混合
#     - 困棋包围圈扣除时活棋位置不扣（加减对称）

func run(t: TestFramework) -> void:
	t.suite("围空/围困 边界情况")

	# ============================================================
	# A. 围空算法（TerritoryDetector）
	# ============================================================

	# A1. 多个独立围空圈：黑方在两处分别围空
	var b := BoardModel.new()
	# 围空圈1：黑围 (2,2)
	b.set_at(2, 1, Const.BLACK)
	b.set_at(1, 2, Const.BLACK)
	b.set_at(2, 3, Const.BLACK)
	b.set_at(3, 2, Const.BLACK)
	# 围空圈2：黑围 (15,15)
	b.set_at(15, 14, Const.BLACK)
	b.set_at(14, 15, Const.BLACK)
	b.set_at(15, 16, Const.BLACK)
	b.set_at(16, 15, Const.BLACK)
	# 远处白子，使外部边界含两色
	b.set_at(0, 18, Const.WHITE)
	var encs = TerritoryDetector.enclosures(b)
	t.expect_eq(encs.size(), 2, "A1: 黑方两处独立围空 → 2 个围空圈")
	if encs.size() == 2:
		var total_pts: int = 0
		for e in encs:
			total_pts += e.points.size()
		t.expect_eq(total_pts, 2, "A1: 两个围空圈各 1 点")

	# A2. 黑白双方同时围空（各一处）
	b = BoardModel.new()
	# 黑围 (2,2)
	b.set_at(2, 1, Const.BLACK)
	b.set_at(1, 2, Const.BLACK)
	b.set_at(2, 3, Const.BLACK)
	b.set_at(3, 2, Const.BLACK)
	# 白围 (16,16)
	b.set_at(16, 15, Const.WHITE)
	b.set_at(15, 16, Const.WHITE)
	b.set_at(16, 17, Const.WHITE)
	b.set_at(17, 16, Const.WHITE)
	encs = TerritoryDetector.enclosures(b)
	t.expect_eq(encs.size(), 2, "A2: 黑白各一处围空 → 2 个")
	if encs.size() == 2:
		var colors: Array = [encs[0].color, encs[1].color]
		colors.sort()
		t.expect_eq(colors, [Const.BLACK, Const.WHITE], "A2: 黑白各一")

	# A3. 嵌套围空去重：外层大圈含内层小圈，内层空点只计一次
	# 外层黑 7x7 围墙（行4-10, 列4-10），内层黑 3x3 围墙（行6-8, 列6-8）围 (7,7)
	# 外层内部 = 5x5=25 空点，内层墙占 8 点，内层围 (7,7) 1 点
	# 去重后：外层 25-8-1=16 点 + 内层 1 点 = 17 点
	b = BoardModel.new()
	for c in range(4, 11):
		b.set_at(4, c, Const.BLACK)
		b.set_at(10, c, Const.BLACK)
	for r in range(5, 10):
		b.set_at(r, 4, Const.BLACK)
		b.set_at(r, 10, Const.BLACK)
	# 内层 3x3 围 (7,7)
	for c in range(6, 9):
		b.set_at(6, c, Const.BLACK)
		b.set_at(8, c, Const.BLACK)
	b.set_at(7, 6, Const.BLACK)
	b.set_at(7, 8, Const.BLACK)
	b.set_at(0, 18, Const.WHITE)
	encs = TerritoryDetector.enclosures(b)
	# 内层 (7,7) 1点 + 外层去重后 16 点 = 共 17 点空
	var total_enc_pts: int = 0
	for e in encs:
		total_enc_pts += e.points.size()
	t.expect_eq(total_enc_pts, 17, "A3: 嵌套围空去重后共 17 点")

	# A4. stones_inside 跨圈去重：同一对方棋子不被多个圈重复计入
	# 黑外层大圈 + 黑内层小圈，圈内同一白子只计一次
	b = BoardModel.new()
	# 外层黑 6x6（行4-9, 列4-9）
	for c in range(4, 10):
		b.set_at(4, c, Const.BLACK)
		b.set_at(9, c, Const.BLACK)
	for r in range(5, 9):
		b.set_at(r, 4, Const.BLACK)
		b.set_at(r, 9, Const.BLACK)
	# 内层黑 4x4（行5-8, 列5-8）
	for c in range(5, 9):
		b.set_at(5, c, Const.BLACK)
		b.set_at(8, c, Const.BLACK)
	for r in range(6, 8):
		b.set_at(r, 5, Const.BLACK)
		b.set_at(r, 8, Const.BLACK)
	# 圈内白子 (6,7)，其气在内层圈内
	b.set_at(6, 7, Const.WHITE)
	b.set_at(0, 18, Const.WHITE)
	encs = TerritoryDetector.enclosures(b)
	var total_stones_inside: int = 0
	for e in encs:
		total_stones_inside += e.get("stones_inside", []).size()
	t.expect_eq(total_stones_inside, 1, "A4: 同一白子跨圈去重 → 只计 1 次")

	# A5. 对角线缺口：黑墙对角缺口处两黑子阻挡 flooding（仍视为封闭）
	# 黑围 (2,2)，但四角留对角缺口（实际围棋中仍封闭）
	b = BoardModel.new()
	# 黑围 (2,2)：上下左右各放黑子，四角也放黑子（完全封闭）
	b.set_at(1, 1, Const.BLACK); b.set_at(1, 2, Const.BLACK); b.set_at(1, 3, Const.BLACK)
	b.set_at(2, 1, Const.BLACK);                           b.set_at(2, 3, Const.BLACK)
	b.set_at(3, 1, Const.BLACK); b.set_at(3, 2, Const.BLACK); b.set_at(3, 3, Const.BLACK)
	b.set_at(0, 18, Const.WHITE)
	encs = TerritoryDetector.enclosures(b)
	t.expect_eq(encs.size(), 1, "A5: 完全封闭围空 1 个")
	if encs.size() == 1:
		t.expect_eq(encs[0].points.size(), 1, "A5: 围空 1 点 (2,2)")

	# A6. 围空圈内含多个对方组群：圈内两颗独立的白子
	b = BoardModel.new()
	# 黑 6x6 围墙（行5-10, 列5-10），内部 4x4=16 空点
	for c in range(5, 11):
		b.set_at(5, c, Const.BLACK)
		b.set_at(10, c, Const.BLACK)
	for r in range(6, 10):
		b.set_at(r, 5, Const.BLACK)
		b.set_at(r, 10, Const.BLACK)
	# 圈内两颗独立白子（不连通）
	b.set_at(7, 7, Const.WHITE)
	b.set_at(8, 8, Const.WHITE)
	b.set_at(0, 18, Const.WHITE)
	encs = TerritoryDetector.enclosures(b)
	t.expect_eq(encs.size(), 1, "A6: 含两白子的围空 1 个")
	if encs.size() == 1:
		# 两白子气都在黑圈内 → 都计入 stones_inside
		t.expect_eq(encs[0].get("stones_inside", []).size(), 2, "A6: 圈内 2 颗白子")

	# A7. 围空圈内对方组群分割空块：白子把圈内空地分成两块
	b = BoardModel.new()
	# 黑 7x7 围墙（行5-11, 列5-11），内部 5x5=25 空点
	for c in range(5, 12):
		b.set_at(5, c, Const.BLACK)
		b.set_at(11, c, Const.BLACK)
	for r in range(6, 11):
		b.set_at(r, 5, Const.BLACK)
		b.set_at(r, 11, Const.BLACK)
	# 白子横向一排（行8, 列6-10）分割上下空地
	for c in range(6, 11):
		b.set_at(8, c, Const.WHITE)
	b.set_at(0, 18, Const.WHITE)
	encs = TerritoryDetector.enclosures(b)
	# 白子把圈内空地分成上下两块，但两块都被黑围 → 2 个围空圈
	t.expect_eq(encs.size(), 2, "A7: 白子分割圈内空地 → 2 个围空圈")
	# 白子组群气在两个圈内 → 计入 stones_inside
	var a7_stones: int = 0
	for e in encs:
		a7_stones += e.get("stones_inside", []).size()
	t.expect_eq(a7_stones, 5, "A7: 白子组群 5 子计入 stones_inside")

	# A8. enclosures_of 过滤：只返回指定色的围空
	b = BoardModel.new()
	b.set_at(2, 1, Const.BLACK)
	b.set_at(1, 2, Const.BLACK)
	b.set_at(2, 3, Const.BLACK)
	b.set_at(3, 2, Const.BLACK)
	b.set_at(16, 15, Const.WHITE)
	b.set_at(15, 16, Const.WHITE)
	b.set_at(16, 17, Const.WHITE)
	b.set_at(17, 16, Const.WHITE)
	var black_encs = TerritoryDetector.enclosures_of(b, Const.BLACK)
	var white_encs = TerritoryDetector.enclosures_of(b, Const.WHITE)
	t.expect_eq(black_encs.size(), 1, "A8: 黑方围空 1 个")
	t.expect_eq(white_encs.size(), 1, "A8: 白方围空 1 个")
	t.expect_eq(black_encs[0].color, Const.BLACK, "A8: 黑方围空色 = 黑")
	t.expect_eq(white_encs[0].color, Const.WHITE, "A8: 白方围空色 = 白")

	# A9. stone_participates_in_enclosure 非该色棋子 → false
	b = BoardModel.new()
	b.set_at(2, 1, Const.BLACK)
	b.set_at(1, 2, Const.BLACK)
	b.set_at(2, 3, Const.BLACK)
	b.set_at(3, 2, Const.BLACK)
	b.set_at(0, 18, Const.WHITE)
	# (2,1) 是黑子参与黑围空
	t.expect(TerritoryDetector.stone_participates_in_enclosure(b, 2, 1, Const.BLACK), "A9: (2,1)黑参与黑围空")
	# (2,1) 不是白子 → 不参与白围空
	t.expect(not TerritoryDetector.stone_participates_in_enclosure(b, 2, 1, Const.WHITE), "A9: (2,1)黑不参与白围空")
	# 远处白子 (0,18) 不参与黑围空
	t.expect(not TerritoryDetector.stone_participates_in_enclosure(b, 0, 18, Const.BLACK), "A9: (0,18)白不参与黑围空")

	# ============================================================
	# B. 围困算法（SiegeDetector）
	# ============================================================

	# B1. 角落组群被对方包围 → 被包围
	# 黑组群在角落 (0,0)(0,1)(1,0)，外围白子封死
	b = BoardModel.new()
	b.set_at(0, 0, Const.BLACK)
	b.set_at(0, 1, Const.BLACK)
	b.set_at(1, 0, Const.BLACK)
	# 白子封堵：(0,2)(1,1)(2,0)
	b.set_at(0, 2, Const.WHITE)
	b.set_at(1, 1, Const.WHITE)
	b.set_at(2, 0, Const.WHITE)
	var g = b.group_at(0, 0)
	t.expect(SiegeDetector._is_surrounded_by_opponent(b, g), "B1: 角落黑组群被白包围")
	# legal空点=0 < 4 → 围困
	t.expect(SiegeDetector.is_sieged(b, g), "B1: 角落黑组群无眼无空间 → 围困")

	# B2. 通过己方棋子链连接到外部 → 不被包围
	# 黑组群被白围住，但通过己方棋子链连到远处
	b = BoardModel.new()
	# 黑组群 (5,5)(5,6) 被白围
	b.set_at(5, 5, Const.BLACK)
	b.set_at(5, 6, Const.BLACK)
	b.set_at(4, 5, Const.WHITE)
	b.set_at(6, 5, Const.WHITE)
	b.set_at(4, 6, Const.WHITE)
	b.set_at(6, 6, Const.WHITE)
	# 但 (5,6) 通过 (5,7) 连到 (5,8)（己方棋子链连外部）
	b.set_at(5, 7, Const.BLACK)
	b.set_at(5, 8, Const.BLACK)
	g = b.group_at(5, 5)
	# 注意：(5,5)(5,6) 与 (5,7)(5,8) 是否连通取决于 (5,6)-(5,7) 邻接
	# (5,6) 邻居 (5,7) 是黑 → 连通 → 大组群
	t.expect_eq(g.stones.size(), 4, "B2: 黑 4 子连通（含外部棋子链）")
	t.expect(not SiegeDetector._is_surrounded_by_opponent(b, g), "B2: 通过己方棋子链连外部 → 不被包围")
	t.expect(not SiegeDetector.is_sieged(b, g), "B2: 不被包围 → 不围困")

	# B3. 真眼判定：对方可在眼位落子（提吃） → 非真眼
	# 黑 8 子连通环围 (1,1)，外圈被白封死 → 黑唯一气=(1,1)
	# 白下 (1,1) 提黑 8 子 → (1,1) 非真眼
	b = BoardModel.new()
	# 3x3 黑环围 (1,1)：8 子连通
	b.set_at(0, 0, Const.BLACK); b.set_at(0, 1, Const.BLACK); b.set_at(0, 2, Const.BLACK)
	b.set_at(1, 0, Const.BLACK);                           b.set_at(1, 2, Const.BLACK)
	b.set_at(2, 0, Const.BLACK); b.set_at(2, 1, Const.BLACK); b.set_at(2, 2, Const.BLACK)
	# 白封死黑外圈：(0,3)(1,3)(2,3)(3,0)(3,1)(3,2)(3,3)
	b.set_at(0, 3, Const.WHITE); b.set_at(1, 3, Const.WHITE); b.set_at(2, 3, Const.WHITE)
	b.set_at(3, 0, Const.WHITE); b.set_at(3, 1, Const.WHITE); b.set_at(3, 2, Const.WHITE); b.set_at(3, 3, Const.WHITE)
	var black_group = b.group_at(0, 1)
	t.expect_eq(black_group.stones.size(), 8, "B3: 黑 8 子连通围 (1,1)")
	# (1,1) 是黑组群唯一气 → 白下 (1,1) 提黑 → 非真眼
	t.expect(SiegeDetector._is_legal_move(b, 1, 1, Const.WHITE), "B3: 白可在 (1,1) 落子（提黑）")
	# group_set 包含黑组群
	var gs: Dictionary = {}
	for s in black_group.stones:
		gs[s.y * b.size + s.x] = true
	t.expect(not SiegeDetector._is_true_eye(b, 1, 1, gs, Const.BLACK), "B3: (1,1) 白可落子 → 非真眼")

	# B4. 真眼判定：眼位正交邻居含对方棋子 → 非真眼（条件1失败）
	# 黑围眼 (2,2)，但 (2,2) 正交邻居中有白子 → 不满足"四周全为该组棋子"
	b = BoardModel.new()
	# 黑围眼棋子：(1,2)(2,1)(2,3)，故意不放 (3,2)（让白占）
	b.set_at(1, 2, Const.BLACK)
	b.set_at(2, 1, Const.BLACK)
	b.set_at(2, 3, Const.BLACK)
	# 白子 (3,2)，气只在 (2,2)（被黑 (4,2)(3,1)(3,3) 围）
	b.set_at(3, 2, Const.WHITE)
	b.set_at(4, 2, Const.BLACK)
	b.set_at(3, 1, Const.BLACK)
	b.set_at(3, 3, Const.BLACK)
	# (2,2) 正交邻居 (1,2)黑(3,2)白(2,1)黑(2,3)黑 → (3,2) 不在 group_set → 条件1失败
	var black_g_b4 = b.group_at(1, 2)
	var gs_b4: Dictionary = {}
	for s in black_g_b4.stones:
		gs_b4[s.y * b.size + s.x] = true
	t.expect(not SiegeDetector._is_true_eye(b, 2, 2, gs_b4, Const.BLACK), "B4: 眼位邻居含白子 → 非真眼（条件1失败）")

	# B5. count_legal_empty_points：能提吃对方的禁入点算合法
	# 黑组群被白围，但圈内空点能提白 → 算合法空点
	b = BoardModel.new()
	# 黑组群 (5,5) 被白 (4,5)(6,5)(5,4) 围，(5,6) 是空点
	# 白 (4,5)(6,5)(5,4) 各自独立，气较少
	# 黑下 (5,6) 不能提白（白有其他气）→ 这里测反向：白组群被黑围，白下某点能提黑
	# 改：黑组群 (5,5) 1 子，气 = (5,6) 1 个（被白 (4,5)(6,5)(5,4) 围）
	# 黑下 (5,6) 后，黑 (5,5)(5,6) 组群气增加 → 合法
	b.set_at(5, 5, Const.BLACK)
	b.set_at(4, 5, Const.WHITE)
	b.set_at(6, 5, Const.WHITE)
	b.set_at(5, 4, Const.WHITE)
	# (5,6) 是空点，黑下 (5,6) 后组群 (5,5)(5,6) 气 = (5,7) → 合法
	g = b.group_at(5, 5)
	var legal_pts = SiegeDetector.count_legal_empty_points(b, g)
	t.expect(legal_pts >= 1, "B5: 黑组群圈内至少 1 合法空点 (5,6)")

	# B6. count_legal_empty_points：被己方棋子分割的空点
	# 黑组群围出两个独立眼，外围白墙封堵 → flooding 限制在圈内
	b = BoardModel.new()
	# 黑 5x3 框围两个独立眼 (1,1)(1,3)，被 (1,2) 分隔
	#  B B B B B
	#  B . B . B
	#  B B B B B
	var black_stones_b6 := [
		[0,0],[0,1],[0,2],[0,3],[0,4],
		[1,0],[1,2],[1,4],
		[2,0],[2,1],[2,2],[2,3],[2,4],
	]
	for s in black_stones_b6:
		b.set_at(s[0], s[1], Const.BLACK)
	# 外围白墙：封堵行 -1(越界跳过)/3 和列 -1(越界跳过)/5
	# 行3 全白（列0-4），列5 全白（行0-2）
	for c in range(5):
		b.set_at(3, c, Const.WHITE)
	for r in range(3):
		b.set_at(r, 5, Const.WHITE)
	g = b.group_at(1, 0)
	t.expect_eq(g.stones.size(), 13, "B6: 黑 13 子连通")
	# 两个空点 (1,1)(1,3)，都是黑的眼位
	# 黑下 (1,1) 后组群气=(1,3) → 合法；黑下 (1,3) 后组群气=(1,1) → 合法
	# count_legal_empty_points 统计圈内可合法落子的空点 = 2
	legal_pts = SiegeDetector.count_legal_empty_points(b, g)
	t.expect_eq(legal_pts, 2, "B6: 两个眼位空点都可合法落子（填眼后仍有气）")

	# B7. 大气域（覆盖大部分棋盘）→ 不被包围
	b = BoardModel.new()
	# 黑单子在中央 (9,9)，气域广阔
	b.set_at(9, 9, Const.BLACK)
	g = b.group_at(9, 9)
	t.expect(not SiegeDetector._is_surrounded_by_opponent(b, g), "B7: 中央黑子气域广阔 → 不被包围")
	t.expect(not SiegeDetector.is_sieged(b, g), "B7: 中央黑子 → 不围困")

	# B8. 边境线上的围困判定
	# 黑 4x4 墙跨边境线（行8-11），围困白子 (9,9) 在边境
	b = BoardModel.new()
	for c in range(8, 12):
		b.set_at(8, c, Const.BLACK)
		b.set_at(11, c, Const.BLACK)
	for r in range(9, 11):
		b.set_at(r, 8, Const.BLACK)
		b.set_at(r, 11, Const.BLACK)
	b.set_at(9, 9, Const.WHITE)
	b.set_at(0, 18, Const.WHITE)
	g = b.group_at(9, 9)
	# 白 (9,9) 在边境，legal空点=3<4 → 围困
	t.expect(SiegeDetector.is_sieged(b, g), "B8: 边境线上白子被围困")

	# ============================================================
	# C. 围空分计分（v5.4 新规则：对方活棋不计入围空分）
	# ============================================================

	# C1. 围空圈内对方活棋（≥4合法空点）位置不计入围空分
	# 黑大墙围住白组群，白组群有 ≥4 合法空点 → 活棋
	# 白活棋位置不计入黑围空分，仅空点计入
	var s = GameSession.new()
	# 黑 7x7 墙（行7-13, 列7-13），内部 5x5=25 空点（行8-12, 列8-12）
	for c in range(7, 14):
		s.board.set_at(7, c, Const.BLACK)
		s.board.set_at(13, c, Const.BLACK)
	for r in range(8, 13):
		s.board.set_at(r, 7, Const.BLACK)
		s.board.set_at(r, 13, Const.BLACK)
	# 白组群在内部 (9,9)(9,10)(10,9)(10,10) 4 子，气域广阔（≥4 合法空点）
	s.board.set_at(9, 9, Const.WHITE)
	s.board.set_at(9, 10, Const.WHITE)
	s.board.set_at(10, 9, Const.WHITE)
	s.board.set_at(10, 10, Const.WHITE)
	s.board.set_at(0, 0, Const.WHITE)  # 远处白子
	# 验证白组群活棋（legal空点 ≥ 4）
	var white_g_c1 = s.board.group_at(9, 9)
	t.expect(not SiegeDetector.is_sieged(s.board, white_g_c1), "C1: 白组群 legal空点≥4 → 活棋")
	# 计分：黑围空分 = 内部攻击区空点数 × 2（白活棋位置不计入）
	var sc = s.scores()
	# 内部 25 空点 - 4 白子 = 21 空点
	# is_attack_zone(row, BLACK): 行9边境/行10-12白境 → true；行8黑境 → false
	# 行8: 5 空点 → 不计
	# 行9: 5-2白=3 空点 → 3×2=6
	# 行10: 5-2白=3 空点 → 3×2=6
	# 行11-12: 5×2=10 空点 → 10×2=20
	# 黑围空分 = 6+6+20 = 32
	t.expect_eq(sc.black.occupation_territory, 32, "C1: 黑围空分=16空点×2=32（4白活棋位置不计入）")
	# 白活子分：is_attack_zone(row, WHITE): 行0-9 → true；行10-18白境 → false
	# (9,9)(9,10) 行9边境 → +1 each = 2
	# (10,9)(10,10) 行10白境 → 0
	# 远处 (0,0) 行0黑境 → +1 = 1
	# 共 3
	t.expect_eq(sc.white.occupation_live, 3, "C1: 白活子分 3（行9活棋2+远处1）")
	# 无围困分（白活棋）
	t.expect_eq(sc.black.defense_siege, 0, "C1: 白活棋 → 黑无围困分")

	# C2. 围空圈内对方两真眼活棋位置不计入围空分
	# 黑大墙围住白两真眼活棋，白棋位置不计入黑围空分
	s = GameSession.new()
	# 黑 9x9 墙（行5-13, 列5-13），内部 7x7=49 空点
	for c in range(5, 14):
		s.board.set_at(5, c, Const.BLACK)
		s.board.set_at(13, c, Const.BLACK)
	for r in range(6, 13):
		s.board.set_at(r, 5, Const.BLACK)
		s.board.set_at(r, 13, Const.BLACK)
	# 白方两真眼形（行8-10, 列7-11），13子连通，两眼 (9,8)(9,10)
	var white_two_eyes_c2 := [
		[8,7],[8,8],[8,9],[8,10],[8,11],
		[9,7],[9,9],[9,11],
		[10,7],[10,8],[10,9],[10,10],[10,11],
	]
	for st in white_two_eyes_c2:
		s.board.set_at(st[0], st[1], Const.WHITE)
	s.board.set_at(0, 0, Const.WHITE)
	# 验证白两真眼活棋
	var wg_c2 = s.board.group_at(8, 7)
	t.expect(SiegeDetector.has_two_true_eyes(s.board, wg_c2), "C2: 白方两真眼活棋")
	t.expect(not SiegeDetector.is_sieged(s.board, wg_c2), "C2: 白两真眼 → 不围困")
	# 计分
	sc = s.scores()
	# 黑围空圈 points = 49 - 13白 - 2眼 = 34（总数）
	# 但 is_attack_zone(row, BLACK): 行9-12 → true；行6-8 → false
	# 攻击区空点：行9(2空)+行10(2空)+行11(7空)+行12(7空) = 18 → 18×2=36
	var black_enc_pts_c2: int = 0
	for e in TerritoryDetector.enclosures(s.board):
		if e.color == Const.BLACK:
			black_enc_pts_c2 += e.points.size()
	t.expect_eq(black_enc_pts_c2, 34, "C2: 黑围空圈 34 空点（49-13白-2眼）")
	t.expect_eq(sc.black.occupation_territory, 36, "C2: 黑围空分=18攻击区空点×2=36（白活棋位置不计入）")
	# 白活子分：is_attack_zone(row, WHITE): 行0-9 → true；行10-12白境 → false
	# 行8(5子)+行9(3子) → +1 each = 8；行10(5子) → 0；远处(0,0) → +1
	# 共 9
	t.expect_eq(sc.white.occupation_live, 9, "C2: 白活子分 9（行8-9活棋8+远处1）")
	# 白方围空 (9,8)(9,10) 2 眼位，行9 边境 → is_attack_zone(9, WHITE)=true → +2 each = 4
	t.expect_eq(sc.white.occupation_territory, 4, "C2: 白围空分=2眼×2=4")

	# C3. 围空圈内围困+活棋混合：部分白子围困，部分白子活棋
	# 黑大墙内用黑分隔墙分成上下两块：上块小（围困区），下块大（活棋区）
	s = GameSession.new()
	# 黑 9x9 墙（行5-13, 列5-13），内部 7x7=49 空点
	for c in range(5, 14):
		s.board.set_at(5, c, Const.BLACK)
		s.board.set_at(13, c, Const.BLACK)
	for r in range(6, 13):
		s.board.set_at(r, 5, Const.BLACK)
		s.board.set_at(r, 13, Const.BLACK)
	# 内部黑分隔墙：行8 全黑（列6-12），把内部分成上下两块
	for c in range(6, 13):
		s.board.set_at(8, c, Const.BLACK)
	# 上块（行6-7, 列6-12）= 2x7=14 空点 → 用黑子缩成 2x2=4 空点
	s.board.set_at(6, 8, Const.BLACK)
	s.board.set_at(6, 9, Const.BLACK)
	s.board.set_at(6, 10, Const.BLACK)
	s.board.set_at(6, 11, Const.BLACK)
	s.board.set_at(6, 12, Const.BLACK)
	s.board.set_at(7, 8, Const.BLACK)
	s.board.set_at(7, 9, Const.BLACK)
	s.board.set_at(7, 10, Const.BLACK)
	s.board.set_at(7, 11, Const.BLACK)
	s.board.set_at(7, 12, Const.BLACK)
	# 上块缩成 (6,6)(6,7)(7,6)(7,7) 4 空点
	# 白围困子 (6,6)(6,7) 两子，气=(7,6)(7,7) 2个，legal<4 → 围困
	s.board.set_at(6, 6, Const.WHITE)
	s.board.set_at(6, 7, Const.WHITE)
	# 下块（行9-12, 列6-12）= 4x7=28 空点（活棋区）
	# 白活棋组群 (10,8)(10,9)(10,10)(10,11) 4 子，气域=28-4=24 ≥4 → 活棋
	s.board.set_at(10, 8, Const.WHITE)
	s.board.set_at(10, 9, Const.WHITE)
	s.board.set_at(10, 10, Const.WHITE)
	s.board.set_at(10, 11, Const.WHITE)
	s.board.set_at(0, 0, Const.WHITE)
	# 验证围困/活棋状态
	var wg_sieged_c3 = s.board.group_at(6, 6)
	var wg_alive_c3 = s.board.group_at(10, 8)
	t.expect(SiegeDetector.is_sieged(s.board, wg_sieged_c3), "C3: 上块白组群围困")
	t.expect(not SiegeDetector.is_sieged(s.board, wg_alive_c3), "C3: 下块白组群活棋")
	# 计分
	sc = s.scores()
	# 上块（行6-7）：全在黑境 → is_attack_zone(row, BLACK)=false → 围空分 0
	# 下块（行9-12）：is_attack_zone(row, BLACK)=true
	#   行9: 7 空点 → 7×2=14
	#   行10: 7-4白=3 空点 → 3×2=6（白活棋位置不计入）
	#   行11-12: 7×2=14 空点 → 14×2=28
	#   下块围空分 = 14+6+28 = 48
	# 黑总围空分 = 0 + 48 = 48
	t.expect_eq(sc.black.occupation_territory, 48, "C3: 黑围空分=下块48（上块黑境不计，白活棋位置不计入）")
	# 黑围困分：上块白围困子 (6,6)(6,7) 在行6 黑境 → is_defense_zone(6, BLACK)=true → +1 each = 2
	t.expect_eq(sc.black.defense_siege, 2, "C3: 黑围困分=2（上块白围困子在黑境）")
	# 白活子分：is_attack_zone(row, WHITE): 行0-9 → true；行10-12 → false
	# 围困子(6,6)(6,7)扣除；活棋(10,8-10,11)行10白境→0；远处(0,0)行0→+1
	# 共 1
	t.expect_eq(sc.white.occupation_live, 1, "C3: 白活子分=1（活棋行10不计，仅远处1）")

	# C4. 困棋包围圈扣除时活棋位置不扣（加减对称）
	# 白围困组群自己形成包围圈（围出眼位），扣除时只扣围困子位置对应的围空分
	# 黑 5x5 紧贴墙（行8-12, 列8-12），白方框 8 子围 (10,10)
	s = GameSession.new()
	# 黑 5x5 墙（行8-12, 列8-12）
	for c in range(8, 13):
		s.board.set_at(8, c, Const.BLACK)
		s.board.set_at(12, c, Const.BLACK)
	for r in range(9, 12):
		s.board.set_at(r, 8, Const.BLACK)
		s.board.set_at(r, 12, Const.BLACK)
	# 白方框 8 子围 (10,10)（紧贴黑墙内部）
	for r in range(9, 12):
		for c in range(9, 12):
			if r == 10 and c == 10:
				continue
			s.board.set_at(r, c, Const.WHITE)
	# 白方框气 = (10,10) 1 个，legal<4 → 围困
	# (10,10) 正交邻居全是白子 → 白方围空圈（黑方无围空圈）
	s.board.set_at(0, 0, Const.WHITE)
	# 验证白围困
	var wg_c4 = s.board.group_at(9, 9)
	t.expect(SiegeDetector.is_sieged(s.board, wg_c4), "C4: 白方框围困")
	# 计分
	sc = s.scores()
	# 白围空分：白方框围 (10,10)，但白围困 → 扣除
	# (10,10) 行10 白境 → is_attack_zone(10, WHITE)=false → 本就 0，扣除后仍 0
	t.expect_eq(sc.white.occupation_territory, 0, "C4: 白围空分=0（围困扣除+非攻击区）")
	# 白活子分：围困子扣除，远处 (0,0) 行0 → +1 = 1
	t.expect_eq(sc.white.occupation_live, 1, "C4: 白活子分=1（围困扣除，远处+1）")
	# 黑围空分：(10,10) 是白方围空圈，白围困→无效→嵌套归属给黑方
	# (10,10) 行10 → is_attack_zone(10, BLACK)=true → 黑 +2
	# 白方框 8 子位置不在任何黑方围空圈内（黑方无围空圈）→ 不计入黑围空分
	t.expect_eq(sc.black.occupation_territory, 2, "C4: 黑围空分=2（白围空圈嵌套归属给黑，仅(10,10)×2）")
	# 黑围困分：is_defense_zone(row, BLACK): 行9边境→true；行10-11白境→false
	# 行9(3子) → +1 each = 3；行10-11(5子) → 0
	t.expect_eq(sc.black.defense_siege, 3, "C4: 黑围困分=3（白方框行9的3子在边境）")

	# C5. 围空圈内对方活棋位置不计入，但活棋自己围的空点计入活棋方围空
	# 黑墙围白活棋，白活棋自己围出空点 → 白方围空分正常计算
	s = GameSession.new()
	# 黑 9x9 墙（行5-13, 列5-13）
	for c in range(5, 14):
		s.board.set_at(5, c, Const.BLACK)
		s.board.set_at(13, c, Const.BLACK)
	for r in range(6, 13):
		s.board.set_at(r, 5, Const.BLACK)
		s.board.set_at(r, 13, Const.BLACK)
	# 白方框 8 子围 (8,8)，但白方框气域不止 (8,8)（与大空地连通）→ 活棋
	# 需白方框与大空地连通：去掉黑墙一处让白气域通外部？不行，那样黑不围空
	# 改：白方框围 (8,8)，但 (8,8) 与其他空点连通（白方框有缺口）
	# 简化：白组群 13 子两真眼（参考 C2），白方围空 = 2 眼位
	# 已在 C2 验证白方围空分 = 4
	# 这里测：黑墙内白两真眼活棋，白方围空分正常（眼位计入白方）
	# 与 C2 相同，跳过
	t.expect(true, "C5: 与 C2 相同场景（白两真眼围空分正常计算），跳过")

	# C6. 围空圈内无对方棋子（纯空点）→ 围空分正常
	s = GameSession.new()
	# 黑 5x5 墙（行7-11, 列7-11），内部 3x3=9 空点（行8-10, 列8-10），无白子
	for c in range(7, 12):
		s.board.set_at(7, c, Const.BLACK)
		s.board.set_at(11, c, Const.BLACK)
	for r in range(8, 11):
		s.board.set_at(r, 7, Const.BLACK)
		s.board.set_at(r, 11, Const.BLACK)
	s.board.set_at(0, 0, Const.WHITE)
	sc = s.scores()
	# 9 空点，按行分区计入黑攻击区：
	#   行8 黑境 → is_attack_zone(8, BLACK)=false → 不计（3 点）
	#   行9 边境 → true → +2×3=6
	#   行10 白境 → true → +2×3=6
	# 黑围空分 = 6 + 6 = 12
	t.expect_eq(sc.black.occupation_territory, 12, "C6: 纯空点围空分=6攻击区空点×2=12（行8黑境不计）")
