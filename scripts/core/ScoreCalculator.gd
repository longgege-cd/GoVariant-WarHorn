# 计分引擎（v4.3规则 — 全分数动态结算）
#
# 总分 = 占领分 + 防御分 - 战损分
#   占领分 = 活子分(+1/子于敌境/边境) + 围空分(+2/交叉点于己方围空内且在敌境/边境)
# 防御分 = 歼灭分(+2/子在己境/边境实际提吃，累计) + 围困分(+1/子被围困于己境/边境)
#   战损分 = 部队损失(-1/普通子被提吃，累计) + 隐子损失(-6/特种部队被提吃，累计)
#
# v4.3 核心机制（全分数动态结算）：
#   - 盘中：所有分数（含围困分）实时动态计算
#   - 围困棋子不计活子分（盘中实时扣除）
#   - 围困棋子自己形成的包围圈围空分扣除（盘中实时）
#   - 围困分盘中实时结算（+1/子在围困方己境/边境）
#   - 终局：仅追加特种部队奖励 + 贴目 + 判胜
#   - 规则3.2：围空分计圈内空点 + 圈内对方围困棋子位置；对方活棋所占的点不计入
#   - 规则3.4：扣除"围困棋子自己形成的包围圈"的围空分（围困棋子作为围空方）
#   - 规则4.2：包围圈边界任一棋子为围困 → 围空分不计入占领分
#
# counters 结构（由 GameSession 维护）：
#   { color: { "annihilate": int, "normal_lost": int, "special_lost": int } }
class_name ScoreCalculator
extends RefCounted

# 单方明细
class Breakdown:
	extends RefCounted
	var occupation_live: int = 0        # 活子分 +1/子
	var occupation_territory: int = 0   # 围空分 +2/点（按面积空点）
	var defense_annihilate: int = 0     # 歼灭分 +2/子
	var defense_siege: int = 0          # 围困分 +1/子（动态结算）
	var casualty_loss: int = 0
	var casualty_special: int = 0
	func occupation() -> int: return occupation_live + occupation_territory
	func defense() -> int: return defense_annihilate + defense_siege
	func casualty() -> int: return casualty_loss + casualty_special
	func total() -> int:
		return occupation() + defense() + casualty()  # casualty 已为负

# 盘中实时计分（v4.3：全分数动态结算，含围困分）
# 返回 { "black": Breakdown, "white": Breakdown }
# precomputed_sieged: 可选预计算的围困组群列表（避免与 GameSession 重复遍历）
# precomputed_encs: 可选预计算的围空列表（避免与 GameSession 重复遍历）
static func compute(board: BoardModel, counters: Dictionary, precomputed_sieged: Variant = null, precomputed_encs: Variant = null) -> Dictionary:
	var bk := Breakdown.new()
	var wt := Breakdown.new()

	# 1. 识别所有围困棋子（v4.3：盘中实时判定）
	# 围困 = 被包围 + 无两眼 + 圈内可合法落子空点 < 4（规则4.2）
	# 提前识别：围空分计算需依据"对方活棋/围困"区分计分
	var sieged_stones_set: Dictionary = {}  # idx -> color（围困棋子颜色）
	var sieged_groups_list: Array = []
	if precomputed_sieged != null and precomputed_sieged is Array:
		# 复用调用方预计算的围困组群（避免重复遍历 all_groups + is_sieged）
		sieged_groups_list = precomputed_sieged
		for g in sieged_groups_list:
			for s in g.stones:
				sieged_stones_set[s.y * board.size + s.x] = g.color
	else:
		# 全盘死活迭代求解（v6.2：有效包围圈 = 由活棋围成的封闭边界）
		var da: Dictionary = SiegeDetector.solve_dead_alive(board)
		sieged_groups_list = da.sieged
		for g in sieged_groups_list:
			for s in g.stones:
				sieged_stones_set[s.y * board.size + s.x] = g.color

	# 2. 围空分（规则3.2：圈内空点 +2/点；圈内对方棋子位置仅围困时 +2/点，活棋不计入）
	# 纯几何判定，不依赖围成棋子死活（规则6.1）
	var encs: Array = precomputed_encs if (precomputed_encs != null and precomputed_encs is Array) else TerritoryDetector.enclosures(board)
	for e in encs:
		var color: int = e.color  # 围空方
		var target: Breakdown = bk if color == Const.BLACK else wt
		# 圈内空点 +2/点
		for p in e.points:
			if Const.is_attack_zone(p.y, color):
				target.occupation_territory += 2
		# 圈内对方棋子位置 +2/点（仅围困棋子；活棋所占的点不计入围空分）
		for s in e.stones_inside:
			var sidx: int = s.y * board.size + s.x
			if not sieged_stones_set.has(sidx):
				continue  # 对方活棋 → 跳过
			if Const.is_attack_zone(s.y, color):
				target.occupation_territory += 2

	# 3. 扣除围困棋子自己形成的包围圈的围空分（规则3.4，v4.3：盘中实时扣除）
	# 围困棋子作为围空方形成的包围圈，其围空分全部扣除
	# 同时（规则6.3嵌套）：无效包围圈的空点归属于对手方(最外层有效包围方)
	for e in encs:
		if is_enclosure_formed_by_sieged(board, e, sieged_stones_set):
			var enc_color: int = e.color
			var target: Breakdown = bk if enc_color == Const.BLACK else wt
			# 扣除围空方的围空分（与第2步加法对应：仅围困棋子位置扣除，活棋位置未加故不扣）
			for p in e.points:
				if Const.is_attack_zone(p.y, enc_color):
					target.occupation_territory -= 2
			for s in e.stones_inside:
				var sidx: int = s.y * board.size + s.x
				if not sieged_stones_set.has(sidx):
					continue  # 对方活棋 → 第2步未加，此处不扣
				if Const.is_attack_zone(s.y, enc_color):
					target.occupation_territory -= 2
			# 嵌套归属：无效包围圈空点归对手方（规则6.3：内层无效→归外层有效包围方）
			var opp: int = Const.opponent(enc_color)
			var opp_target: Breakdown = bk if opp == Const.BLACK else wt
			for p in e.points:
				if Const.is_attack_zone(p.y, opp):
					opp_target.occupation_territory += 2

	# 4. 活子分（v4.3：围困棋子不计活子分，盘中实时扣除）
	# 规则3.1：活子 = 有气且未被提吃的棋子，敌境/边境 +1/子
	# 围困棋子的活子分全部扣除（规则5.1）
	var groups: Array = board.all_groups()
	for g in groups:
		var color: int = g.color
		var stones: Array = g.stones
		var target: Breakdown = bk if color == Const.BLACK else wt
		# 检查该组群是否被围困（用组群任一棋子查询 sieged_stones_set）
		var is_sieged_group: bool = false
		if not stones.is_empty():
			is_sieged_group = sieged_stones_set.has(stones[0].y * board.size + stones[0].x)
		if is_sieged_group:
			continue  # 围困棋子不计活子分
		for s in stones:
			if Const.is_attack_zone(s.y, color):
				target.occupation_live += 1

	# 5. 结算围困分（规则5.2，v4.3：盘中实时结算）
	# 围困棋子按所在区域计分：
	#   围困方己方领土内 → +1/子（围困方己境）
	#   边境线上 → +1/子（可与围空分叠加）
	#   对方领土内 → 不计（被围空分覆盖）
	for g in sieged_groups_list:
		var color: int = g.color       # 被围困方
		var opp: int = Const.opponent(color)  # 围困方
		var opp_target: Breakdown = bk if opp == Const.BLACK else wt
		for s in g.stones:
			if Const.is_defense_zone(s.y, opp):
				opp_target.defense_siege += 1

	# 6. 累计事件分（歼灭分/战损分 实时累计）
	_apply_counters(bk, wt, counters)

	return { "black": bk, "white": wt }

# 应用累计事件计数器
static func _apply_counters(bk: Breakdown, wt: Breakdown, counters: Dictionary) -> void:
	for color in [Const.BLACK, Const.WHITE]:
		var c: Dictionary = counters.get(color, {})
		var b: Breakdown = bk if color == Const.BLACK else wt
		var ann: int = c.get("annihilate", 0)
		var nl: int = c.get("normal_lost", 0)
		var sl: int = c.get("special_lost", 0)
		b.defense_annihilate += ann * 2
		b.casualty_loss -= nl
		b.casualty_special -= sl * 6

# 终局结算（v4.3：盘中已全动态结算，终局仅追加特种部队奖励 + 贴目 + 判胜）
# special_rewards: { color: { occ_live_delta, occ_territ_delta, def_delta, def_siege_delta } }
static func compute_final(board: BoardModel, counters: Dictionary, komi: float, special_rewards: Dictionary) -> Dictionary:
	# 盘中已全动态结算（含围困分）
	var res: Dictionary = compute(board, counters)
	var bk: Breakdown = res.black
	var wt: Breakdown = res.white

	# 追加特种部队奖励增量
	for color in [Const.BLACK, Const.WHITE]:
		var sr: Dictionary = special_rewards.get(color, {})
		var b: Breakdown = bk if color == Const.BLACK else wt
		b.occupation_live += int(sr.get("occ_live_delta", 0))
		b.occupation_territory += int(sr.get("occ_territ_delta", 0))
		b.defense_annihilate += int(sr.get("def_delta", 0))
		b.defense_siege += int(sr.get("def_siege_delta", 0))

	# 计算总分与胜者
	var bk_total: int = bk.total()
	var wt_total: int = wt.total()
	var bk_final: float = bk_total - komi
	var wt_final: float = wt_total
	var winner: String = "和棋"
	var winner_color: int = -1
	if bk_final > wt_final:
		winner = "黑方胜"
		winner_color = Const.BLACK
	elif wt_final > bk_final:
		winner = "白方胜"
		winner_color = Const.WHITE
	return {
		"black": { "breakdown": bk, "total": bk_total, "komi": komi, "final": bk_final },
		"white": { "breakdown": wt, "total": wt_total, "final": wt_final },
		"winner": winner,
		"winner_color": winner_color,
	}

# 判定包围圈是否由围困棋子形成（规则4.2 + 3.4）
# 规则4.2：包围圈边界棋子任一为围困 → 围空分不计入占领分
# 规则3.4：被围困的棋子自己形成的包围圈，其围空分全部扣除
# 条件：围空方颜色的边界棋子中任一属于围困组群 → 包围圈无效，扣除围空分
# sieged_stones_set: { idx -> any }（围困棋子位置索引集合；值可为颜色或 true，只判存在性）
# 公开：供显示层（BoardView 领土填充 / 对局日志）过滤无效包围圈
static func is_enclosure_formed_by_sieged(board: BoardModel, enclosure: Dictionary, sieged_stones_set: Dictionary) -> bool:
	var enc_color: int = enclosure.color
	for idx in enclosure.border_stones_idx:
		var r: int = idx / board.size
		var c: int = idx % board.size
		if board.get_at(r, c) != enc_color:
			continue  # 对方棋子作为边界（两色边界场景），不影响判定
		# 围空方颜色的边界棋子：若任一为围困 → 包围圈无效
		if sieged_stones_set.has(idx):
			return true
	# 所有围空方边界棋子都非围困 → 包围圈有效
	return false
