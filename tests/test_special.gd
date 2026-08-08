extends RefCounted
# 特种部队 测试

func run(t: TestFramework) -> void:
	t.suite("特种部队")

	# 1. 部署隐子真实占点
	var s := GameSession.new(Const.KOMI_DEFAULT, true)
	t.expect(s.special.can_deploy(Const.BLACK, 0), "黑可部署特种(开局)")
	var out = s.deploy_special(Const.BLACK, 5, 5)
	t.expect(out.ok, "部署成功")
	t.expect(s.special.has_hidden_at(Vector2i(5, 5)), "隐子存在")
	t.expect_eq(s.board.get_at(5, 5), Const.BLACK, "隐子在盘上为黑子(真实占点)")
	t.expect_eq(s.special.uses_left(Const.BLACK), 1, "剩余1次")
	t.expect_eq(s.pieces_left(Const.BLACK), Const.PIECE_LIMIT, "部署不消耗兵力")

	# 2. 伏击：白落在黑隐子点 → 白战损 -1，隐子现形，白子未落
	s = GameSession.new(Const.KOMI_DEFAULT, true)
	s.deploy_special(Const.BLACK, 5, 5)
	# 轮到白
	out = s.play_move(Const.WHITE, 5, 5)  # 撞隐子
	t.expect(out.ambush, "触发伏击")
	t.expect_eq(s.counters[Const.WHITE].ambushed, 1, "白伏击战损 +1计数")
	t.expect_eq(s.board.get_at(5, 5), Const.BLACK, "隐子仍在(现形)")
	# 白子未落（盘上无白子在5,5）
	# 战损 -1
	var sc = s.scores()
	t.expect_eq(sc.white.casualty_ambush, -1, "白伏击战损 -1")
	# 隐子现形
	t.expect(not s.special.hidden_at(Vector2i(5, 5)).is_empty() == false, "隐子已现形")  # hidden_at 返回空=已现形
	t.expect(not s.special.get_special_at(Vector2i(5, 5)).hidden, "现形标记")

	# 3. 邻接暴露：白落在隐子四邻 → 隐子现形，无伏击
	s = GameSession.new(Const.KOMI_DEFAULT, true)
	s.deploy_special(Const.BLACK, 5, 5)
	out = s.play_move(Const.WHITE, 5, 6)  # 邻接
	t.expect(not out.ambush, "邻接非伏击")
	t.expect(out.revealed.size() >= 1, "隐子因邻接现形")
	t.expect_eq(s.board.get_at(5, 6), Const.WHITE, "白子正常落下")

	# 4. 冷却：连续部署不可
	s = GameSession.new(Const.KOMI_DEFAULT, true)
	s.deploy_special(Const.BLACK, 5, 5)  # ply 0→1
	# 轮白，白虚手让回合推进
	s.play_move(Const.WHITE, 0, 0)  # ply 1→2
	# 轮黑 ply2，距上次0差2 <4 → 不可部署
	t.expect(not s.special.can_deploy(Const.BLACK, s.ply), "冷却内不可部署")
	s.play_move(Const.BLACK, 0, 1)  # ply2→3
	s.play_move(Const.WHITE, 0, 2)  # ply3→4
	# ply4 距0差4 → 可部署
	t.expect(s.special.can_deploy(Const.BLACK, s.ply), "冷却后可部署")

	# 5. 隐子被提吃 → 战损 -6
	s = GameSession.new(Const.KOMI_DEFAULT, true)
	# 黑隐子在(5,5)，白包围提吃
	s.deploy_special(Const.BLACK, 5, 5)  # ply0→1, 轮白
	# 白下(4,5)(6,5)(5,4) 后 (5,6)提黑隐子；中间黑随便下
	s.play_move(Const.WHITE, 4, 5)  # ply1→2
	s.play_move(Const.BLACK, 0, 0)  # ply2→3
	s.play_move(Const.WHITE, 6, 5)  # ply3→4
	s.play_move(Const.BLACK, 0, 1)  # ply4→5
	s.play_move(Const.WHITE, 5, 4)  # ply5→6
	s.play_move(Const.BLACK, 0, 2)  # ply6→7
	var out2 = s.play_move(Const.WHITE, 5, 6)  # 提黑(5,5)
	t.expect(out2.ok, "白提黑隐子合法")
	t.expect_eq(out2.captures.size(), 1, "提1子")
	t.expect_eq(s.counters[Const.BLACK].special_lost, 1, "黑特种损失计数1")
	sc = s.scores()
	t.expect_eq(sc.black.casualty_special, -6, "黑特种战损 -6")
	# 白歼灭分：提吃发生在白防御区(白境/边境)。 (5,5)行5<9=黑境≠白防御区 → 无歼灭分
	t.expect_eq(sc.white.defense_annihilate, 0, "白在黑境提子无歼灭分(非防御区)")

	# 6. 到期现形（20回合=40 ply）：直接调用 check_expiry 验证
	s = GameSession.new(Const.KOMI_DEFAULT, true)
	s.deploy_special(Const.BLACK, 5, 5)  # ply0, expire_ply=40
	t.expect(s.special.has_hidden_at(Vector2i(5,5)), "隐子隐藏")
	# 到期前不应现形
	var pre = s.special.check_expiry(39)
	t.expect_eq(pre.size(), 0, "39 ply 未到期")
	t.expect(s.special.has_hidden_at(Vector2i(5,5)), "39 ply 仍隐藏")
	# 到期现形
	var expired = s.special.check_expiry(40)
	t.expect_eq(expired.size(), 1, "40 ply 到期现形 1 子")
	t.expect(not s.special.has_hidden_at(Vector2i(5,5)), "40 ply后隐子到期现形")
