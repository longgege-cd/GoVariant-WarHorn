# MCTS 增强模块（参考《AI对手算法设计文档》第五章）
#
# 4 阶段：选择(UCB1) → 扩展(快速候选) → 模拟(随机 rollout) → 回传
# 仅在关键局面启用（由 AIEngine 判断：资源紧张/分数接近/大量围困）
# 模拟数受 think_time 时间限制（尽力而为）
class_name MCTS
extends RefCounted

const MAX_SIMULATION_DEPTH: int = 30
const UCB_C: float = 1.414  # sqrt(2)

var candidate_generator: CandidateGenerator = null
var evaluator: EvaluationFunction = null
var _deadline_ms: int = 0

# MCTS 节点
class MCTSNode:
	var session: GameSession
	var parent: MCTSNode = null
	var move: Dictionary = {}  # 导致此节点的移动
	var children: Array = []   # Array[MCTSNode]
	var visits: int = 0
	var wins: float = 0.0      # 从 root color 视角的累积得分
	var untried_moves: Array = []
	var is_expanded: bool = false

	func _init(s: GameSession, p: MCTSNode = null, m: Dictionary = {}) -> void:
		session = s
		parent = p
		move = m

func _is_time_up() -> bool:
	return Time.get_ticks_msec() >= _deadline_ms

func search(session: GameSession, ai_color: int, simulations: int, budget_sec: float) -> Dictionary:
	_deadline_ms = Time.get_ticks_msec() + int(budget_sec * 1000.0)
	var root: MCTSNode = MCTSNode.new(session.clone_for_ai(ai_color), null, {})
	root.untried_moves = candidate_generator.generate_quick_candidates(root.session, root.session.to_move, 20)
	if root.untried_moves.is_empty():
		return {"type": "pass", "row": -1, "col": -1, "reason": "MCTS 无合法点"}

	var iterations: int = 0
	while iterations < simulations and not _is_time_up():
		iterations += 1
		# 1. 选择
		var node: MCTSNode = _select(root)
		# 2. 扩展
		if not node.is_expanded and not node.untried_moves.is_empty():
			node = _expand(node)
		# 3. 模拟
		var score: float = _simulate(node.session, ai_color)
		# 4. 回传
		_backpropagate(node, score)

	# 选择访问次数最多的子节点
	var best_child: MCTSNode = null
	var best_visits: int = -1
	for child in root.children:
		if child.visits > best_visits:
			best_visits = child.visits
			best_child = child

	var result: Dictionary
	if best_child == null or not best_child.move.has("row"):
		result = {"type": "pass", "row": -1, "col": -1, "reason": "MCTS 无结果"}
	else:
		result = {"type": "move", "row": best_child.move.row, "col": best_child.move.col, "reason": "MCTS 访问最多(%d次)" % best_child.visits}
	# 清理节点树（断开 parent/children 循环引用，避免 ObjectDB 泄漏）
	_clear_tree(root)
	return result

# 递归清理节点树
func _clear_tree(node: MCTSNode) -> void:
	for child in node.children:
		child.parent = null
		_clear_tree(child)
	node.children.clear()

# UCB1 选择
func _select(root: MCTSNode) -> MCTSNode:
	var node: MCTSNode = root
	while node.is_expanded and not node.children.is_empty():
		var best: MCTSNode = null
		var best_ucb: float = -9999.0
		for child in node.children:
			if child.visits == 0:
				return child  # 未访问优先
			var ucb: float = child.wins / child.visits + UCB_C * sqrt(log(node.visits) / child.visits)
			if ucb > best_ucb:
				best_ucb = ucb
				best = child
		if best == null:
			break
		node = best
	return node

# 扩展
func _expand(node: MCTSNode) -> MCTSNode:
	if node.untried_moves.is_empty():
		node.is_expanded = true
		return node
	var move: Dictionary = node.untried_moves.pop_back()
	if node.untried_moves.is_empty():
		node.is_expanded = true
	var clone: GameSession = node.session.clone()
	var out: Dictionary
	if move.get("type", "move") == "pass":
		out = clone.do_pass(clone.to_move)
	else:
		out = clone.play_move(clone.to_move, move.row, move.col)
	if not out.ok:
		return node  # 跳过非法
	var child: MCTSNode = MCTSNode.new(clone, node, move)
	child.untried_moves = candidate_generator.generate_quick_candidates(clone, clone.to_move, 20)
	node.children.append(child)
	return child

# 随机 rollout（快速候选，按评分加权）
func _simulate(session: GameSession, root_color: int) -> float:
	var sim: GameSession = session.clone()
	sim.emit_signals = false  # 加速：关闭信号
	var ply: int = 0
	while ply < MAX_SIMULATION_DEPTH and not sim.game_over and not _is_time_up():
		ply += 1
		var move: Dictionary = _rollout_move(sim)
		if move.get("type", "move") == "pass":
			sim.do_pass(sim.to_move)
		else:
			sim.play_move(sim.to_move, move.row, move.col)
	# 用评估函数打分（含分数差/资源/边境/围困等）
	return evaluator.evaluate(sim, root_color)

# rollout 移动选择（按评分加权随机）
func _rollout_move(session: GameSession) -> Dictionary:
	var moves: Array = candidate_generator.generate_quick_candidates(session, session.to_move, 12)
	if moves.is_empty():
		return {"type": "pass", "row": -1, "col": -1}
	# 70% 取前 3 高评分，30% 全范围加权随机
	if randf() < 0.7 and moves.size() > 0:
		var top_n: int = min(3, moves.size())
		var m: Dictionary = moves[randi() % top_n]
		return {"type": "move", "row": m.row, "col": m.col}
	var m: Dictionary = moves[randi() % moves.size()]
	return {"type": "move", "row": m.row, "col": m.col}

# 回传
func _backpropagate(node: MCTSNode, score: float) -> void:
	var n: MCTSNode = node
	while n != null:
		n.visits += 1
		n.wins += score
		n = n.parent
