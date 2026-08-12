# 评估函数（参考《AI对手算法设计文档》第三章）
#
# 从 AI 视角评估当前局面，综合加权：
#   score_diff(1.0)        分数差（最重要）
#   resource(0.3)          棋子余量比例差（动态读取兵力上限）
#   border_control(0.15)   边境线控制
#   enclosure_potential(0.1) 包围圈潜力
#   trapped_penalty(0.5)   被围困棋子惩罚
#   territory_control(0.05) 领土控制
#   special_force_threat(0.1) 特种部队威胁（可选规则时有效）
#
# 性能：scores()/cached_enclosures()/cached_sieged_groups() 共享一次全盘缓存重建
class_name EvaluationFunction
extends RefCounted

const WEIGHTS := {
	"score_diff": 1.0,
	"resource": 0.3,
	"border_control": 0.15,
	"enclosure_potential": 0.1,
	"trapped_penalty": 0.5,
	"territory_control": 0.05,
	"special_force_threat": 0.1,
}

func evaluate(session: GameSession, ai_color: int) -> float:
	var opp: int = Const.opponent(ai_color)
	# 分数差（触发一次全盘缓存：围困+围空+计分）
	var sc: Dictionary = session.scores()
	var my: int = sc.black.total() if ai_color == Const.BLACK else sc.white.total()
	var opp_score: int = sc.white.total() if ai_color == Const.BLACK else sc.black.total()
	var score_diff: float = my - opp_score

	# 资源评估（动态读取兵力上限）
	var my_left: int = session.pieces_left(ai_color)
	var opp_left: int = session.pieces_left(opp)
	var max_stones: int = max(session.piece_limit, 1)
	var resource_ratio: float = float(my_left) / max_stones - float(opp_left) / max_stones

	# 边境线控制评估
	var border_control: float = _evaluate_border_control(session.board, ai_color)

	# 包围圈潜力评估（己方有效围空面积）
	var enclosure_potential: float = _evaluate_enclosure_potential(session, ai_color)

	# 被围困棋子惩罚（缓存命中）
	var my_trapped: int = _count_trapped(session, ai_color)
	var opp_trapped: int = _count_trapped(session, opp)

	# 领土控制评估
	var territory_control: float = _evaluate_territory_control(session.board, ai_color)

	var evaluation := 0.0
	evaluation += score_diff * WEIGHTS.score_diff
	evaluation += resource_ratio * 100.0 * WEIGHTS.resource
	evaluation += border_control * WEIGHTS.border_control
	evaluation += enclosure_potential * WEIGHTS.enclosure_potential
	evaluation += territory_control * WEIGHTS.territory_control
	evaluation -= my_trapped * WEIGHTS.trapped_penalty
	evaluation += opp_trapped * WEIGHTS.trapped_penalty * 0.5

	# 特种部队威胁评估（可选规则时）
	if session.special.enabled:
		evaluation += _evaluate_special_threat(session, ai_color) * WEIGHTS.special_force_threat

	return evaluation

# 边境线控制：己方棋子 +1，对方 -1
func _evaluate_border_control(board: BoardModel, ai_color: int) -> float:
	var control := 0.0
	var opp: int = Const.opponent(ai_color)
	var br: int = Const.BORDER_ROW
	for c in range(board.size):
		var v: int = board.get_at(br, c)
		if v == ai_color:
			control += 1.0
		elif v == opp:
			control -= 1.0
	return control

# 包围圈潜力：己方围空圈有效点（在敌境/边境的点 ×2）
func _evaluate_enclosure_potential(session: GameSession, ai_color: int) -> float:
	var potential := 0.0
	for enc in session.cached_enclosures():
		if enc.color != ai_color:
			continue
		for p in enc.points:
			if Const.is_attack_zone(p.y, ai_color):
				potential += 2.0
	return potential

# 领土控制：己方领土内己方子 - 对方子
func _evaluate_territory_control(board: BoardModel, ai_color: int) -> float:
	var control := 0.0
	var my_zone: int = Const.own_zone(ai_color)
	var opp: int = Const.opponent(ai_color)
	for r in range(board.size):
		if Const.zone_of_row(r) != my_zone:
			continue
		for c in range(board.size):
			var v: int = board.get_at(r, c)
			if v == ai_color:
				control += 1.0
			elif v == opp:
				control -= 1.0
	return control

# 被围困棋子数量（缓存命中）
func _count_trapped(session: GameSession, color: int) -> int:
	var count: int = 0
	for g in session.cached_sieged_groups():
		if g.color == color:
			count += g.stones.size()
	return count

# 特种部队威胁：对方未现形隐子数（己方视角威胁）
func _evaluate_special_threat(session: GameSession, ai_color: int) -> float:
	var threat := 0.0
	var opp: int = Const.opponent(ai_color)
	for p in session.special.pieces:
		if p.captured or not p.hidden:
			continue
		if p.color == opp:
			threat += 1.0
	return threat
