# AI 引擎总控（参考《AI对手算法设计文档》第七章）
#
# 集成：候选着法生成器 + 评估函数 + alpha-beta 搜索引擎 + MCTS 增强
# 难度由 AIDifficulty 配置驱动（简单/普通/困难/专家/大师）
#
# 接口兼容 BaseAI：choose_move(session) -> Dictionary
#   {"type": "move"/"pass"/"deploy", "row", "col", "reason"}
class_name AIEngine
extends "res://scripts/ai/BaseAI.gd"

const AIDifficultyScript = preload("res://scripts/ai/AIDifficulty.gd")
const CandidateGenerator = preload("res://scripts/ai/CandidateGenerator.gd")
const EvaluationFunction = preload("res://scripts/ai/EvaluationFunction.gd")
const SearchEngine = preload("res://scripts/ai/SearchEngine.gd")
const MCTSScript = preload("res://scripts/ai/MCTS.gd")

var difficulty: int = AIDifficultyScript.Difficulty.NORMAL
var config: Dictionary = {}
var candidate_generator
var evaluator
var search_engine
var mcts

func _init(c: int = Const.BLACK, d: int = AIDifficultyScript.Difficulty.NORMAL) -> void:
	super(c)
	set_difficulty(d)

func set_difficulty(d: int) -> void:
	difficulty = d
	config = AIDifficultyScript.get_config(d)
	search_budget_sec = float(config.get("think_time_ms", 1000)) / 1000.0
	candidate_generator = CandidateGenerator.new()
	evaluator = EvaluationFunction.new()
	search_engine = SearchEngine.new()
	mcts = MCTSScript.new()
	search_engine.candidate_generator = candidate_generator
	search_engine.evaluator = evaluator
	mcts.candidate_generator = candidate_generator
	mcts.evaluator = evaluator

func _do_choose(session: GameSession) -> Dictionary:
	# 特种部队：可选规则开启时偶尔主动部署（低概率，多数交由候选生成器）
	var mcts_sims: int = int(config.get("mcts_simulations", 0))
	# 专家/大师：关键局面启用 MCTS
	if mcts_sims > 0 and _should_use_mcts(session, color):
		return mcts.search(session, color, mcts_sims, search_budget_sec)
	return search_engine.find_best_move(session, color, config, search_budget_sec)

# 关键局面判断（文档 5.1）：资源紧张 / 分数接近 / 大量棋子被围困
func _should_use_mcts(session: GameSession, ai_color: int) -> bool:
	var opp: int = Const.opponent(ai_color)
	var max_stones: int = max(session.piece_limit, 1)
	var ai_stones: int = session.pieces_left(ai_color)
	var opp_stones: int = session.pieces_left(opp)
	var resource_critical: bool = float(ai_stones) / float(max_stones) < 0.2
	var sc: Dictionary = session.scores()
	var my: int = sc.black.total() if ai_color == Const.BLACK else sc.white.total()
	var opp_score: int = sc.white.total() if ai_color == Const.BLACK else sc.black.total()
	var score_close: bool = abs(my - opp_score) < 5
	var trapped_count: int = 0
	for g in session.cached_sieged_groups():
		if g.color == ai_color:
			trapped_count += g.stones.size()
	var trapped_critical: bool = trapped_count > 5
	return resource_critical or score_close or trapped_critical
