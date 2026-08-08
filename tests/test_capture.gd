extends RefCounted
# 吃子/自杀/合法性 测试

func run(t: TestFramework) -> void:
	t.suite("吃子与合法性")

	# 1. 单子提吃
	var b := BoardModel.new()
	b.set_at(0, 1, Const.WHITE)
	b.set_at(1, 0, Const.BLACK)
	b.set_at(1, 2, Const.BLACK)
	# (0,0) 角落白子，黑下 (0,0) 邻？实际让白在 (1,1)，黑四周围
	b = BoardModel.new()
	b.set_at(0, 1, Const.BLACK)
	b.set_at(1, 0, Const.BLACK)
	var r = GoRules.try_move(b, 0, 0, Const.WHITE)
	t.expect(not r.legal, "角落白下(0,0)被黑两子夹击应自杀非法")

	# 2. 正常提子：白子(1,1)被黑四周围，黑下(1,1)最后一气
	b = BoardModel.new()
	# 白在 (5,5)，黑占 (4,5)(6,5)(5,4)，黑下 (5,6) 提白
	b.set_at(5, 5, Const.WHITE)
	b.set_at(4, 5, Const.BLACK)
	b.set_at(6, 5, Const.BLACK)
	b.set_at(5, 4, Const.BLACK)
	r = GoRules.try_move(b, 5, 6, Const.BLACK)
	t.expect(r.legal, "黑下(5,6)合法")
	t.expect_eq(r.captured.size(), 1, "提一子")
	t.expect_eq(b.get_at(5, 5), Const.EMPTY, "白子被提走")
	t.expect_eq(b.get_at(5, 6), Const.BLACK, "黑子留下")

	# 3. 多子组提吃
	b = BoardModel.new()
	# 白两子 (5,5)(5,6)，黑包围
	b.set_at(5, 5, Const.WHITE)
	b.set_at(5, 6, Const.WHITE)
	b.set_at(4, 5, Const.BLACK)
	b.set_at(4, 6, Const.BLACK)
	b.set_at(6, 5, Const.BLACK)
	b.set_at(6, 6, Const.BLACK)
	b.set_at(5, 4, Const.BLACK)
	# 黑下 (5,7) 提白两子
	r = GoRules.try_move(b, 5, 7, Const.BLACK)
	t.expect(r.legal, "黑下(5,7)合法")
	t.expect_eq(r.captured.size(), 2, "提两子")
	t.expect_eq(b.get_at(5, 5), Const.EMPTY, "白(5,5)被提")
	t.expect_eq(b.get_at(5, 6), Const.EMPTY, "白(5,6)被提")

	# 4. 自杀但可提子 → 合法（白下(0,0)提黑两子）
	# 构造：B(0,1) B(1,0) 各仅剩 (0,0) 一气（其余邻为白），白下(0,0) 提两黑
	b = BoardModel.new()
	b.set_at(0, 1, Const.BLACK)
	b.set_at(1, 0, Const.BLACK)
	b.set_at(0, 2, Const.WHITE)
	b.set_at(1, 1, Const.WHITE)
	b.set_at(2, 0, Const.WHITE)
	# 白(0,0)：邻 (0,1)黑 (1,0)黑，自身无气，但落子后两黑子也无气 → 提黑
	r = GoRules.try_move(b, 0, 0, Const.WHITE)
	t.expect(r.legal, "白下(0,0)自杀但提黑两子应合法")
	t.expect_eq(r.captured.size(), 2, "提黑两子")
	t.expect_eq(b.get_at(0, 0), Const.WHITE, "白子留下")
	t.expect_eq(b.get_at(0, 1), Const.EMPTY, "黑(0,1)被提")
	t.expect_eq(b.get_at(1, 0), Const.EMPTY, "黑(1,0)被提")

	# 5. 占点非法
	b = BoardModel.new()
	b.set_at(5, 5, Const.BLACK)
	r = GoRules.try_move(b, 5, 5, Const.WHITE)
	t.expect(not r.legal, "已有棋子处非法")

	# 6. group_at / liberties
	b = BoardModel.new()
	b.set_at(5, 5, Const.BLACK)
	b.set_at(5, 6, Const.BLACK)
	var g = b.group_at(5, 5)
	t.expect_eq(g.stones.size(), 2, "两子组群")
	var libs = b.liberties(g.stones)
	t.expect(libs.size() > 0, "组群有气")

	# 7. has_any_legal_move
	b = BoardModel.new()
	t.expect(GoRules.has_any_legal_move(b, Const.BLACK), "空盘有合法点")
