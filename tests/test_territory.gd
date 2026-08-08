extends RefCounted
# 围空检测 测试
# 注意：TerritoryDetector 用「单色边界」规则（Go 标准地域算法）。
# 当棋盘仅有一色棋子时，大片空地会因边界只触该色而被误判为围空。
# 故测试中需放置远处对手子，使「外部」边界含两色 → 不计围空，仅留真实包围圈。

func run(t: TestFramework) -> void:
	t.suite("围空检测")

	# 1. 黑八子围一格空 → 黑围空 1 点
	var b := BoardModel.new()
	b.set_at(0, 0, Const.BLACK)
	b.set_at(0, 2, Const.BLACK)
	b.set_at(2, 0, Const.BLACK)
	b.set_at(2, 2, Const.BLACK)
	b.set_at(0, 1, Const.BLACK)
	b.set_at(2, 1, Const.BLACK)
	b.set_at(1, 0, Const.BLACK)
	b.set_at(1, 2, Const.BLACK)
	b.set_at(10, 10, Const.WHITE)  # 远处白子，使外部边界含两色
	var encs = TerritoryDetector.enclosures(b)
	t.expect_eq(encs.size(), 1, "1 个围空")
	if encs.size() == 1:
		t.expect_eq(encs[0].color, Const.BLACK, "黑围空")
		t.expect_eq(encs[0].points.size(), 1, "1 个空点")

	# 2. 边界参与围空：黑在角落围 (0,0)
	b = BoardModel.new()
	b.set_at(0, 1, Const.BLACK)
	b.set_at(1, 0, Const.BLACK)
	b.set_at(1, 1, Const.BLACK)
	b.set_at(10, 10, Const.WHITE)  # 远处白子
	encs = TerritoryDetector.enclosures(b)
	t.expect_eq(encs.size(), 1, "角落围空 1 个")
	if encs.size() == 1:
		t.expect_eq(encs[0].color, Const.BLACK, "黑角落围空")
		t.expect_eq(encs[0].points.size(), 1, "角落 1 点")

	# 3. 两色边界 → 中立不计围空
	b = BoardModel.new()
	b.set_at(0, 1, Const.BLACK)
	b.set_at(1, 0, Const.WHITE)
	encs = TerritoryDetector.enclosures(b)
	t.expect_eq(encs.size(), 0, "两色边界空地不计围空")

	# 4. 大围空：黑在左上角围 3x3
	b = BoardModel.new()
	for i in range(4):
		b.set_at(3, i, Const.BLACK)  # 底边
		b.set_at(i, 3, Const.BLACK)  # 右边
	b.set_at(10, 10, Const.WHITE)  # 远处白子
	encs = TerritoryDetector.enclosures(b)
	t.expect_eq(encs.size(), 1, "左上 3x3 围空 1 个")
	if encs.size() == 1:
		t.expect_eq(encs[0].points.size(), 9, "3x3 = 9 空点")

	# 5. stone_participates_in_enclosure
	b = BoardModel.new()
	b.set_at(0, 1, Const.BLACK)
	b.set_at(1, 0, Const.BLACK)
	b.set_at(1, 1, Const.BLACK)
	b.set_at(10, 10, Const.WHITE)
	t.expect(TerritoryDetector.stone_participates_in_enclosure(b, 0, 1, Const.BLACK), "(0,1)黑参与围空")
	t.expect(not TerritoryDetector.stone_participates_in_enclosure(b, 5, 5, Const.BLACK), "空点(5,5)不参与")

	# 6. 围空圈内含被围困的对方棋子：黑方包围圈内有一颗被围困的白子
	#    内部空块边界含两色（黑墙 + 白子），白子被围困 → 计为黑围空，白子计入 stones_inside
	b = BoardModel.new()
	# 黑方 5x5 围墙（行 8-12，列 8-12 的外圈），内部 3x3 空地
	for c in range(8, 13):
		b.set_at(8, c, Const.BLACK)   # 顶边
		b.set_at(12, c, Const.BLACK)  # 底边
	for r in range(9, 12):
		b.set_at(r, 8, Const.BLACK)   # 左边
		b.set_at(r, 12, Const.BLACK)  # 右边
	# 白子放在内部角落 (9,9)，使其与黑墙相邻 → 被围困
	b.set_at(9, 9, Const.WHITE)
	# 远处孤立白子，使外部空块边界含两色（不计外部围空）
	b.set_at(0, 18, Const.WHITE)
	encs = TerritoryDetector.enclosures(b)
	t.expect_eq(encs.size(), 1, "含被围困白子的围空 1 个")
	if encs.size() == 1:
		t.expect_eq(encs[0].color, Const.BLACK, "黑围空（主色）")
		t.expect(encs[0].points.size() >= 6, "内部空点 >= 6")
		t.expect_eq(encs[0].get("stones_inside", []).size(), 1, "圈内 1 颗被围困白子")
		if encs[0].get("stones_inside", []).size() == 1:
			t.expect_eq(encs[0].stones_inside[0], Vector2i(9, 9), "被围困白子坐标 (9,9)")

	# 7. 围空圈内对方棋子做出两真眼 → 活棋
	#    v4.1：_collect_stones_inside 不做死活筛选，但要求组群所有气在围空圈内
	#    两真眼活棋的气域跨越多个独立空块 → 不在任何单一围空圈的 stones_inside 中
	#    构造：黑 7x7 围墙（行7-13, 列7-13），圈内白方 5x3 两真眼形
	#    白棋眼位 (10,9)(10,11) — 正交邻居全为白棋，对角也全为白棋
	b = BoardModel.new()
	for c in range(7, 14):
		b.set_at(7, c, Const.BLACK)
		b.set_at(13, c, Const.BLACK)
	for r in range(8, 13):
		b.set_at(r, 7, Const.BLACK)
		b.set_at(r, 13, Const.BLACK)
	# 白方 5x3 两真眼形（行9-11, 列8-12），13子连通，两眼 (10,9)(10,11)
	var white_two_eyes := [
		[9,8],[9,9],[9,10],[9,11],[9,12],
		[10,8],[10,10],[10,12],
		[11,8],[11,9],[11,10],[11,11],[11,12],
	]
	for s in white_two_eyes:
		b.set_at(s[0], s[1], Const.WHITE)
	b.set_at(0, 18, Const.WHITE)  # 远处白子，使外部边界含两色
	# 先验证白棋确实做出两真眼
	var wg = b.group_at(9, 8)
	t.expect_eq(wg.stones.size(), 13, "白方两真眼形 13 子连通")
	t.expect(SiegeDetector.has_two_true_eyes(b, wg), "白方两真眼形判定为活棋")
	# 活棋 → 不计入任何围空的 stones_inside
	encs = TerritoryDetector.enclosures(b)
	var total_stones_inside: int = 0
	for e in encs:
		total_stones_inside += e.get("stones_inside", []).size()
	t.expect_eq(total_stones_inside, 0, "两真眼活棋不计入 stones_inside")

	# 8. 边界含两色但多数色未形成封闭包围圈 → 不计围空（防止误判）
	b = BoardModel.new()
	# 黑白交错，没有形成封闭包围圈
	b.set_at(9, 8, Const.BLACK)
	b.set_at(9, 10, Const.WHITE)
	b.set_at(10, 9, Const.BLACK)
	b.set_at(8, 9, Const.WHITE)
	b.set_at(0, 18, Const.WHITE)
	encs = TerritoryDetector.enclosures(b)
	# 边界含两色，黑子未形成闭合曲线 → 不计围空
	t.expect_eq(encs.size(), 0, "多数色未形成封闭包围圈 → 不计围空")
