# 特种部队（可选规则）管理器
#
# 关键设计（用户确认）：隐子「真实占据」其交叉点，参与气/吃子计算，对手不可见。
# 因此隐子在 BoardModel 中以普通棋子形式存在，「hidden」仅为显示元数据。
#
# 规则要点：
#   - 每局 2 次/方，不计入 171 兵力上限
#   - 冷却：不可连续使用，需间隔至少 1 个己方回合（实现为两次部署间 ply 差 >= 4）
#   - 持续 20 回合（双方各 20 手 = 40 ply），到期自动现形
#   - 暴露：对手落子重叠(伏击) / 落子四邻 / 到期
#   - 伏击：对手落子被移除，落子方战损 -1，防守方不得歼灭分，隐子现形
#   - 隐子被实际提吃：战损 -6，对方防御分仍 +2/子（若在防御区）
#   - 终局成功奖励：互斥三选一（敌后渗透/潜伏存活/协助防御），由 GameSession 终局计算
class_name SpecialForces
extends RefCounted

const USES_PER_GAME: int = 2
const DURATION_PLY: int = 40      # 20 回合 * 2 ply
const COOLDOWN_PLY: int = 4       # 间隔至少 1 个己方回合

var enabled: bool = false
var pieces: Array = []            # Array[Dictionary]
var uses_remaining: Dictionary = {}   # color -> int
var last_use_ply: Dictionary = {}     # color -> int

func _init() -> void:
	uses_remaining = { Const.BLACK: USES_PER_GAME, Const.WHITE: USES_PER_GAME }
	last_use_ply = { Const.BLACK: -9999, Const.WHITE: -9999 }

func reset() -> void:
	pieces.clear()
	uses_remaining = { Const.BLACK: USES_PER_GAME, Const.WHITE: USES_PER_GAME }
	last_use_ply = { Const.BLACK: -9999, Const.WHITE: -9999 }

func clone() -> SpecialForces:
	var sf := SpecialForces.new()
	sf.enabled = enabled
	sf.pieces = pieces.duplicate(true)
	sf.uses_remaining = uses_remaining.duplicate(true)
	sf.last_use_ply = last_use_ply.duplicate(true)
	return sf

# 是否可部署
func can_deploy(color: int, current_ply: int) -> bool:
	if not enabled:
		return false
	if int(uses_remaining.get(color, 0)) <= 0:
		return false
	if current_ply - int(last_use_ply.get(color, -9999)) < COOLDOWN_PLY:
		return false
	return true

# 部署隐子（调用方需保证该点为空且合法）
func deploy(pos: Vector2i, color: int, current_ply: int) -> Dictionary:
	uses_remaining[color] = int(uses_remaining.get(color, 0)) - 1
	last_use_ply[color] = current_ply
	var piece := {
		"pos": pos,
		"color": color,
		"hidden": true,
		"captured": false,
		"deployed_ply": current_ply,
		"expire_ply": current_ply + DURATION_PLY,
		"revealed_reason": "",
	}
	pieces.append(piece)
	return piece

# 取某点的隐子（任意色，未现形未被捕）
func hidden_at(pos: Vector2i) -> Dictionary:
	for p in pieces:
		if not p.captured and p.hidden and p.pos == pos:
			return p
	return {}

func has_hidden_at(pos: Vector2i) -> bool:
	return not hidden_at(pos).is_empty()

# 取对手隐子（用于伏击检测）
func hidden_opponent_at(pos: Vector2i, mover_color: int) -> Dictionary:
	var p: Dictionary = hidden_at(pos)
	if p.is_empty():
		return {}
	if p.color != mover_color:  # 隐子属于对方
		return p
	return {}

# 落子点四邻的对手隐子（暴露触发）
func hidden_opponent_adjacent(board: BoardModel, pos: Vector2i, mover_color: int) -> Array:
	var out: Array = []
	for p in pieces:
		if p.captured or not p.hidden:
			continue
		if p.color == mover_color:
			continue
		# 四邻
		for n in board.neighbors(pos.y, pos.x):
			if p.pos.x == n[1] and p.pos.y == n[0]:
				out.append(p)
				break
	return out

# 现形
func reveal(piece: Dictionary, reason: String = "") -> void:
	if piece.is_empty():
		return
	piece.hidden = false
	piece.revealed_reason = reason

# 检查到期现形，返回新现形的棋子列表
func check_expiry(current_ply: int) -> Array:
	var out: Array = []
	for p in pieces:
		if p.captured or not p.hidden:
			continue
		if current_ply >= p.expire_ply:
			p.hidden = false
			p.revealed_reason = "到期"
			out.append(p)
	return out

# 该点是否有特种部队（隐或现，未被捕）
func is_special_at(pos: Vector2i) -> bool:
	for p in pieces:
		if not p.captured and p.pos == pos:
			return true
	return false

func get_special_at(pos: Vector2i) -> Dictionary:
	for p in pieces:
		if not p.captured and p.pos == pos:
			return p
	return {}

# 标记被提吃（返回该棋子，供战损 -6 计算）
func mark_captured(pos: Vector2i) -> Dictionary:
	var p: Dictionary = get_special_at(pos)
	if not p.is_empty():
		p.captured = true
	return p

# 某色剩余次数
func uses_left(color: int) -> int:
	return int(uses_remaining.get(color, 0))

# 某色未被捕且存活（在盘上）的特种棋子（终局奖励判定用）
func alive_pieces(color: int) -> Array:
	return pieces.filter(func(p): return not p.captured and p.color == color)
