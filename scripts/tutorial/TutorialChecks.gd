# 教程关卡完成判定（纯逻辑，可独立测试）
#
# 各 target 的完成条件：
#   place            成功落一手（ply > 0）
#   capture          最近一手发生提吃
#   annihilate       黑方歼灭分 > 0（己方领土提吃）
#   enclosure        存在己方（玩家色）围空
#   siege            存在围困组群
#   border_enclosure 存在己方围空 且 存在围困组群
#   pass             已执行虚手（连续虚手计数 > 0）
#   ko               存在劫点
#   deploy           已部署特种部队
class_name TutorialChecks
extends RefCounted

static func is_complete(target: String, session: GameSession, player_color: int, extra: Dictionary = {}) -> bool:
	match target:
		"place":
			return session.ply > 0
		"capture":
			return has_capture(session, extra)
		"annihilate":
			return int(session.counters.get(Const.BLACK, {}).get("annihilate", 0)) > 0
		"enclosure":
			return has_player_enclosure(session, player_color)
		"siege":
			return has_siege(session)
		"border_enclosure":
			return has_player_enclosure(session, player_color) and has_siege(session)
		"pass":
			return bool(extra.get("pass_done", false))
		"ko":
			return session.ko_point != GoRules.NO_KO
		"deploy":
			return session.special.pieces.size() > 0
	return false

static func has_capture(session: GameSession, extra: Dictionary = {}) -> bool:
	# 优先使用最近一手的结果（last_outcome 仅终局时填充）
	var out: Dictionary = extra.get("last_outcome", {})
	if out.is_empty():
		out = session.last_outcome
	return out.get("captures", []).size() > 0

static func has_player_enclosure(session: GameSession, player_color: int) -> bool:
	for e in session.cached_enclosures():
		if e.color == player_color:
			return true
	return false

static func has_siege(session: GameSession) -> bool:
	return session.cached_sieged_groups().size() > 0

# 区域判定（1-1）：0=黑方领土 1=边境线 2=白方领土
static func zone_of(row: int) -> int:
	if row == Const.BORDER_ROW:
		return 1
	elif row > Const.BORDER_ROW:
		return 2
	return 0
