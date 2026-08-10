# AI 基类：定义统一接口，所有 AI 等级继承此类
#
# 接口：
#   choose_move(session) -> Dictionary
#     返回 {"type": "move"/"pass"/"deploy", "row": int, "col": int, "reason": String}
#
# 设计：
#   - 纯逻辑（RefCounted），不依赖 Godot 节点
#   - 使用 GameSession.clone() 进行搜索，不影响真实对局
#   - 限时：search_budget_sec 控制搜索时间上限
class_name BaseAI
extends RefCounted

var color: int = Const.BLACK
var search_budget_sec: float = 1.0  # 搜索时间上限
var _start_time: float = 0.0

func _init(c: int = Const.BLACK) -> void:
	color = c

# 主接口：选择一步棋
func choose_move(session: GameSession) -> Dictionary:
	_start_time = Time.get_ticks_msec() / 1000.0
	return _do_choose(session)

# 子类实现
func _do_choose(_session: GameSession) -> Dictionary:
	return {"type": "pass", "row": -1, "col": -1, "reason": "未实现"}

# ===== 通用工具 =====

# 检查搜索是否超时
func _time_up() -> bool:
	return (Time.get_ticks_msec() / 1000.0) - _start_time >= search_budget_sec

# 获取 AI 视角的棋盘克隆：对手的未现形隐子视为空点（规则：隐子对对手不可见）
# 用于 AI 决策（候选生成/合法性/价值评估），不影响真实 session
func _ai_view_board(session: GameSession) -> BoardModel:
	var b: BoardModel = session.board.clone()
	if not session.special.enabled:
		return b
	var opp: int = Const.opponent(color)
	for p in session.special.pieces:
		if p.captured or not p.hidden:
			continue
		if p.color != opp:
			continue
		# 对手隐子 → 在 AI 视图中视为空点
		b.set_at(p.pos.y, p.pos.x, Const.EMPTY)
	return b

# 获取所有合法落子点（随机顺序，避免AI总下同一位置）
# 使用 AI 视角棋盘（对手隐子视为空点），保证 AI 不知晓隐子位置
func _legal_moves(session: GameSession) -> Array:
	var moves: Array = []
	var b: BoardModel = _ai_view_board(session)
	for r in range(b.size):
		for c in range(b.size):
			if b.get_at(r, c) != Const.EMPTY:
				continue
			if GoRules.is_legal(b, r, c, session.to_move, session.ko_point):
				moves.append({"row": r, "col": c})
	# 简单洗牌
	moves.shuffle()
	return moves

# 评估局面（从 color 视角）：分数差 + 位置启发
func _evaluate(session: GameSession, eval_color: int) -> float:
	var sc: Dictionary = session.scores()
	var my: int = sc.black.total() if eval_color == Const.BLACK else sc.white.total()
	var opp: int = sc.white.total() if eval_color == Const.BLACK else sc.black.total()
	return float(my - opp)

# 快速评估某落子点的即时价值（用于启发式排序）
# 使用 AI 视角棋盘，保证评估不依赖对手隐子信息
func _move_value(session: GameSession, row: int, col: int) -> int:
	var b: BoardModel = _ai_view_board(session)
	var value: int = 0
	# 1. 提子价值：模拟落子看能提多少
	var test = GoRules.try_move(b.clone(), row, col, session.to_move, session.ko_point)
	if test.legal:
		value += test.captured.size() * 10
		# 歼灭分加成（在防御区提子）
		for cap in test.captured:
			if Const.is_defense_zone(cap.y, session.to_move):
				value += 5
	# 2. 占领分：在攻击区（敌境/边境）落子 +1
	if Const.is_attack_zone(row, session.to_move):
		value += 2
	# 3. 避免自填眼/边角（简单惩罚）
	if row == 0 or row == 18 or col == 0 or col == 18:
		value -= 1
	return value
