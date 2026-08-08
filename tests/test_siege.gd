extends RefCounted
# 围困判定 测试（眼位+连通启发式）

func run(t: TestFramework) -> void:
	t.suite("围困判定")

	# 1. 孤子开阔地 → 不围困
	var b := BoardModel.new()
	b.set_at(9, 9, Const.BLACK)  # 边境线中央孤子
	var g = b.group_at(9, 9)
	t.expect(not SiegeDetector.is_sieged(b, g), "开阔地孤子不围困")

	# 2. 黑子被白完全包围，0 眼 → 围困
	b = BoardModel.new()
	b.set_at(5, 5, Const.BLACK)
	for n in [[4,5],[6,5],[5,4],[5,6]]:
		b.set_at(n[0], n[1], Const.WHITE)
	g = b.group_at(5, 5)
	t.expect(SiegeDetector.is_sieged(b, g), "黑单子被白四面包围无眼→围困")

	# 3. 黑两真眼活棋 → 不围困
	# 构造：黑组群有 2 个独立真眼，外围被白包围
	b = BoardModel.new()
	# 经典两眼形：黑占一圈围出两个独立空点
	# 简化构造 7 子形：
	#   . B .        (0,1)空眼? 不对，需黑围
	# 用 5x5 区域：黑围出 (1,1) 和 (1,3) 两个独立眼
	# 黑子：(0,0)(0,1)(0,2)(0,3)(0,4)(1,0)(1,4)(2,0)(2,2)(2,4)(3,0)(3,1)(3,2)(3,3)(3,4)
	# 空眼 (1,1)(1,2)(1,3)? 那是连通的 3 空点，不是 2 眼
	# 改：两个独立单点眼
	# 黑子布局（中心两眼形）：
	#  B B B B B
	#  B . B . B
	#  B B B B B
	# 空点 (1,1) 和 (1,3)，被黑分隔
	var black_stones := [
		[0,0],[0,1],[0,2],[0,3],[0,4],
		[1,0],[1,2],[1,4],
		[2,0],[2,1],[2,2],[2,3],[2,4],
	]
	for s in black_stones:
		b.set_at(s[0], s[1], Const.BLACK)
	g = b.group_at(1, 0)  # 黑组群（应连通）
	t.expect_eq(g.stones.size(), 13, "黑两眼形 13 子连通")
	t.expect(not SiegeDetector.is_sieged(b, g), "两真眼活棋不围困")

	# 4. 黑子被白包围，1 眼 → 围困
	b = BoardModel.new()
	# 黑 4 子围 (1,1) 单眼，外围白
	# B B B
	# B . B
	# B B B   全黑，再外围白
	b.set_at(0,0,Const.BLACK); b.set_at(0,1,Const.BLACK); b.set_at(0,2,Const.BLACK)
	b.set_at(1,0,Const.BLACK); b.set_at(1,2,Const.BLACK)
	b.set_at(2,0,Const.BLACK); b.set_at(2,1,Const.BLACK); b.set_at(2,2,Const.BLACK)
	# 白外围：包住这 3x3
	for r in range(-1, 4):
		for c in range(-1, 4):
			if b.in_bounds(r, c) and b.get_at(r, c) == Const.EMPTY:
				# 仅放紧邻 3x3 的白子
				if r == -1 or r == 3 or c == -1 or c == 3:
					if b.in_bounds(r, c):
						b.set_at(r, c, Const.WHITE)
	# 修正：r/c 越界跳过
	b.set_at(0,3,Const.WHITE); b.set_at(2,3,Const.WHITE)
	# (1,1) 为黑单眼
	g = b.group_at(1, 0)
	t.expect(SiegeDetector.is_sieged(b, g), "黑单眼被白包围→围困")

	# 5. 无两眼组群（即使附近有友军）→ has_two_true_eyes=false
	#    新规则：围困 = 围空圈内 + 无两眼；友军连通性不影响两眼判定
	b = BoardModel.new()
	b.set_at(5, 5, Const.BLACK)
	b.set_at(4, 5, Const.WHITE)
	b.set_at(6, 5, Const.WHITE)
	b.set_at(5, 4, Const.WHITE)
	# (5,6) 留空，远处有黑友军 (5,8)（不连通）
	b.set_at(5, 8, Const.BLACK)
	g = b.group_at(5, 5)
	# (5,5) 气域虽通向友军，但被白子阻隔无法形成眼空间 → 无两眼
	t.expect(not SiegeDetector.has_two_true_eyes(b, g), "无两眼→has_two_true_eyes=false（友军不影响判定）")

	# 6. 大眼空间(≥4合法空点)未做出两真眼 → 活棋（v4.1规则）
	# 规则v4.1：被包围但圈内可合法落子空点≥4 → 活棋
	# 黑 4x5 环（行0-3, 列0-4），内部 2x3=6 空点，外围白封堵
	b = BoardModel.new()
	for c in range(5):
		b.set_at(0, c, Const.BLACK)   # 顶边
		b.set_at(3, c, Const.BLACK)   # 底边
	for r in range(1, 3):
		b.set_at(r, 0, Const.BLACK)   # 左边
		b.set_at(r, 4, Const.BLACK)   # 右边
	# 外围白：封堵行4 与 列5（顶/左为棋盘边界）
	for c in range(5):
		b.set_at(4, c, Const.WHITE)
	for r in range(4):
		b.set_at(r, 5, Const.WHITE)
	g = b.group_at(0, 0)
	# 内部 2x3=6 空点 → legal空点≥4 → 活棋（即使未做出两真眼）
	t.expect(not SiegeDetector.is_sieged(b, g), "6点大眼空间≥4合法空点→活棋（v4.1）")

	# 6b. 小眼空间(<4合法空点)未做出两真眼 → 围困
	# 黑 3x3 环（行0-2, 列0-2），内部 1 空点(1,1)，外围白封堵
	b = BoardModel.new()
	for c in range(3):
		b.set_at(0, c, Const.BLACK)
		b.set_at(2, c, Const.BLACK)
	b.set_at(1, 0, Const.BLACK)
	b.set_at(1, 2, Const.BLACK)
	# 外围白：封堵行3 与 列3
	for c in range(3):
		b.set_at(3, c, Const.WHITE)
	for r in range(3):
		b.set_at(r, 3, Const.WHITE)
	g = b.group_at(0, 0)
	# 内部 1 空点(1,1) → legal空点=0（自杀禁着）< 4 → 围困
	t.expect(SiegeDetector.is_sieged(b, g), "1点小眼空间<4合法空点→围困")
