# AI 管理器：按难度创建 AI 实例，协调 AI 行棋
#
# 难度等级：
#   EASY   = 启发式 AI（提子/救援/价值选择）
#   MEDIUM = Lookahead AI（2层 minimax + alpha-beta）
#   HARD   = MCTS AI（蒙特卡洛树搜索）
#
# 用法：
#   var ai = AIManager.create(AIManager.Difficulty.MEDIUM, Const.WHITE)
#   var move = ai.choose_move(session)
#   match move.type:
#       "move": session.play_move(...)
#       "pass": session.do_pass(...)
#       "deploy": session.deploy_special(...)
class_name AIManager
extends RefCounted

enum Difficulty { EASY, MEDIUM, HARD }

const HeuristicAI = preload("res://scripts/ai/HeuristicAI.gd")
const LookaheadAI = preload("res://scripts/ai/LookaheadAI.gd")
const MCTSAI = preload("res://scripts/ai/MCTSAI.gd")

# 创建 AI 实例
static func create(difficulty: int, color: int):
	var ai
	match difficulty:
		Difficulty.EASY:
			ai = HeuristicAI.new(color)
			ai.search_budget_sec = 0.5
		Difficulty.MEDIUM:
			ai = LookaheadAI.new(color)
			ai.search_budget_sec = 1.0
		Difficulty.HARD:
			ai = MCTSAI.new(color)
			ai.search_budget_sec = 2.0
		_:
			ai = HeuristicAI.new(color)
			ai.search_budget_sec = 0.5
	return ai

# 难度名称
static func difficulty_name(d: int) -> String:
	match d:
		Difficulty.EASY:
			return "简单"
		Difficulty.MEDIUM:
			return "中等"
		Difficulty.HARD:
			return "困难"
		_:
			return "未知"

# 执行 AI 行棋（同步，返回 outcome）
static func play_ai_turn(session: GameSession, ai) -> Dictionary:
	var move: Dictionary = ai.choose_move(session)
	var color: int = session.to_move
	match move.get("type", "pass"):
		"move":
			return session.play_move(color, move.row, move.col)
		"deploy":
			return session.deploy_special(color, move.row, move.col)
		_:
			return session.do_pass(color)

# AI 异步任务对象（持有上下文，线程安全读取结果）
class AITask:
	extends RefCounted
	var session: GameSession
	var ai
	var move: Dictionary = {}
	var thread: Thread = null
	func _init(s: GameSession, a) -> void:
		session = s
		ai = a
	# 线程入口：计算 move（写入 self.move）
	func _run() -> void:
		move = ai.choose_move(session)
	# 启动线程（失败则同步降级）
	func start() -> void:
		thread = Thread.new()
		var err: int = thread.start(Callable(self, "_run"))
		if err != OK:
			_run()  # 降级同步
			thread = null
	# 是否仍在计算
	func is_running() -> bool:
		return thread != null and thread.is_alive()
	# 完成时调用（获取结果并回收线程）
	func finish() -> Dictionary:
		if thread != null:
			thread.wait_to_finish()
			thread = null
		return move

# 创建异步任务
static func create_task(session: GameSession, ai) -> AITask:
	return AITask.new(session, ai)
