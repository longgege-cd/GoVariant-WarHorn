# MCTS AI（困难难度）
#
# 蒙特卡洛树搜索（4阶段：选择→扩展→模拟→回传）
#
# 优化：
#   - UCB1 选择策略
#   - 随机 rollout（限时）
#   - 候选移动预筛（仅前 N 个，按启发式排序）
#   - 仿真数受 search_budget_sec 限制
class_name MCTSAI
extends "res://scripts/ai/BaseAI.gd"

const MAX_CANDIDATES: int = 12
const ROLLOUT_MAX_PLY: int = 60  # 单次 rollout 最大手数
const UCB_C: float = 1.414  # sqrt(2)

# MCTS 节点
class MCTSNode:
	var session: GameSession
	var parent: MCTSNode = null
	var move: Dictionary = {}  # 导致此节点的移动
	var children: Array = []   # Array[MCTSNode]
	var visits: int = 0
	var wins: float = 0.0      # 从 root color 视角的胜率
	var untried_moves: Array = []
	var is_expanded: bool = false

	func _init(s: GameSession, p: MCTSNode = null, m: Dictionary = {}) -> void:
		session = s
		parent = p
		move = m

func _do_choose(session: GameSession) -> Dictionary:
	var my_color: int = session.to_move
	# 特种部队：偶尔部署
	if session.special.enabled and session.special.can_deploy(my_color, session.ply):
		if randf() < 0.25:
			var deploy_pos = _find_deploy_pos(session, my_color)
			if not deploy_pos.is_empty():
				return {"type": "deploy", "row": deploy_pos.row, "col": deploy_pos.col, "reason": "特种渗透"}

	# 创建根节点
	var root: MCTSNode = MCTSNode.new(session.clone(), null, {})
	root.untried_moves = _ranked_candidates(session, my_color)
	if root.untried_moves.is_empty():
		return {"type": "pass", "row": -1, "col": -1, "reason": "无合法点"}

	# MCTS 迭代
	var iterations: int = 0
	while not _time_up() and iterations < 200:
		iterations += 1
		# 1. 选择
		var node: MCTSNode = _select(root)
		# 2. 扩展
		if not node.is_expanded and not node.untried_moves.is_empty():
			node = _expand(node)
		# 3. 模拟
		var score: float = _simulate(node.session, my_color)
		# 4. 回传
		_backpropagate(node, score, my_color)

	# 选择访问次数最多的子节点
	var best_child: MCTSNode = null
	var best_visits: int = -1
	for child in root.children:
		if child.visits > best_visits:
			best_visits = child.visits
			best_child = child

	if best_child == null or not best_child.move.has("row"):
		return {"type": "pass", "row": -1, "col": -1, "reason": "MCTS 无结果"}

	return {"type": "move", "row": best_child.move.row, "col": best_child.move.col, "reason": "MCTS 访问最多(%d次)" % best_child.visits}

# UCB1 选择
func _select(root: MCTSNode) -> MCTSNode:
	var node: MCTSNode = root
	while node.is_expanded and not node.children.is_empty():
		var best: MCTSNode = null
		var best_ucb: float = -9999.0
		for child in node.children:
			if child.visits == 0:
				return child  # 未访问的优先
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
	# 取一个未尝试的移动
	var move: Dictionary = node.untried_moves.pop_back()
	if node.untried_moves.is_empty():
		node.is_expanded = true
	# 克隆并执行
	var clone: GameSession = node.session.clone()
	var out: Dictionary
	if move.get("type", "move") == "pass":
		out = clone.do_pass(clone.to_move)
	else:
		out = clone.play_move(clone.to_move, move.row, move.col)
	if not out.ok:
		return node  # 跳过非法
	var child: MCTSNode = MCTSNode.new(clone, node, move)
	child.untried_moves = _ranked_candidates(clone, clone.to_move)
	node.children.append(child)
	return child

# 随机 rollout
func _simulate(session: GameSession, root_color: int) -> float:
	var sim: GameSession = session.clone()
	sim.emit_signals = false  # 加速：关闭信号
	var ply: int = 0
	while ply < ROLLOUT_MAX_PLY and not sim.game_over:
		ply += 1
		var move: Dictionary = _rollout_move(sim)
		if move.type == "pass":
			sim.do_pass(sim.to_move)
		else:
			sim.play_move(sim.to_move, move.row, move.col)
	# 评估终局
	var sc: Dictionary = sim.scores()
	var my: int = sc.black.total() if root_color == Const.BLACK else sc.white.total()
	var opp: int = sc.white.total() if root_color == Const.BLACK else sc.black.total()
	if my > opp:
		return 1.0
	elif my < opp:
		return 0.0
	return 0.5

# rollout 移动选择（快速随机 + 启发式偏好）
func _rollout_move(session: GameSession) -> Dictionary:
	var moves: Array = _ranked_candidates(session, session.to_move)
	if moves.is_empty():
		return {"type": "pass", "row": -1, "col": -1}
	# 70% 取前 3，30% 随机
	if randf() < 0.7 and moves.size() > 0:
		var top_n: int = min(3, moves.size())
		var m = moves[randi() % top_n]
		return {"type": "move", "row": m.row, "col": m.col}
	var m = moves[randi() % moves.size()]
	return {"type": "move", "row": m.row, "col": m.col}

# 回传
func _backpropagate(node: MCTSNode, score: float, _root_color: int) -> void:
	var n: MCTSNode = node
	while n != null:
		n.visits += 1
		n.wins += score
		n = n.parent

# 获取排序后的候选移动
func _ranked_candidates(session: GameSession, c: int) -> Array:
	var moves: Array = []
	var b: BoardModel = session.board
	for r in range(b.size):
		for c2 in range(b.size):
			if b.get_at(r, c2) != Const.EMPTY:
				continue
			if not GoRules.is_legal(b, r, c2, c, session.ko_point):
				continue
			var val: int = _move_value(session, r, c2)
			moves.append({"row": r, "col": c2, "value": val})
	moves.sort_custom(func(a, b): return a.value > b.value)
	# 限制候选数
	if moves.size() > MAX_CANDIDATES:
		moves = moves.slice(0, MAX_CANDIDATES)
	return moves

# 寻找特种部队部署点（敌境空点）
func _find_deploy_pos(session: GameSession, my_color: int) -> Dictionary:
	var b: BoardModel = session.board
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
