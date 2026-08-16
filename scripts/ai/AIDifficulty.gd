# AI 难度分级（参考《AI对手算法设计文档》第六章）
#
# 5 档难度：简单/普通/困难/专家/大师
#   - max_candidates:   候选着法生成上限
#   - search_depth:      alpha-beta 搜索深度
#   - mcts_simulations:  MCTS 模拟次数（0=不启用 MCTS）
#   - think_time_ms:     AI 思考时间上限（毫秒）
class_name AIDifficulty
extends RefCounted

enum Difficulty { EASY, NORMAL, HARD, EXPERT, MASTER }

static func get_config(difficulty: int) -> Dictionary:
	match difficulty:
		Difficulty.EASY:
			return {
				"max_candidates": 15,
				"search_depth": 1,
				"mcts_simulations": 0,
				"think_time_ms": 500,
			}
		Difficulty.NORMAL:
			return {
				"max_candidates": 25,
				"search_depth": 2,
				"mcts_simulations": 0,
				"think_time_ms": 1500,
			}
		Difficulty.HARD:
			return {
				"max_candidates": 40,
				"search_depth": 3,
				"mcts_simulations": 0,
				"think_time_ms": 3000,
			}
		Difficulty.EXPERT:
			return {
				"max_candidates": 40,
				"search_depth": 3,
				"mcts_simulations": 200,
				"think_time_ms": 5000,
			}
		Difficulty.MASTER:
			return {
				"max_candidates": 50,
				"search_depth": 4,
				"mcts_simulations": 500,
				"think_time_ms": 6000,
			}
	return {}

# 难度显示名
static func name_of(d: int) -> String:
	match d:
		Difficulty.EASY:
			return "简单"
		Difficulty.NORMAL:
			return "普通"
		Difficulty.HARD:
			return "困难"
		Difficulty.EXPERT:
			return "专家"
		Difficulty.MASTER:
			return "大师"
	return "未知"

# 难度显示名翻译键（i18n）
static func name_key(d: int) -> String:
	match d:
		Difficulty.EASY:
			return "ai.easy"
		Difficulty.NORMAL:
			return "ai.normal"
		Difficulty.HARD:
			return "ai.hard"
		Difficulty.EXPERT:
			return "ai.expert"
		Difficulty.MASTER:
			return "ai.master"
	return "ai.unknown"

# 难度描述（用于二级选择页）
static func desc_of(d: int) -> String:
	match d:
		Difficulty.EASY:
			return "只看当前手评分"
		Difficulty.NORMAL:
			return "浅层搜索"
		Difficulty.HARD:
			return "标准搜索"
		Difficulty.EXPERT:
			return "标准搜索+关键局面MCTS"
		Difficulty.MASTER:
			return "更深搜索+更多模拟"
	return ""

# 难度描述翻译键（i18n）
static func desc_key(d: int) -> String:
	match d:
		Difficulty.EASY:
			return "ai.easy_desc"
		Difficulty.NORMAL:
			return "ai.normal_desc"
		Difficulty.HARD:
			return "ai.hard_desc"
		Difficulty.EXPERT:
			return "ai.expert_desc"
		Difficulty.MASTER:
			return "ai.master_desc"
	return ""
