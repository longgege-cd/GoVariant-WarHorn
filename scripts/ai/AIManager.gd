# AI 管理器：按难度创建 AI 引擎实例，协调 AI 行棋
#
# 难度等级（参考《AI对手算法设计文档》第六章）：
#   EASY   = 简单（15 候选 / 深1）
#   NORMAL = 普通（25 候选 / 深2）
#   HARD   = 困难（40 候选 / 深3）
#   EXPERT = 专家（40 候选 / 深3 + 关键局面 MCTS 200 模拟）
#   MASTER = 大师（50 候选 / 深4 + 关键局面 MCTS 500 模拟）
#
# 用法：
#   var ai = AIManager.create(AIManager.Difficulty.NORMAL, Const.WHITE)
#   var move = ai.choose_move(session)
#   match move.type:
#       "move": session.play_move(...)
#       "pass": session.do_pass(...)
#       "deploy": session.deploy_special(...)
class_name AIManager
extends RefCounted

enum Difficulty { EASY, NORMAL, HARD, EXPERT, MASTER }

const AIEngineScript = preload("res://scripts/ai/AIEngine.gd")

# 创建 AI 实例（按难度配置引擎）
static func create(difficulty: int, color: int):
	return AIEngineScript.new(color, difficulty)

# 难度名称
static func difficulty_name(d: int) -> String:
	return AIDifficulty.name_of(d)

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
