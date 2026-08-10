# Lookahead AI（中等难度）
#
# 策略：2层 minimax + alpha-beta 剪枝
#   1. 我方落子 → 评估
#   2. 对方最佳应对 → 评估
#   3. 选择对我方最优的结果
#
# 优化：
#   - 候选移动按启发式排序（提子优先、攻击区优先）
#   - 仅搜索前 N 个候选（限时）
class_name LookaheadAI
extends "res://scripts/ai/BaseAI.gd"

const MAX_CANDIDATES: int = 15  # 每层最大候选数

func _do_choose(session: GameSession) -> Dictionary:
	var my_color: int = session.to_move
	# 获取排序后的候选移动（基于 AI 视角，不含对手隐子）
	var candidates: Array = _ranked_candidates(session, my_color)
	if candidates.is_empty():
		return {"type": "pass", "row": -1, "col": -1, "reason": "无合法点"}
	# 限制候选数
	if candidates.size() > MAX_CANDIDATES:
		candidates = candidates.slice(0, MAX_CANDIDATES)

	var best_score: float = -9999.0
	var best_move: Dictionary = {"type": "pass", "row": -1, "col": -1, "reason": "默认虚手"}
	var alpha: float = -9999.0
	var beta: float = 9999.0

	for m in candidates:
		if _time_up():
			break
		# 使用 AI 视角克隆搜索（对手隐子已移除）
		var clone: GameSession = session.clone_for_ai(my_color)
		var out: Dictionary = clone.play_move(my_color, m.row, m.col)
		if not out.ok:
			continue
		# 2层搜索：对方最佳应对
		var score: float = _minimize(clone, alpha, beta, 1)
		if score > best_score:
			best_score = score
			best_move = {"type": "move", "row": m.row, "col": m.col, "reason": "搜索最优"}
		alpha = max(alpha, score)

	# 特种部队：偶尔部署
	if session.special.enabled and session.special.can_deploy(my_color, session.ply):
		if randf() < 0.2:
			var deploy_pos = _find_deploy_pos(session, my_color)
			if not deploy_pos.is_empty():
				return {"type": "deploy", "row": deploy_pos.row, "col": deploy_pos.col, "reason": "特种渗透"}

	return best_move

# 最小层（对方应对）
func _minimize(session: GameSession, alpha: float, beta: float, depth: int) -> float:
	if depth <= 0 or session.game_over or _time_up():
		return _evaluate(session, color)
	var opp: int = Const.opponent(color)
	var candidates: Array = _ranked_candidates(session, opp)
	if candidates.size() > MAX_CANDIDATES:
		candidates = candidates.slice(0, MAX_CANDIDATES)
	var worst: float = 9999.0
	for m in candidates:
		var clone: GameSession = session.clone()
		var out: Dictionary = clone.play_move(opp, m.row, m.col)
		if not out.ok:
			continue
		var score: float = _evaluate(clone, color)  # 从我方视角评估
		worst = min(worst, score)
		beta = min(beta, score)
		if beta <= alpha:
			break  # alpha-beta 剪枝
	if worst == 9999.0:
		return _evaluate(session, color)
	return worst

# 获取排序后的候选移动（按启发式价值降序）
# 使用 AI 视角棋盘（对手隐子视为空点）
func _ranked_candidates(session: GameSession, c: int) -> Array:
	var moves: Array = []
	var b: BoardModel = _ai_view_board(session)
	for r in range(b.size):
		for c2 in range(b.size):
			if b.get_at(r, c2) != Const.EMPTY:
				continue
			if not GoRules.is_legal(b, r, c2, c, session.ko_point):
				continue
			var val: int = _move_value(session, r, c2)
			moves.append({"row": r, "col": c2, "value": val})
	# 按价值降序排序
	moves.sort_custom(func(a, b): return a.value > b.value)
	return moves

# 寻找特种部队部署点（敌境空点）
func _find_deploy_pos(session: GameSession, my_color: int) -> Dictionary:
	var b: BoardModel = _ai_view_board(session)
	var candidates: Array = []
	for r in range(b.size):
		for c in range(b.size):
			if b.get_at(r, c) != Const.EMPTY:
				continue
			if Const.zone_of_row(r) == Const.enemy_zone(my_color):
				candidates.append({"row": r, "col": c})
	if candidates.is_empty():
		return {}
	return candidates[randi() % candidates.size()]
