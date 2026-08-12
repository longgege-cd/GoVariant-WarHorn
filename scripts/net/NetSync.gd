# 联机操作同步节点（autoload）— 权威主机模型
#
# 职责：
#   - 持有当前对局 GameSession 引用（由 GameScreen 设置）
#   - 主机：权威执行本地操作 + 广播确认给客户端
#   - 客户端：发送操作请求给主机，收到主机确认后应用到本地 session
#   - 房间模式：主机点"开始游戏" → 推送配置 → 双方开始对局
#
# 架构（参考《联机对战.txt》权威主机模型）：
#   - 主机（Host）负责所有游戏逻辑的权威验证与执行
#   - 客户端（Client）不直接执行操作，只发请求、收确认
#   - 双方 GameSession 由主机权威驱动，天然状态一致
#
# RPC 协议（操作同步）：
#   request_move(row, col)            客户端→主机：请求落子
#   request_pass()                    客户端→主机：请求虚手
#   request_deploy_special(row, col)  客户端→主机：请求部署特种
#   request_resign()                  客户端→主机：请求认输
#   confirm_move(row, col, color)     主机→客户端：落子确认（双方应用）
#   confirm_pass(color)               主机→客户端：虚手确认
#   confirm_deploy_special(r,c,color) 主机→客户端：部署确认
#   confirm_game_over(result)         主机→客户端：终局广播
#   remote_new_game(komi, special, piece_limit)  主机→客户端：新对局
#   remote_start_game(time_setting, piece_limit, komi, special_enabled)  主机→客户端：开始游戏
#
# 颜色约定：主机=黑(peer_id=1)，客户端=白。请求中颜色由发送方 peer_id 推断。
extends Node

# 当前活动的 session（由 GameScreen 设置）
var session: GameSession = null
# 是否联机对战中（由 GameScreen 设置）
var active: bool = false

# ===== 本地操作发送 =====
# 主机：本地权威执行 + 广播确认；客户端：发送请求，等待主机确认
func local_play_move(row: int, col: int) -> Dictionary:
	if session == null:
		return {"ok": false, "reason": "无活动对局"}
	if NetworkManager.is_host():
		var out: Dictionary = session.play_move(NetworkManager.local_color, row, col)
		if out.ok and NetworkManager.is_online():
			confirm_move.rpc_id(NetworkManager.remote_peer_id(), row, col, NetworkManager.local_color)
		return out
	# 客户端：发请求，本地不执行（等待主机权威确认）
	if NetworkManager.is_online():
		request_move.rpc_id(1, row, col)
	return {"ok": true, "pending": true}

# 本地玩家虚手
func local_do_pass() -> Dictionary:
	if session == null:
		return {"ok": false, "reason": "无活动对局"}
	if NetworkManager.is_host():
		var out: Dictionary = session.do_pass(NetworkManager.local_color)
		if out.ok and NetworkManager.is_online():
			confirm_pass.rpc_id(NetworkManager.remote_peer_id(), NetworkManager.local_color)
		return out
	if NetworkManager.is_online():
		request_pass.rpc_id(1)
	return {"ok": true, "pending": true}

# 本地玩家部署特种
func local_deploy_special(row: int, col: int) -> Dictionary:
	if session == null:
		return {"ok": false, "reason": "无活动对局"}
	if NetworkManager.is_host():
		var out: Dictionary = session.deploy_special(NetworkManager.local_color, row, col)
		if out.ok and NetworkManager.is_online():
			confirm_deploy_special.rpc_id(NetworkManager.remote_peer_id(), row, col, NetworkManager.local_color)
		return out
	if NetworkManager.is_online():
		request_deploy_special.rpc_id(1, row, col)
	return {"ok": true, "pending": true}

# 本地玩家认输
func local_resign() -> void:
	if session == null:
		return
	if NetworkManager.is_host():
		_finish_by_resign(NetworkManager.local_color)
	elif NetworkManager.is_online():
		request_resign.rpc_id(1)

# 主机发起新对局配置同步（主机权威）
func host_broadcast_new_game(komi: float, special_enabled: bool, piece_limit: int = Const.PIECE_LIMIT) -> void:
	if NetworkManager.is_online() and NetworkManager.is_host():
		remote_new_game.rpc_id(NetworkManager.remote_peer_id(), komi, special_enabled, piece_limit)

# ===== 房间模式：开始游戏 =====
# 主机点"开始游戏"后调用：推送最终配置给客户端，双方开始对局
func host_start_game(time_setting: Dictionary, piece_limit: int, komi: float, special_enabled: bool) -> void:
	if NetworkManager.is_online() and NetworkManager.is_host():
		remote_start_game.rpc_id(NetworkManager.remote_peer_id(), time_setting, piece_limit, komi, special_enabled)

# ===== 客户端 → 主机：操作请求（any_peer） =====
@rpc("any_peer", "call_remote", "reliable")
func request_move(row: int, col: int) -> void:
	if not NetworkManager.is_host() or session == null or not active:
		return
	var color: int = _sender_color()
	var out: Dictionary = session.play_move(color, row, col)
	if not out.ok:
		Log.w("NetSync: 对端落子非法 (row=%d col=%d): %s" % [row, col, out.reason])
		sync_mismatch.emit()
		return
	if NetworkManager.is_online():
		confirm_move.rpc_id(NetworkManager.remote_peer_id(), row, col, color)

@rpc("any_peer", "call_remote", "reliable")
func request_pass() -> void:
	if not NetworkManager.is_host() or session == null or not active:
		return
	var color: int = _sender_color()
	var out: Dictionary = session.do_pass(color)
	if not out.ok:
		Log.w("NetSync: 对端虚手非法: %s" % out.reason)
		sync_mismatch.emit()
		return
	if NetworkManager.is_online():
		confirm_pass.rpc_id(NetworkManager.remote_peer_id(), color)

@rpc("any_peer", "call_remote", "reliable")
func request_deploy_special(row: int, col: int) -> void:
	if not NetworkManager.is_host() or session == null or not active:
		return
	var color: int = _sender_color()
	var out: Dictionary = session.deploy_special(color, row, col)
	if not out.ok:
		Log.w("NetSync: 对端部署特种非法 (row=%d col=%d): %s" % [row, col, out.reason])
		sync_mismatch.emit()
		return
	if NetworkManager.is_online():
		confirm_deploy_special.rpc_id(NetworkManager.remote_peer_id(), row, col, color)

@rpc("any_peer", "call_remote", "reliable")
func request_resign() -> void:
	if not NetworkManager.is_host() or session == null or not active:
		return
	_finish_by_resign(_sender_color())

# ===== 主机 → 客户端：操作确认（any_peer + is_host 守卫）
# 注：权威主机模型中 confirm_* 本应使用 authority 权限，但 Godot 4.7 在
# RPC 处理函数内部发送 authority 权限 RPC 会被拦截（客户端收不到）。
# 改用 any_peer + 函数内 is_host 守卫，安全性等价（客户端调用会被守卫拒绝）。
@rpc("any_peer", "call_remote", "reliable")
func confirm_move(row: int, col: int, color: int) -> void:
	if NetworkManager.is_host() or session == null or not active:
		return
	var out: Dictionary = session.play_move(color, row, col)
	if not out.ok:
		Log.w("NetSync: confirm_move 应用失败 (row=%d col=%d): %s" % [row, col, out.reason])
		sync_mismatch.emit()

@rpc("any_peer", "call_remote", "reliable")
func confirm_pass(color: int) -> void:
	if NetworkManager.is_host() or session == null or not active:
		return
	var out: Dictionary = session.do_pass(color)
	if not out.ok:
		Log.w("NetSync: confirm_pass 应用失败: %s" % out.reason)
		sync_mismatch.emit()

@rpc("any_peer", "call_remote", "reliable")
func confirm_deploy_special(row: int, col: int, color: int) -> void:
	if NetworkManager.is_host() or session == null or not active:
		return
	var out: Dictionary = session.deploy_special(color, row, col)
	if not out.ok:
		Log.w("NetSync: confirm_deploy_special 应用失败: %s" % out.reason)
		sync_mismatch.emit()

@rpc("any_peer", "call_remote", "reliable")
func confirm_game_over(result: Dictionary) -> void:
	if NetworkManager.is_host() or session == null:
		return
	session.game_over = true
	session.game_ended.emit(result)

# ===== 认输终局（主机侧执行 + 广播） =====
func _finish_by_resign(resigner_color: int) -> void:
	var winner_str: String = "白方胜" if resigner_color == Const.BLACK else "黑方胜"
	session.game_over = true
	var result: Dictionary = session.final_result("认输")
	result["winner"] = winner_str
	result["reason"] = "%s认输" % ("黑方" if resigner_color == Const.BLACK else "白方")
	session.game_ended.emit(result)
	if NetworkManager.is_online():
		confirm_game_over.rpc_id(NetworkManager.remote_peer_id(), result)

# ===== 房间模式：开始游戏 RPC =====
# 主机→客户端：开始游戏并推送最终配置
@rpc("any_peer", "call_remote", "reliable")
func remote_start_game(time_setting: Dictionary, piece_limit: int, komi: float, special_enabled: bool) -> void:
	if not NetworkManager.is_host():
		game_started.emit(time_setting, piece_limit, komi, special_enabled)

@rpc("any_peer", "call_remote", "reliable")
func remote_new_game(komi: float, special_enabled: bool, piece_limit: int = Const.PIECE_LIMIT) -> void:
	# 主机权威广播新对局配置
	if not NetworkManager.is_host():
		new_game_requested.emit(komi, special_enabled, piece_limit)

# ===== 辅助 =====
# 从 RPC 发送方 peer_id 推断颜色（主机=1=黑，客户端=白）
func _sender_color() -> int:
	var sender: int = get_tree().get_multiplayer().get_remote_sender_id()
	return Const.BLACK if sender == 1 else Const.WHITE

# 同步失败信号（用于触发状态纠偏或断线提示）
signal sync_mismatch
# 主机发起的新对局请求（客户端接收）
signal new_game_requested(komi: float, special_enabled: bool, piece_limit: int)
# 开始游戏信号（客户端接收，由主机推送）
signal game_started(time_setting: Dictionary, piece_limit: int, komi: float, special_enabled: bool)
