# 启发式 AI（简单难度）
#
# 策略（按优先级）：
#   1. 能提子就提（优先防御区歼灭分）
#   2. 己方有子被围困则尝试救援（连气/外逃）
#   3. 部署特种部队到敌境（若可用）
#   4. 选择价值最高的落子点（攻击区优先）
#   5. 无好棋则虚手
class_name HeuristicAI
extends "res://scripts/ai/BaseAI.gd"

func _do_choose(session: GameSession) -> Dictionary:
	var my_color: int = session.to_move
	# 1. 提子优先
	var capture_move = _find_best_capture(session, my_color)
	if not capture_move.is_empty():
		capture_move["type"] = "move"
		capture_move["reason"] = "提子"
		return capture_move

	# 2. 救援被围困的己方组群
	var rescue_move = _find_rescue(session, my_color)
	if not rescue_move.is_empty():
		rescue_move["type"] = "move"
		rescue_move["reason"] = "救援"
		return rescue_move

	# 3. 部署特种部队（概率性，在敌境渗透）
	if session.special.enabled and session.special.can_deploy(my_color, session.ply):
		if randf() < 0.3:  # 30% 概率部署
			var deploy_pos = _find_deploy_pos(session, my_color)
			if not deploy_pos.is_empty():
				return {"type": "deploy", "row": deploy_pos.row, "col": deploy_pos.col, "reason": "特种渗透"}

	# 4. 选择价值最高的落子点
	var best_move = _find_best_move(session, my_color)
	if not best_move.is_empty():
		best_move["type"] = "move"
		best_move["reason"] = "最优价值"
		return best_move

	# 5. 虚手
	return {"type": "pass", "row": -1, "col": -1, "reason": "无好棋"}

# 寻找最佳提子点
func _find_best_capture(session: GameSession, my_color: int) -> Dictionary:
	var best: Dictionary = {}
	var best_cap: int = 0
	var b: BoardModel = session.board
	for r in range(b.size):
		for c in range(b.size):
			if b.get_at(r, c) != Const.EMPTY:
				continue
			if not GoRules.is_legal(b, r, c, my_color, session.ko_point):
				continue
			var test = GoRules.try_move(b.clone(), r, c, my_color, session.ko_point)
			if test.captured.size() > best_cap:
				best_cap = test.captured.size()
				best = {"row": r, "col": c}
	return best

# 寻找救援点（己方组群仅剩1气时，尝试连气）
func _find_rescue(session: GameSession, my_color: int) -> Dictionary:
	var b: BoardModel = session.board
	for g in b.all_groups():
		if g.color != my_color:
			continue
		var libs: Array = b.liberties(g.stones)
		if libs.size() != 1:
			continue
		# 仅剩1气：尝试在该气点落子扩展
		var lib = libs[0]
		if GoRules.is_legal(b, lib[0], lib[1], my_color, session.ko_point):
			# 检查落子后是否真的增加了气
			var test = GoRules.try_move(b.clone(), lib[0], lib[1], my_color, session.ko_point)
			if test.legal:
				var new_g: Dictionary = b.clone().group_at(lib[0], lib[1])
				# 用 test 后的 board 检查
				var test_board = b.clone()
				GoRules.try_move(test_board, lib[0], lib[1], my_color, session.ko_point)
				var after_g: Dictionary = test_board.group_at(lib[0], lib[1])
				var after_libs: Array = test_board.liberties(after_g.stones)
				if after_libs.size() > 1:
					return {"row": lib[0], "col": lib[1]}
	return {}

# 寻找特种部队部署点（敌境空点）
func _find_deploy_pos(session: GameSession, my_color: int) -> Dictionary:
	var b: BoardModel = session.board
	var candidates: Array = []
	for r in range(b.size):
		for c in range(b.size):
			if b.get_at(r, c) != Const.EMPTY:
				continue
			# 优先敌境
			if Const.zone_of_row(r) == Const.enemy_zone(my_color):
				candidates.append({"row": r, "col": c})
	if candidates.is_empty():
		return {}
	return candidates[randi() % candidates.size()]

# 寻找价值最高的落子点
func _find_best_move(session: GameSession, my_color: int) -> Dictionary:
	var moves: Array = _legal_moves(session)
	if moves.is_empty():
		return {}
	var best: Dictionary = {}
	var best_val: int = -999
	for m in moves:
		var val: int = _move_value(session, m.row, m.col)
		if val > best_val:
			best_val = val
			best = m
	# 如果最佳价值 <= 0，有概率虚手
	if best_val <= 0 and randf() < 0.1:
		return {}
	return best
