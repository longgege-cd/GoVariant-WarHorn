extends RefCounted
# 计分 测试

func run(t: TestFramework) -> void:
	t.suite("实时计分")

	# 1. 黑在白境活子 +1
	var s := GameSession.new()
	# 白境 = 行10-18。黑下 (10,10)
	var out = s.play_move(Const.BLACK, 10, 10)
	t.expect(out.ok, "黑下(10,10)合法")
	var sc = s.scores()
	t.expect_eq(sc.black.occupation_live, 1, "黑在白境活子 +1")
	t.expect_eq(sc.black.total(), 1, "黑总分 1")

	# 2. 黑在边境活子 +1
	s = GameSession.new()
	s.play_move(Const.BLACK, 9, 9)  # 边境
	sc = s.scores()
	t.expect_eq(sc.black.occupation_live, 1, "黑在边境活子 +1")

	# 3. 黑在己境(行0-8)活子 → 无占领分
	s = GameSession.new()
	s.play_move(Const.BLACK, 0, 0)  # 黑境
	sc = s.scores()
	t.expect_eq(sc.black.occupation_live, 0, "黑在己境无占领分")
	t.expect_eq(sc.black.total(), 0, "黑总分 0")

	# 4. 黑在白境围空 +2/点
	s = GameSession.new()
	# 黑在白境(行10-18)围一格空
	# 黑子 (10,10)(10,12)(11,10)(11,11)(11,12)(12,10)(12,11)(12,12) 围 (10,11)? 不对
	# 简化：黑在 (11,10)(11,12)(10,11)(12,11) 围中心 (11,11)? 需要黑围 (11,11)
	# 黑四子 (10,11)(12,11)(11,10)(11,12)，空 (11,11) 被围
	# 但需轮流落子；这里直接构造 session 盘面
	s = GameSession.new()
	s.board.set_at(10, 11, Const.BLACK)
	s.board.set_at(12, 11, Const.BLACK)
	s.board.set_at(11, 10, Const.BLACK)
	s.board.set_at(11, 12, Const.BLACK)
	sc = s.scores()
	# 4 个黑子都在白境 → 活子分 4，围空 1 点 +2
	t.expect_eq(sc.black.occupation_live, 4, "4 黑活子 +4")
	t.expect_eq(sc.black.occupation_territory, 2, "1 点围空 +2")
	t.expect_eq(sc.black.total(), 6, "黑总分 6")

	# 5. 提子：黑在己境提白 → 歼灭分 +2，白战损 -1
	s = GameSession.new()
	# 黑境(行0-8)。白下 (4,4)，黑包围提子
	# 白(4,4)，黑(3,4)(5,4)(4,3)，黑下(4,5)提白
	# 序列：黑1(3,4) 白1(4,4) 黑2(5,4) 白2(18,18白境远处) 黑3(4,3) 白3(18,17) 黑4(4,5)提白
	s = GameSession.new()
	s.play_move(Const.BLACK, 3, 4)
	s.play_move(Const.WHITE, 4, 4)
	s.play_move(Const.BLACK, 5, 4)
	s.play_move(Const.WHITE, 18, 18)  # 白境远处，不计占领分
	s.play_move(Const.BLACK, 4, 3)
	s.play_move(Const.WHITE, 18, 17)
	out = s.play_move(Const.BLACK, 4, 5)  # 提白(4,4)
	t.expect(out.ok, "黑(4,5)提子合法")
	t.expect_eq(out.captures.size(), 1, "提白一子")
	sc = s.scores()
	# 白(4,4)在黑境(行4<9)被提 → 黑歼灭 +2，白战损 -1
	t.expect_eq(sc.black.defense_annihilate, 2, "黑歼灭分 +2")
	t.expect_eq(sc.white.casualty_loss, -1, "白战损 -1")
	# 白(4,4)被提后无活子；白(18,18)(18,17)在白境(己境)无占领分
	t.expect_eq(sc.white.occupation_live, 0, "白无活子占领分")

	# 6. 围困分（v4.3：全分数动态结算）
	#    黑方 4x4 围墙（行8-11, 列8-11），圈内3空点含白子(9,9)在边境
	#    legal空点=3 < 4 → 围困；围困分盘中实时计算
	s = GameSession.new()
	for c in range(8, 12):
		s.board.set_at(8, c, Const.BLACK)
		s.board.set_at(11, c, Const.BLACK)
	for r in range(9, 11):
		s.board.set_at(r, 8, Const.BLACK)
		s.board.set_at(r, 11, Const.BLACK)
	s.board.set_at(9, 9, Const.WHITE)    # 圈内被围困白子（边境行9，legal空点=3<4）
	s.board.set_at(18, 18, Const.WHITE)  # 远处白子（白境己境，不计占领分）
	# 盘中：围困分动态结算，围困棋子活子分实时扣除
	sc = s.scores()
	t.expect_eq(sc.black.defense_siege, 1, "盘中围困分=1（动态结算）")
	t.expect_eq(sc.white.occupation_live, 0, "盘中围困棋子活子分已扣除")
	# 终局：与盘中一致（无额外结算）
	var fin6 = s.final_result("测试")
	t.expect_eq(fin6.black.breakdown.defense_siege, 1, "终局黑围困分 +1")
	t.expect_eq(fin6.white.breakdown.occupation_live, 0, "终局白被围困无活子分")

	# 7. 贴目终局
	s = GameSession.new()
	s.play_move(Const.BLACK, 10, 10)  # 黑 +1
	s.play_move(Const.WHITE, 8, 8)    # 白在黑境无分... 改白在黑境? 白在黑境=白攻击区 +1
	# 白(8,8)在黑境(行8<9) → 白活子 +1
	sc = s.scores()
	t.expect_eq(sc.black.occupation_live, 1, "黑 +1")
	t.expect_eq(sc.white.occupation_live, 1, "白 +1")
	var fin = s.final_result("测试")
	# 黑 1 - 3.5 = -2.5, 白 1 → 白胜
	t.expect_eq(fin.winner, "白方胜", "贴目后白胜")

	# 8. 兵力上限
	s = GameSession.new()
	s.stones_placed[Const.BLACK] = Const.PIECE_LIMIT - 1
	out = s.play_move(Const.BLACK, 10, 10)  # 第171子
	t.expect(out.ok, "第171子合法")
	t.expect_eq(s.pieces_left(Const.BLACK), 0, "黑兵力用尽")
	out = s.play_move(Const.WHITE, 11, 11)
	# 现在轮白
	t.expect(out.ok, "白继续落子")

	# 9. 围空圈内被围困棋子计分（v4.3：全分数动态结算）
	#    黑方 4x4 围墙（行8-11, 列8-11），圈内3空点+1白子(9,9)在边境
	#    legal空点=3 < 4 → 围困；围空分+围困分均盘中实时
	#    规则3.2：圈内所有交叉点（含对方棋子）均计入围空分
	s = GameSession.new()
	for c in range(8, 12):
		s.board.set_at(8, c, Const.BLACK)
		s.board.set_at(11, c, Const.BLACK)
	for r in range(9, 11):
		s.board.set_at(r, 8, Const.BLACK)
		s.board.set_at(r, 11, Const.BLACK)
	s.board.set_at(9, 9, Const.WHITE)   # 圈内被围困白子（边境行9，legal空点=3<4）
	s.board.set_at(0, 18, Const.WHITE)  # 远处白子，避免外部误判围空
	# 盘中：围空分+围困分均动态结算
	sc = s.scores()
	# 围空分：圈内3空点+1白子=4交叉点，均在黑攻击区 → +2*4=8（规则3.2：含对方棋子）
	t.expect_eq(sc.black.occupation_territory, 8, "围空分: (3空点+1白子)×2 = 8（含圈内对方棋子）")
	# 盘中围困分动态结算
	t.expect_eq(sc.black.defense_siege, 1, "盘中围困分=1（动态结算）")
	# 盘中围困棋子活子分已扣除；远处(0,18)在白攻击区(行0=黑境)+1
	t.expect_eq(sc.white.occupation_live, 1, "盘中围困棋子扣除，仅远处活子+1")
	# 终局：与盘中一致（无额外结算）
	var fin9 = s.final_result("测试")
	t.expect_eq(fin9.black.breakdown.defense_siege, 1, "终局围困分 +1")
	t.expect_eq(fin9.white.breakdown.occupation_live, 1, "终局围困棋子扣除，仅远处活子+1")

	# 10. 歼灭分区域判定：在敌方领土提吃 → 不计歼灭分（仅战损）
	#    黑在白境(行10-18)提白子 → is_defense_zone(白境, 黑)=false → 无歼灭分
	s = GameSession.new()
	# 白(12,12)在白境，黑包围提子
	s.play_move(Const.BLACK, 11, 12)
	s.play_move(Const.WHITE, 12, 12)
	s.play_move(Const.BLACK, 13, 12)
	s.play_move(Const.WHITE, 0, 0)  # 白境远处
	s.play_move(Const.BLACK, 12, 11)
	s.play_move(Const.WHITE, 0, 1)
	out = s.play_move(Const.BLACK, 12, 13)  # 提白(12,12)
	t.expect(out.ok, "黑在白境提子合法")
	t.expect_eq(out.captures.size(), 1, "提白一子")
	sc = s.scores()
	# 白(12,12)在白境(行12>9)被提 → is_defense_zone(12, BLACK)=false → 黑无歼灭分
	t.expect_eq(sc.black.defense_annihilate, 0, "黑在白境提子 → 无歼灭分（非己境/边境）")
	# 白战损 -1
	t.expect_eq(sc.white.casualty_loss, -1, "白战损 -1")

	# 11. 围困分区域判定（v4.1）：被围困棋子在围困方敌境 → 不计围困分
	#     黑4x4墙在白境围困白子 → 白子在黑敌境(白境) → 黑无围困分
	s = GameSession.new()
	# 黑方 4x4 围墙（行11-14, 列11-14），圈内3空点含白子(12,12)在白境
	for c in range(11, 15):
		s.board.set_at(11, c, Const.BLACK)
		s.board.set_at(14, c, Const.BLACK)
	for r in range(12, 14):
		s.board.set_at(r, 11, Const.BLACK)
		s.board.set_at(r, 14, Const.BLACK)
	s.board.set_at(12, 12, Const.WHITE)   # 圈内被围困白子（白境行12，legal空点=3<4）
	s.board.set_at(0, 0, Const.WHITE)     # 远处白子（黑境=白攻击区，活子+1）
	# 终局：白子(12,12)在白境(行12>9)被围困，但 is_defense_zone(12, BLACK)=false
	# → 黑围困分 0（白子在黑敌境非黑己境/边境）
	var fin11 = s.final_result("测试")
	t.expect_eq(fin11.black.breakdown.defense_siege, 0, "被围困白子在黑敌境(白境) → 黑无围困分")

	# 12. 围困棋子自己形成的包围圈围空分扣除（规则3.4，v4.3：盘中动态扣除）
	#    场景：白组群被黑围困（legal空点<4），但白组群自己围了一个独立小空
	#    盘中动态扣除：白组群活子分 + 白组群自己形成的包围圈围空分
	#    构造：黑4x4墙（行8-11,列8-11，黑境+边境），内含白组群(9,9)(9,10)(10,9)
	#    白组群围出空点(10,10) → 但白三子未形成闭合曲线 → 不计白方围空（计黑方围空）
	#    legal空点=0 < 4 → 白组群围困
	s = GameSession.new()
	# 黑方 4x4 围墙（行8-11, 列8-11）
	for c in range(8, 12):
		s.board.set_at(8, c, Const.BLACK)
		s.board.set_at(11, c, Const.BLACK)
	for r in range(9, 11):
		s.board.set_at(r, 8, Const.BLACK)
		s.board.set_at(r, 11, Const.BLACK)
	# 白组群：(9,9)(9,10)(10,9) 围出空点(10,10)
	s.board.set_at(9, 9, Const.WHITE)
	s.board.set_at(9, 10, Const.WHITE)
	s.board.set_at(10, 9, Const.WHITE)
	# 远处白子避免外部误判
	s.board.set_at(0, 0, Const.WHITE)
	# 盘中（v4.3：全动态结算）：
	# 白活子：围困棋子活子分扣除，远处(0,0)+1 → 共1
	# 白围空：白三子未形成闭合包围圈 → 0
	# 黑围空：圈内(10,10)空点+3白子位置=4交叉点，均在黑攻击区 → +2×4=8
	# 黑围困分：白组群3子中(9,9)(9,10)在边境(is_defense_zone(BLACK))→+2；(10,9)在白境→+0
	sc = s.scores()
	t.expect_eq(sc.white.occupation_live, 1, "盘中白活子: 围困扣除，仅远处+1 = 1")
	t.expect_eq(sc.white.occupation_territory, 0, "盘中白围空 0（白三子未形成闭合包围圈）")
	t.expect_eq(sc.black.occupation_territory, 8, "黑围空: (1空点+3白子)×2 = 8")
	t.expect_eq(sc.black.defense_siege, 2, "盘中黑围困分 +2（白组群2子在边境）")
	# 终局：与盘中一致（无额外结算）
	var fin12 = s.final_result("测试")
	t.expect_eq(fin12.white.breakdown.occupation_live, 1, "终局白活子扣除围困棋子分，仅远处+1")
	t.expect_eq(fin12.black.breakdown.defense_siege, 2, "终局黑围困分 +2（白组群2子在边境）")

	# 13. 围困棋子自己形成闭合包围圈时扣除围空分（规则3.4核心场景，v4.3：盘中动态扣除）
	#    白方框8子围空点(9,9)，被黑墙紧贴包围 → legal空点=0<4 → 围困
	#    盘中动态扣除：白组群活子分 + 白组群自己形成的围空分
	s = GameSession.new()
	# 黑墙5x5（行7-11,列7-11）紧贴白方框
	for c in range(7, 12):
		s.board.set_at(7, c, Const.BLACK)
		s.board.set_at(11, c, Const.BLACK)
	for r in range(8, 11):
		s.board.set_at(r, 7, Const.BLACK)
		s.board.set_at(r, 11, Const.BLACK)
	# 白方框8子围空点(9,9)
	for r in range(8, 11):
		for c in range(8, 11):
			if r == 9 and c == 9:
				continue
			s.board.set_at(r, c, Const.WHITE)
	s.board.set_at(0, 0, Const.WHITE)
	# 盘中（v4.3：全动态结算）：
	# 白活子：围困棋子活子分扣除，远处(0,0)+1 → 共1
	# 白围空：白方框形成的包围圈(9,9)因围困扣除 → 0
	# 黑围困分：白组群8子中行8-9的5子在黑境/边境→+5
	sc = s.scores()
	t.expect_eq(sc.white.occupation_live, 1, "盘中白活子: 围困扣除，仅远处+1 = 1")
	t.expect_eq(sc.white.occupation_territory, 0, "盘中白围空扣除（围困棋子自己形成的包围圈）")
	t.expect_eq(sc.black.defense_siege, 5, "盘中黑围困分 +5（白组群5子在黑境/边境）")
	# 终局：与盘中一致（无额外结算）
	var fin13 = s.final_result("测试")
	t.expect_eq(fin13.white.breakdown.occupation_live, 1, "终局白活子扣除围困棋子分，仅远处+1")
	t.expect_eq(fin13.white.breakdown.occupation_territory, 0, "终局白围空扣除（围困棋子自己形成的包围圈）")
	t.expect_eq(fin13.black.breakdown.defense_siege, 5, "终局黑围困分 +5（白组群5子在黑境/边境）")

	# 14. 贴目生效测试：自定义 komi 应直接影响终局总分与胜者
	#    场景：黑下(10,10)在白境+1，白下(0,0)在黑境(白攻击区)+1 → 双方盘中各1分
	#    终局：黑 final = 1 - komi，白 final = 1
	#    komi=0.5  → 黑 0.5 > 白 1 → 白胜
	#    komi=1.5  → 黑 -0.5 < 白 1 → 白胜
	#    komi=0.0  → 黑 1 == 白 1 → 和棋
	var s_komi0 := GameSession.new(0.0, false)
	s_komi0.play_move(Const.BLACK, 10, 10)
	s_komi0.play_move(Const.WHITE, 0, 0)
	var fin_komi0 = s_komi0.final_result("贴目测试")
	t.expect_eq(fin_komi0.black.final, 1.0, "komi=0: 黑 final = 1 - 0 = 1")
	t.expect_eq(fin_komi0.white.final, 1.0, "komi=0: 白 final = 1")
	t.expect_eq(fin_komi0.winner, "和棋", "komi=0: 和棋")

	var s_komi05 := GameSession.new(0.5, false)
	s_komi05.play_move(Const.BLACK, 10, 10)
	s_komi05.play_move(Const.WHITE, 0, 0)
	var fin_komi05 = s_komi05.final_result("贴目测试")
	t.expect_eq(fin_komi05.black.final, 0.5, "komi=0.5: 黑 final = 1 - 0.5 = 0.5")
	t.expect_eq(fin_komi05.winner, "白方胜", "komi=0.5: 白胜（0.5 < 1）")

	var s_komi35 := GameSession.new(3.5, false)
	s_komi35.play_move(Const.BLACK, 10, 10)
	s_komi35.play_move(Const.WHITE, 0, 0)
	var fin_komi35 = s_komi35.final_result("贴目测试")
	t.expect_eq(fin_komi35.black.final, -2.5, "komi=3.5: 黑 final = 1 - 3.5 = -2.5")
	t.expect_eq(fin_komi35.komi, 3.5, "komi=3.5: 返回值携带正确贴目")
	t.expect_eq(fin_komi35.winner, "白方胜", "komi=3.5: 白胜（-2.5 < 1）")

	# 15. 贴目反转测试：komi 足够大时黑胜 → 白胜
	#     黑在白境围大空（+8围空），白仅1活子 → 黑8 - komi vs 白1
	#     komi=5.0 → 黑 3 > 白 1 → 黑胜
	#     komi=10.0 → 黑 -2 < 白 1 → 白胜
	var s_big := GameSession.new(5.0, false)
	for c in range(8, 12):
		s_big.board.set_at(8, c, Const.BLACK)
		s_big.board.set_at(11, c, Const.BLACK)
	for r in range(9, 11):
		s_big.board.set_at(r, 8, Const.BLACK)
		s_big.board.set_at(r, 11, Const.BLACK)
	s_big.board.set_at(0, 0, Const.WHITE)
	var fin_big5 = s_big.final_result("贴目反转")
	t.expect_eq(fin_big5.winner, "黑方胜", "komi=5.0: 黑胜（8-5=3 > 1）")

	var s_big10 := GameSession.new(10.0, false)
	for c in range(8, 12):
		s_big10.board.set_at(8, c, Const.BLACK)
		s_big10.board.set_at(11, c, Const.BLACK)
	for r in range(9, 11):
		s_big10.board.set_at(r, 8, Const.BLACK)
		s_big10.board.set_at(r, 11, Const.BLACK)
	s_big10.board.set_at(0, 0, Const.WHITE)
	var fin_big10 = s_big10.final_result("贴目反转")
	t.expect_eq(fin_big10.winner, "白方胜", "komi=10.0: 白胜（8-10=-2 < 1）")

	# 16. 兵力上限可变测试：piece_limit 实例字段生效
	#     piece_limit=99 → 第100子非法；默认171 → 第100子合法
	var s_pl99 := GameSession.new(Const.KOMI_DEFAULT, false, 99)
	t.expect_eq(s_pl99.piece_limit, 99, "piece_limit=99 实例字段正确")
	t.expect_eq(s_pl99.pieces_left(Const.BLACK), 99, "piece_limit=99: 初始兵力 99")
	s_pl99.stones_placed[Const.BLACK] = 98
	t.expect(s_pl99.can_place(Const.BLACK), "piece_limit=99: 第99子合法")
	s_pl99.stones_placed[Const.BLACK] = 99
	t.expect(not s_pl99.can_place(Const.BLACK), "piece_limit=99: 第100子非法")

	var s_pl144 := GameSession.new(Const.KOMI_DEFAULT, false, 144)
	t.expect_eq(s_pl144.piece_limit, 144, "piece_limit=144 实例字段正确")
	s_pl144.stones_placed[Const.BLACK] = 143
	t.expect(s_pl144.can_place(Const.BLACK), "piece_limit=144: 第144子合法")
	s_pl144.stones_placed[Const.BLACK] = 144
	t.expect(not s_pl144.can_place(Const.BLACK), "piece_limit=144: 第145子非法")

	# 17. clone() 继承 piece_limit
	var s_orig := GameSession.new(4.5, true, 128)
	var s_clone := s_orig.clone()
	t.expect_eq(s_clone.piece_limit, 128, "clone() 继承 piece_limit=128")
	t.expect_eq(s_clone.komi, 4.5, "clone() 继承 komi=4.5")
