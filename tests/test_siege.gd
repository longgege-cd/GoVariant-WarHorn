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

	# 3. 黑两真眼活棋 → 不围困（真场景：被白完全包围 + 黑做出两个独立真眼）
	# 黑组群 rows 6-8 / cols 1-7（17子），眼位 (7,2) 与 (7,6) 被黑四邻围死
	# 白墙 row5/row9/col0/col8 完全封闭，黑组群全部气 = 两个眼位
	b = BoardModel.new()
	for r in range(6, 9):
		for c in range(1, 8):
			if r == 7 and (c == 2 or c == 6):
				continue  # 眼位留空
			b.set_at(r, c, Const.BLACK)
	for c in range(0, 9):
		b.set_at(5, c, Const.WHITE)
		b.set_at(9, c, Const.WHITE)
	for r in range(5, 10):
		b.set_at(r, 0, Const.WHITE)
		b.set_at(r, 8, Const.WHITE)
	g = b.group_at(6, 1)
	t.expect_eq(g.stones.size(), 19, "两真眼黑组群 19 子连通")
	# 场景构造验证：确实被白完全包围、确实做出两个真眼
	t.expect(SiegeDetector._is_surrounded_by_opponent(b, g), "两真眼黑组群被白完全包围")
	t.expect(SiegeDetector.has_two_true_eyes(b, g), "黑组群做出两个独立真眼")
	t.expect(not SiegeDetector.is_sieged(b, g), "被包围但两真眼活棋不围困")

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

	# 7. 角部包围：组群唯一气是角部边缘空点(0,0) → 应被包围/围困
	# 白(0,1)(1,0)(1,1) 被黑(0,2)(1,2)(2,0)(2,1)(2,2) 完全封闭
	# 唯一气 = 角部(0,0)（边缘空点），旧算法误判"触及边缘→不被包围"
	b = BoardModel.new()
	b.set_at(0, 1, Const.WHITE); b.set_at(1, 0, Const.WHITE); b.set_at(1, 1, Const.WHITE)
	b.set_at(0, 2, Const.BLACK); b.set_at(1, 2, Const.BLACK); b.set_at(2, 2, Const.BLACK)
	b.set_at(2, 0, Const.BLACK); b.set_at(2, 1, Const.BLACK)
	g = b.group_at(0, 1)
	t.expect(SiegeDetector._is_surrounded_by_opponent(b, g), "角部白子唯一气(0,0)被黑+边缘封闭→被包围")
	t.expect(SiegeDetector.is_sieged(b, g), "角部白子被围且空点<4→围困")

	# 7b. 角部圈内含 2 个相邻边缘空点：白(1,1) 唯一气(0,1) 也在边缘
	b = BoardModel.new()
	b.set_at(1, 1, Const.WHITE)
	b.set_at(1, 0, Const.BLACK); b.set_at(0, 2, Const.BLACK); b.set_at(1, 2, Const.BLACK)
	b.set_at(2, 0, Const.BLACK); b.set_at(2, 1, Const.BLACK); b.set_at(2, 2, Const.BLACK)
	g = b.group_at(1, 1)
	t.expect(SiegeDetector.is_sieged(b, g), "角部白子唯一气(0,1)贴边被封闭→围困")

	# 8. 角部贴边但未被封闭 → 活棋（气域触及真外部）
	b = BoardModel.new()
	b.set_at(0, 0, Const.WHITE)
	b.set_at(1, 1, Const.BLACK)
	g = b.group_at(0, 0)
	t.expect(not SiegeDetector.is_sieged(b, g), "角部白子气域(0,1)(1,0)连通外部→活棋")

	# 9. 圈内合法落子点：提吃点计入（黑落(1,1)提白后存活）
	# 黑 7 子环 + 白(0,1) 嵌环上围 (1,1)，环外白墙封死 → 黑白均唯一气 (1,1)
	b = BoardModel.new()
	var black_ring := [[0,0],[0,2],[1,0],[1,2],[2,0],[2,1],[2,2]]
	for s in black_ring:
		b.set_at(s[0], s[1], Const.BLACK)
	b.set_at(0, 1, Const.WHITE)
	for c in range(3):
		b.set_at(3, c, Const.WHITE)
	for r in range(3):
		b.set_at(r, 3, Const.WHITE)
	g = b.group_at(0, 0)
	# (1,1) 填黑可提白(0,1)后存活 → 合法 → count=1（可提吃点计入）
	t.expect(SiegeDetector._is_legal_move(b, 1, 1, Const.BLACK), "9: 提吃后存活→可合法落子")
	t.expect_eq(SiegeDetector.count_legal_empty_points(b, g), 1, "9: 圈内可提吃点计入 count=1")

	# 10. 多个对方组群同时被提 → 落子合法
	# 落子点(1,1) 四邻 (0,1)(1,0)(1,2)(2,1) 为 4 个独立白子，各自唯一气=(1,1)
	b = BoardModel.new()
	for p in [[0,1],[1,0],[1,2],[2,1]]:
		b.set_at(p[0], p[1], Const.WHITE)
	for s in [[0,0],[0,2],[0,3],[1,3],[2,3],[2,2],[2,0],[3,1],[3,0],[3,2]]:
		b.set_at(s[0], s[1], Const.BLACK)
	# 4 个白子各自唯一气 (1,1)，黑落 (1,1) 同时提 4 子
	t.expect(SiegeDetector._is_legal_move(b, 1, 1, Const.BLACK), "10: 黑落(1,1)同时提4白子→合法")

	# 11. 对方组群有外气 → 落子自杀非法（禁入点）
	# 落子点(1,1) 四邻全白且白各有外气 → 黑落 (1,1) 无气且不能提 → 非法
	b = BoardModel.new()
	for p in [[0,1],[1,0],[1,2],[2,1]]:
		b.set_at(p[0], p[1], Const.WHITE)
	t.expect(not SiegeDetector._is_legal_move(b, 1, 1, Const.BLACK), "11: 四白包围白有外气→自杀非法")

	# 12. 两个同色组群共享两个禁入点 → 各自两真眼活棋（规则6.4：眼位四邻可为多组群）
	# 10 路棋盘布局（rows 5-9, cols 4-9）：
	#      c4  c5  c6  c7  c8  c9
	# r5:  W   W   W   W   W   W
	# r6:  W   A   A   W   W   W
	# r7:  W   A   A   A   A   W
	# r8:  W   A   A   A   P1  B
	# r9:  W   A   A   P2  B   B
	# 组群A 左下方（11 子），组群B 右下角（3 子），共享禁入点 P1=(8,8) P2=(9,7)
	# P1 四邻 = A,B,A,B；P2 四邻 = A,B,A（下贴边）
	# A 的气 = {P1,P2}，B 的气 = {P1,P2} → 白下 P1/P2 均自杀（禁入点），两块棋杀不死
	# → 各有两个真眼（共享禁入点）→ 活棋。旧规则要求四邻全为同一组群 → 误判围困
	b = BoardModel.new(10)
	for p in [[6,5],[6,6],[7,5],[7,6],[7,7],[7,8],[8,5],[8,6],[8,7],[9,5],[9,6]]:
		b.set_at(p[0], p[1], Const.BLACK)   # 组群A
	for p in [[8,9],[9,8],[9,9]]:
		b.set_at(p[0], p[1], Const.BLACK)   # 组群B
	# 白墙完整封闭外围，仅留两个共享点 P1/P2 为气
	for c in range(4, 10):
		b.set_at(5, c, Const.WHITE)
	for r in range(5, 10):
		b.set_at(r, 4, Const.WHITE)
	b.set_at(6, 7, Const.WHITE); b.set_at(6, 8, Const.WHITE); b.set_at(6, 9, Const.WHITE)
	b.set_at(7, 9, Const.WHITE)
	var ga = b.group_at(7, 5)
	var gb = b.group_at(8, 9)
	t.expect_eq(ga.stones.size(), 11, "12: 组群A 11 子连通")
	t.expect_eq(gb.stones.size(), 3, "12: 组群B 3 子连通")
	# 两个共享点均为白棋禁入点（下入自杀）
	t.expect(not SiegeDetector._is_legal_move(b, 8, 8, Const.WHITE), "12: 白下P1禁入点")
	t.expect(not SiegeDetector._is_legal_move(b, 9, 7, Const.WHITE), "12: 白下P2禁入点")
	# 放宽规则6.4后：眼位四邻可为多个同色组群 → 两个共享点都是真眼
	t.expect(SiegeDetector.has_two_true_eyes(b, ga), "12: 组群A 共享两禁入点→两真眼活棋")
	t.expect(SiegeDetector.has_two_true_eyes(b, gb), "12: 组群B 共享两禁入点→两真眼活棋")
	t.expect(not SiegeDetector.is_sieged(b, ga), "12: 组群A 不被围困（活棋）")
	t.expect(not SiegeDetector.is_sieged(b, gb), "12: 组群B 不被围困（活棋）")

	# 13. 死棋围不成有效包围圈（v6.2）：被围困棋子围住的组群应活
	# 三层方环（11 路棋盘，黑C 紧贴白B，无环带空间）：
	#   黑C 大环 row3-8×col3-8（活棋，环外有空点）
	#   白B 中环 row4-7×col4-7（被黑C 完全包围，唯一气=内部3空点<4，无两眼 → 围困）
	#   黑A 单子 (5,5) 在白B 环内（白B 死棋不作墙 → 黑A 气域可穿出到黑C 环内大空间 → 活）
	# 旧纯几何语义：黑A 被白B 包围 → 误判围困；v6.2 有效包围圈语义：白B 是死棋 → 黑A 活
	b = BoardModel.new(11)
	for c in range(3, 9):
		b.set_at(3, c, Const.BLACK); b.set_at(8, c, Const.BLACK)  # 黑C 大环上下
	for r in range(4, 8):
		b.set_at(r, 3, Const.BLACK); b.set_at(r, 8, Const.BLACK)  # 黑C 大环左右
	for c in range(4, 8):
		b.set_at(4, c, Const.WHITE); b.set_at(7, c, Const.WHITE)  # 白B 中环上下
	for r in range(5, 7):
		b.set_at(r, 4, Const.WHITE); b.set_at(r, 7, Const.WHITE)  # 白B 中环左右
	b.set_at(5, 5, Const.BLACK)  # 黑A 单子（白B 环内）
	var da13: Dictionary = SiegeDetector.solve_dead_alive(b)
	var a13_sieged := false
	var b13_sieged := false
	var c13_sieged := false
	for sg in da13.sieged:
		if sg.color == Const.WHITE:
			b13_sieged = true
		elif sg.stones.size() == 1 and sg.stones[0] == Vector2i(5, 5):
			a13_sieged = true
		else:
			c13_sieged = true
	t.expect(b13_sieged, "13: 白B 中环被黑C 有效包围→围困（死棋）")
	t.expect(not a13_sieged, "13: 黑A 被死棋白B 围住→活棋（v6.2 有效包围圈）")
	t.expect(not c13_sieged, "13: 黑C 大环活棋")
