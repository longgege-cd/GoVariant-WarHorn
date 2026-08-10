# 经典围棋对局规则对比（传统围棋 vs 边境线规则）
#
# 用途：构造几个有代表性的围棋对局终局局面，分别用两种规则计算胜负，
#       对比规则差异如何影响胜负判定。
#
# 两种规则：
#   ① 传统围棋（中国数子法简化版）：
#      - 总分 = 己方活子数 + 己方围住空点数
#      - 贴目 6.5（黑方贴目）
#      - 双方活子都计 1/子，围空都计 1/点（不分区域）
#
#   ② 边境线规则（本项目）：
#      - 总分 = 活子分(攻击区+1/子) + 围空分(攻击区+2/点)
#             + 围困分(+1/子于己境/边境) + 歼灭分(+2/子) - 战损分
#      - 贴目 2.5（黑方贴目）
#      - 攻击区 = 己方领土(对方领土+边境)；己境不计分
#      - 围困机制：被包围且无两眼且空点<4的棋子活子分扣除
#
# 运行: godot --headless --script res://tests/run_classic_compare.gd
extends SceneTree

const TestFramework = preload("res://tests/test_framework.gd")

# 传统围棋中国数子法简化计算
# 返回 { "black": int, "white": int, "komi": 6.5, "winner": str }
func traditional_score(board: BoardModel, komi: float = 6.5) -> Dictionary:
	var size: int = board.size
	var black_stones: int = 0
	var white_stones: int = 0
	# 活子计数（排除被围困的棋子）
	var sieged_set: Dictionary = {}
	for g in board.all_groups():
		if SiegeDetector.is_sieged(board, g):
			for s in g.stones:
				sieged_set[s.y * size + s.x] = true
	for r in range(size):
		for c in range(size):
			var v: int = board.get_at(r, c)
			if v == Const.EMPTY:
				continue
			if sieged_set.has(r * size + c):
				continue  # 围困棋子不计活子（死子）
			if v == Const.BLACK:
				black_stones += 1
			else:
				white_stones += 1
	# 围空（TerritoryDetector 的 enclosures 返回单色围空圈）
	var encs: Array = TerritoryDetector.enclosures(board)
	var black_territory: int = 0
	var white_territory: int = 0
	for e in encs:
		if e.color == Const.BLACK:
			black_territory += e.points.size()
		else:
			white_territory += e.points.size()
		# 围空圈内对方围困棋子位置计入己方地（传统围棋死子算地）
		for s in e.get("stones_inside", []):
			var sidx: int = s.y * size + s.x
			if sieged_set.has(sidx):
				if e.color == Const.BLACK:
					black_territory += 1
				else:
					white_territory += 1
	var black_total: float = black_stones + black_territory - komi
	var white_total: float = white_stones + white_territory
	var winner: String = "和棋"
	if black_total > white_total:
		winner = "黑方胜"
	elif white_total > black_total:
		winner = "白方胜"
	return {
		"black_stones": black_stones,
		"white_stones": white_stones,
		"black_territory": black_territory,
		"white_territory": white_territory,
		"black_total": black_total,
		"white_total": white_total,
		"komi": komi,
		"winner": winner,
	}

# 边境线规则计算（使用 GameSession）
func border_score(board: BoardModel, komi: float = 2.5) -> Dictionary:
	var s := GameSession.new(komi, false)
	s.board = board.clone()
	var sc = s.scores()
	var fin = s.final_result("对比")
	return {
		"black_live": sc.black.occupation_live,
		"black_territory": sc.black.occupation_territory,
		"black_siege": sc.black.defense_siege,
		"black_annihilate": sc.black.defense_annihilate,
		"black_total": fin.black.total,
		"black_final": fin.black.final,
		"white_live": sc.white.occupation_live,
		"white_territory": sc.white.occupation_territory,
		"white_siege": sc.white.defense_siege,
		"white_annihilate": sc.white.defense_annihilate,
		"white_total": fin.white.total,
		"white_final": fin.white.final,
		"komi": komi,
		"winner": fin.winner,
	}

# 打印对比结果
func print_compare(title: String, trad: Dictionary, bord: Dictionary) -> void:
	print("\n────────── %s ──────────" % title)
	print("【传统围棋】(贴目 %.1f)" % trad.komi)
	print("  黑: 活子%d + 围空%d - 贴目%.1f = %.1f" % [trad.black_stones, trad.black_territory, trad.komi, trad.black_total])
	print("  白: 活子%d + 围空%d = %.1f" % [trad.white_stones, trad.white_territory, trad.white_total])
	print("  → %s" % trad.winner)
	print("【边境线规则】(贴目 %.1f)" % bord.komi)
	print("  黑: 活子%d + 围空%d + 围困%d + 歼灭%d = %d (贴目后 %.1f)" % [
		bord.black_live, bord.black_territory, bord.black_siege, bord.black_annihilate,
		bord.black_total, bord.black_final])
	print("  白: 活子%d + 围空%d + 围困%d + 歼灭%d = %d (贴目后 %.1f)" % [
		bord.white_live, bord.white_territory, bord.white_siege, bord.white_annihilate,
		bord.white_total, bord.white_final])
	print("  → %s" % bord.winner)
	# 差异分析
	var trad_diff: float = trad.black_total - trad.white_total
	var bord_diff: float = bord.black_final - bord.white_final
	print("  差异: 传统黑净%.1f vs 边境线黑净%.1f → %s" % [
		trad_diff, bord_diff,
		("胜者一致" if trad.winner == bord.winner else "★胜者反转★")])

func _init() -> void:
	print("############## 经典围棋对局规则对比 ##############")
	print("棋盘分区: 行0-8=黑境, 行9=边境, 行10-18=白境")
	print("边境线规则: 仅攻击区(对方领土+边境)的活子(+1)和围空(+2)计分")
	print("")

	# ============================================================
	# 场景1: 宇宙流风格 — 黑围中腹大模样 vs 白围四角实地
	# ============================================================
	# 黑棋围住上方大片（行0-9，模拟武宫正树宇宙流）
	# 白棋围住四角小块实地（行10-18的四个角）
	var b1 := BoardModel.new()
	# 黑上方大墙：行9全黑（边境线整行），列0和列18全黑到行9
	for c in range(19):
		b1.set_at(9, c, Const.BLACK)
	for r in range(0, 9):
		b1.set_at(r, 0, Const.BLACK)
		b1.set_at(r, 18, Const.BLACK)
	# 上方再围一层确保封闭
	for c in range(0, 19):
		b1.set_at(0, c, Const.BLACK)
	# 白方四角小围空（行10-18的角）
	# 右下角围 (17,17)
	b1.set_at(17, 16, Const.WHITE); b1.set_at(16, 17, Const.WHITE); b1.set_at(17, 18, Const.WHITE); b1.set_at(18, 17, Const.WHITE)
	# 左下角围 (17,1)
	b1.set_at(17, 0, Const.WHITE); b1.set_at(17, 2, Const.WHITE); b1.set_at(16, 1, Const.WHITE); b1.set_at(18, 1, Const.WHITE)
	# 远处白子避免单色墙误判
	b1.set_at(10, 9, Const.WHITE)
	print_compare("场景1: 宇宙流大模样(黑围上方) vs 实地(白围四角)",
		traditional_score(b1), border_score(b1))

	# ============================================================
	# 场景2: 对角星布局 — 黑左上+右下，白右上+左下
	# ============================================================
	var b2 := BoardModel.new()
	# 黑左上围角 (2,2)
	b2.set_at(2, 1, Const.BLACK); b2.set_at(1, 2, Const.BLACK); b2.set_at(2, 3, Const.BLACK); b2.set_at(3, 2, Const.BLACK)
	# 黑右下围角 (16,16) — 注意右下在白境
	b2.set_at(16, 15, Const.BLACK); b2.set_at(15, 16, Const.BLACK); b2.set_at(16, 17, Const.BLACK); b2.set_at(17, 16, Const.BLACK)
	# 白右上围角 (2,16)
	b2.set_at(2, 15, Const.WHITE); b2.set_at(1, 16, Const.WHITE); b2.set_at(2, 17, Const.WHITE); b2.set_at(3, 16, Const.WHITE)
	# 白左下围角 (16,2)
	b2.set_at(16, 1, Const.WHITE); b2.set_at(15, 2, Const.WHITE); b2.set_at(16, 3, Const.WHITE); b2.set_at(17, 2, Const.WHITE)
	print_compare("场景2: 对角星布局(黑左上+黑右下,白右上+白左下)",
		traditional_score(b2), border_score(b2))

	# ============================================================
	# 场景3: 黑棋深入白境（敌后渗透）
	# ============================================================
	# 黑棋在白境(行10-18)围出一块地，白棋在黑境(行0-8)围出一块地
	var b3 := BoardModel.new()
	# 黑在白境围空 (13,13)
	b3.set_at(13, 12, Const.BLACK); b3.set_at(12, 13, Const.BLACK); b3.set_at(13, 14, Const.BLACK); b3.set_at(14, 13, Const.BLACK)
	# 白在黑境围空 (5,5)
	b3.set_at(5, 4, Const.WHITE); b3.set_at(4, 5, Const.WHITE); b3.set_at(5, 6, Const.WHITE); b3.set_at(6, 5, Const.WHITE)
	print_compare("场景3: 敌后渗透(黑围白境+白围黑境,空点相等)",
		traditional_score(b3), border_score(b3))

	# ============================================================
	# 场景4: 黑棋围困白子（围困机制对比）
	# ============================================================
	# 黑在边境围困白子（legal空点<4 → 围困）
	var b4 := BoardModel.new()
	# 黑 4x4 围墙（行8-11, 列8-11），围困白子 (9,9) 在边境
	for c in range(8, 12):
		b4.set_at(8, c, Const.BLACK)
		b4.set_at(11, c, Const.BLACK)
	for r in range(9, 11):
		b4.set_at(r, 8, Const.BLACK)
		b4.set_at(r, 11, Const.BLACK)
	b4.set_at(9, 9, Const.WHITE)  # 圈内被围困白子
	b4.set_at(0, 18, Const.WHITE)  # 远处白子避免单色误判
	print_compare("场景4: 黑围困白子(边境线围困,4x4墙围1白子)",
		traditional_score(b4), border_score(b4))

	# ============================================================
	# 场景5: 双方各围一块边境线两侧（贴目对比）
	# ============================================================
	# 黑围住边境线上方一块（含边境行9）
	# 白围住边境线下方一块（含边境行9）
	var b5 := BoardModel.new()
	# 黑上方围 (7,9) 区域 — 行5-11 列7-11 黑墙
	for c in range(7, 12):
		b5.set_at(5, c, Const.BLACK)
	for r in range(6, 11):
		b5.set_at(r, 7, Const.BLACK)
		b5.set_at(r, 11, Const.BLACK)
	# 底部边界（行10 不放，让(7,9)(8,9)(9,9)(10,9)4空点在黑境内）
	# 改：底部用边境行9作为天然边界？不行，需要黑棋封闭
	# 简化：底部行11全黑
	for c in range(7, 12):
		b5.set_at(11, c, Const.BLACK)
	# 白下方围 (11,9) 区域 — 行12-18 列7-11 白墙
	for c in range(7, 12):
		b5.set_at(13, c, Const.WHITE)
	for r in range(14, 18):
		b5.set_at(r, 7, Const.WHITE)
		b5.set_at(r, 11, Const.WHITE)
	for c in range(7, 12):
		b5.set_at(18, c, Const.WHITE)
	print_compare("场景5: 黑围上方+白围下方(等量空点,贴目对比)",
		traditional_score(b5), border_score(b5))

	# ============================================================
	# 场景6: 三线星位围空对比（黑围三线 vs 白围三线）
	# ============================================================
	# 黑围三线（行2,列2角）vs 白围三线（行16,列16角）
	# 模拟标准对子棋局面
	var b6 := BoardModel.new()
	# 黑左上三线围空（行1-3,列1-3 围 (2,2)）
	b6.set_at(1, 1, Const.BLACK); b6.set_at(1, 2, Const.BLACK); b6.set_at(1, 3, Const.BLACK)
	b6.set_at(2, 1, Const.BLACK); b6.set_at(2, 3, Const.BLACK)
	b6.set_at(3, 1, Const.BLACK); b6.set_at(3, 2, Const.BLACK); b6.set_at(3, 3, Const.BLACK)
	# 白右下三线围空（行15-17,列15-17 围 (16,16)）
	b6.set_at(15, 15, Const.WHITE); b6.set_at(15, 16, Const.WHITE); b6.set_at(15, 17, Const.WHITE)
	b6.set_at(16, 15, Const.WHITE); b6.set_at(16, 17, Const.WHITE)
	b6.set_at(17, 15, Const.WHITE); b6.set_at(17, 16, Const.WHITE); b6.set_at(17, 17, Const.WHITE)
	print_compare("场景6: 标准三线围空(黑左上角 vs 白右下角,等量)",
		traditional_score(b6), border_score(b6))

	# ============================================================
	# 场景7: 黑棋边境线大规模围空（边境作战）
	# ============================================================
	# 黑棋沿边境线(行9)两侧围出大块
	var b7 := BoardModel.new()
	# 黑大墙：行6-12,列4-14 黑框，内部 5x9=45 空点
	for c in range(4, 15):
		b7.set_at(6, c, Const.BLACK)
		b7.set_at(12, c, Const.BLACK)
	for r in range(7, 12):
		b7.set_at(r, 4, Const.BLACK)
		b7.set_at(r, 14, Const.BLACK)
	# 白围一个小角 (16,2)
	b7.set_at(16, 1, Const.WHITE); b7.set_at(15, 2, Const.WHITE); b7.set_at(16, 3, Const.WHITE); b7.set_at(17, 2, Const.WHITE)
	b7.set_at(0, 18, Const.WHITE)
	print_compare("场景7: 黑边境大围空 vs 白小角地",
		traditional_score(b7), border_score(b7))

	print("\n############## 对比完成 ##############")
	quit(0)
