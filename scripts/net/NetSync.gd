# 联机操作同步节点（autoload）
#
# 职责：
#   - 持有当前对局 GameSession 引用（由 GameScreen 设置）
#   - 提供本地操作发送接口（本地执行 + RPC 通知对端）
#   - 接收对端 RPC 操作并应用到本地 session
#   - 操作同步模型：双方运行相同规则引擎，确保状态一致
#
# RPC 协议（操作同步）：
#   remote_play_move(row, col)     对端落子
#   remote_do_pass()               对端虚手
#   remote_deploy_special(row,col) 对端部署特种
#   remote_resign()                对端认输
#   remote_new_game(komi, special) 对端（主机）发起新对局配置
#
# 颜色约定：主机=黑，客户端=白。各端只操作己方颜色。
extends Node

# 当前活动的 session（由 GameScreen 设置）
var session: GameSession = null
# 是否联机对战中（由 GameScreen 设置）
var active: bool = false

# ===== 本地操作发送 =====
# 本地玩家落子（先本地执行，成功后 RPC 通知对端）
func local_play_move(row: int, col: int) -> Dictionary:
	if session == null:
		return {"ok": false, "reason": "无活动对局"}
	var color: int = NetworkManager.local_color
	var out: Dictionary = session.play_move(color, row, col)
	if out.ok and NetworkManager.is_online():
		remote_play_move.rpc_id(NetworkManager.remote_peer_id(), row, col)
	return out

# 本地玩家虚手
func local_do_pass() -> Dictionary:
	if session == null:
		return {"ok": false, "reason": "无活动对局"}
	var color: int = NetworkManager.local_color
	var out: Dictionary = session.do_pass(color)
	if out.ok and NetworkManager.is_online():
		remote_do_pass.rpc_id(NetworkManager.remote_peer_id())
	return out

# 本地玩家部署特种
func local_deploy_special(row: int, col: int) -> Dictionary:
	if session == null:
		return {"ok": false, "reason": "无活动对局"}
	var color: int = NetworkManager.local_color
	var out: Dictionary = session.deploy_special(color, row, col)
	if out.ok and NetworkManager.is_online():
		remote_deploy_special.rpc_id(NetworkManager.remote_peer_id(), row, col)
	return out

# 本地玩家认输
func local_resign() -> void:
	if session == null:
		return
	if NetworkManager.is_online():
		remote_resign.rpc_id(NetworkManager.remote_peer_id())

# 主机发起新对局配置同步（主机权威）
func host_broadcast_new_game(komi: float, special_enabled: bool) -> void:
	if NetworkManager.is_online() and NetworkManager.is_host():
		remote_new_game.rpc_id(NetworkManager.remote_peer_id(), komi, special_enabled)

# ===== 对端 RPC 接收 =====
# any_peer: 任意对端可调用；call_remote: 不本地执行；reliable: 可靠传输
@rpc("any_peer", "call_remote", "reliable")
func remote_play_move(row: int, col: int) -> void:
	if session == null or not active:
		return
	# 对端颜色 = 本地颜色的对手
	var remote_color: int = Const.opponent(NetworkManager.local_color)
	var out: Dictionary = session.play_move(remote_color, row, col)
	if not out.ok:
		Log.w("NetSync: 对端落子非法 (row=%d col=%d): %s" % [row, col, out.reason])
		# 同步失败：触发状态纠偏请求（可扩展）
		sync_mismatch.emit()

@rpc("any_peer", "call_remote", "reliable")
func remote_do_pass() -> void:
	if session == null or not active:
		return
	var remote_color: int = Const.opponent(NetworkManager.local_color)
	var out: Dictionary = session.do_pass(remote_color)
	if not out.ok:
		Log.w("NetSync: 对端虚手非法: %s" % out.reason)
		sync_mismatch.emit()

@rpc("any_peer", "call_remote", "reliable")
func remote_deploy_special(row: int, col: int) -> void:
	if session == null or not active:
		return
	var remote_color: int = Const.opponent(NetworkManager.local_color)
	var out: Dictionary = session.deploy_special(remote_color, row, col)
	if not out.ok:
		Log.w("NetSync: 对端部署特种非法 (row=%d col=%d): %s" % [row, col, out.reason])
		sync_mismatch.emit()

@rpc("any_peer", "call_remote", "reliable")
func remote_resign() -> void:
	if session == null or not active:
		return
	# 对端认输 → 本地端获胜
	var loser: int = Const.opponent(NetworkManager.local_color)
	var winner_str: String = "白方胜" if loser == Const.BLACK else "黑方胜"
	session.game_over = true
	var result: Dictionary = session.final_result("对端认输")
	result["winner"] = winner_str
	result["reason"] = "%s认输" % ("黑方" if loser == Const.BLACK else "白方")
	session.game_ended.emit(result)

@rpc("authority", "call_remote", "reliable")
func remote_new_game(komi: float, special_enabled: bool) -> void:
	# 主机权威广播新对局配置
	if not NetworkManager.is_host():
		new_game_requested.emit(komi, special_enabled)

# 同步失败信号（用于触发状态纠偏或断线提示）
signal sync_mismatch
# 主机发起的新对局请求（客户端接收）
signal new_game_requested(komi: float, special_enabled: bool)
