# 搜索算法（参考《AI对手算法设计文档》第四章）
#
# 策略：
#   1. 根节点用完整战术候选生成器（质量高）
#   2. alpha-beta 内层用快速候选生成器（避免重复全盘战术检测）
#   3. 每层候选截断 SEARCH_SLICE 个（高评分优先，提高剪枝效率）
#   4. 受 think_time 时间限制（尽力而为搜索，超时返回当前最优）
class_name SearchEngine
extends RefCounted

const SEARCH_SLICE: int = 10

var candidate_generator: CandidateGenerator = null
var evaluator: EvaluationFunction = null
var _deadline_ms: int = 0

func _is_time_up() -> bool:
	return Time.get_ticks_msec() >= _deadline_ms

func find_best_move(session: GameSession, ai_color: int, config: Dictionary, budget_sec: float) -> Dictionary:
	_deadline_ms = Time.get_ticks_msec() + int(budget_sec * 1000.0)
	var max_candidates: int = int(config.get("max_candidates", 25))
	var depth: int = int(config.get("search_depth", 2))

	var candidates: Array = candidate_generator.generate_candidates(session, ai_color, max_candidates)
	if candidates.is_empty():
		return {"type": "pass", "row": -1, "col": -1, "reason": "无合法点"}
	var search_candidates: Array = candidates.slice(0, min(SEARCH_SLICE, candidates.size()))

	var best_move: Dictionary = {"type": "pass", "row": -1, "col": -1, "reason": "默认虚手"}
	var best_score: float = -INF
	for cand in search_candidates:
		if _is_time_up():
			break
		var clone: GameSession = session.clone_for_ai(ai_color)
		var out: Dictionary = clone.play_move(ai_color, cand.row, cand.col)
		if not out.ok:
			continue
		var score: float = _alpha_beta(clone, depth - 1, -INF, INF, false, ai_color, config)
		if score > best_score:
			best_score = score
			best_move = {"type": "move", "row": cand.row, "col": cand.col, "reason": cand.get("reason", "搜索最优")}

	# 深度1（简单档）或全部超时：退回最高评分候选
	if best_score == -INF and not search_candidates.is_empty():
		var first: Dictionary = search_candidates[0]
		best_move = {"type": "move", "row": first.row, "col": first.col, "reason": first.get("reason", "最高评分")}
	return best_move

# alpha-beta（maximizing=当前层是否最大化我方得分）
func _alpha_beta(session: GameSession, depth: int, alpha: float, beta: float, maximizing: bool, ai_color: int, config: Dictionary) -> float:
	if depth <= 0 or session.game_over or _is_time_up():
		return evaluator.evaluate(session, ai_color)
	var color: int = session.to_move
	var max_candidates: int = int(config.get("max_candidates", 25))
	var candidates: Array = candidate_generator.generate_quick_candidates(session, color, max_candidates)
	candidates = candidates.slice(0, min(SEARCH_SLICE, candidates.size()))
	if candidates.is_empty():
		# 无合法落子 → 虚手
		var clone: GameSession = session.clone()
		clone.do_pass(color)
		return _alpha_beta(clone, depth - 1, alpha, beta, not maximizing, ai_color, config)

	if maximizing:
		var max_score: float = -INF
		for cand in candidates:
			if _is_time_up():
				break
			var clone: GameSession = session.clone()
			var out: Dictionary = clone.play_move(color, cand.row, cand.col)
			if not out.ok:
				continue
			var score: float = _alpha_beta(clone, depth - 1, alpha, beta, false, ai_color, config)
			max_score = max(max_score, score)
			alpha = max(alpha, score)
			if beta <= alpha:
				break  # 剪枝
		if max_score == -INF:
			return evaluator.evaluate(session, ai_color)
		return max_score
	else:
		var min_score: float = INF
		for cand in candidates:
			if _is_time_up():
				break
			var clone: GameSession = session.clone()
			var out: Dictionary = clone.play_move(color, cand.row, cand.col)
			if not out.ok:
				continue
			var score: float = _alpha_beta(clone, depth - 1, alpha, beta, true, ai_color, config)
			min_score = min(min_score, score)
			beta = min(beta, score)
			if beta <= alpha:
				break  # 剪枝
		if min_score == INF:
			return evaluator.evaluate(session, ai_color)
		return min_score
