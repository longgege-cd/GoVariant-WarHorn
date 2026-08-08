# 联机模块测试：验证 NetworkManager 状态机 + NetSync 操作同步逻辑
# 用法: godot --headless res://tests/test_net.tscn
#
# 注意：必须用「场景方式」运行而非 --script，因为 --script 模式下
# autoload（NetworkManager/NetSync/Log）在编译期未注册。
extends Node

const TestFramework = preload("res://tests/test_framework.gd")

var t: TestFramework

func _ready() -> void:
	t = TestFramework.new()
	t.suite("联机模块")
	await _run_tests()

func _run_tests() -> void:
	print("########## 联机模块测试 ##########")
	t.expect(NetworkManager != null, "NetworkManager autoload 可用")
	t.expect(NetSync != null, "NetSync autoload 可用")
	t.expect(Log != null, "Log autoload 可用")
	if NetworkManager == null or NetSync == null:
		_finish()
		return

	_test_nm_initial_state()
	_test_nm_host_close()
	_test_netsync_active_gate()
	_test_netsync_local_ops()
	_test_remote_resign()
	_test_full_sync_simulation()

	_reset_net_state()
	_finish()

# ===== 1. NetworkManager 初始状态 =====
func _test_nm_initial_state() -> void:
	t.expect_eq(NetworkManager.get_state(), NetworkManager.State.OFFLINE, "初始 OFFLINE")
	t.expect(NetworkManager.is_offline(), "is_offline 初始 true")
	t.expect(not NetworkManager.is_online(), "is_online 初始 false")
	t.expect_eq(NetworkManager.local_color, Const.BLACK, "初始 local_color=BLACK")

# ===== 2. NetworkManager 建主/关闭 =====
func _test_nm_host_close() -> void:
	var port: int = 15055
	var host_ok: bool = NetworkManager.host_game(port)
	t.expect(host_ok, "建主成功")
	t.expect_eq(NetworkManager.get_state(), NetworkManager.State.HOSTING, "状态 HOSTING")
	t.expect(NetworkManager.is_host(), "is_host true")
	t.expect_eq(NetworkManager.local_color, Const.BLACK, "主机 local_color=BLACK")
	# 重复建主应失败
	t.expect(not NetworkManager.host_game(port + 1), "重复建主失败")
	NetworkManager.close()
	t.expect_eq(NetworkManager.get_state(), NetworkManager.State.OFFLINE, "关闭后 OFFLINE")

# ===== 3. NetSync active 门控 =====
func _test_netsync_active_gate() -> void:
	_reset_net_state()
	var session := GameSession.new(Const.KOMI_DEFAULT, true)
	session.emit_signals = false
	NetSync.session = session
	NetSync.active = false
	# active=false 时 remote_* 不应执行
	NetSync.remote_play_move(5, 5)
	t.expect_eq(session.ply, 0, "active=false 时 remote_play_move 不生效")
	t.expect_eq(session.board.get_at(5, 5), Const.EMPTY, "active=false 时盘面不变")
	# active=true 且模拟客户端视角（local_color=WHITE，对端=BLACK）
	NetSync.active = true
	NetworkManager._state = NetworkManager.State.OFFLINE  # 离线，避免 RPC
	NetworkManager._is_host = false
	NetworkManager.local_color = Const.WHITE
	NetSync.remote_play_move(9, 9)  # 对端(黑)落子
	t.expect_eq(session.ply, 1, "remote_play_move 后 ply=1")
	t.expect_eq(session.to_move, Const.WHITE, "轮到本地(白)")
	t.expect_eq(session.board.get_at(9, 9), Const.BLACK, "黑子已落 (9,9)")
	# 非法虚手不崩溃：to_move=WHITE=local，remote_do_pass 用 BLACK → 非法
	var ply_before: int = session.ply
	NetSync.remote_do_pass()
	t.expect_eq(session.ply, ply_before, "非法虚手不影响 ply")

# ===== 4. NetSync 本地操作执行（主机视角，离线避免 RPC） =====
func _test_netsync_local_ops() -> void:
	_reset_net_state()
	NetworkManager.local_color = Const.BLACK
	NetworkManager._is_host = true
	NetworkManager._state = NetworkManager.State.OFFLINE  # 离线，避免 RPC
	var session := GameSession.new(Const.KOMI_DEFAULT, true)
	session.emit_signals = false
	NetSync.session = session
	NetSync.active = true
	# 主机(黑)落子
	var out: Dictionary = NetSync.local_play_move(10, 10)
	t.expect(out.ok, "local_play_move 本地执行成功")
	t.expect_eq(session.ply, 1, "local_play_move 后 ply=1")
	t.expect_eq(session.board.get_at(10, 10), Const.BLACK, "黑子已落 (10,10)")
	# 主机(黑)虚手 - to_move=WHITE，需要先模拟对手走，或用新session测虚手
	# 改用新 session 测虚手（黑先手虚手）
	var session2 := GameSession.new(Const.KOMI_DEFAULT, true)
	session2.emit_signals = false
	NetSync.session = session2
	out = NetSync.local_do_pass()
	t.expect(out.ok, "local_do_pass 执行成功")
	t.expect_eq(session2.consecutive_passes, 1, "连续虚手 1")
	# 部署特种
	var session3 := GameSession.new(Const.KOMI_DEFAULT, true)
	session3.emit_signals = false
	NetSync.session = session3
	out = NetSync.local_deploy_special(5, 5)
	t.expect(out.ok, "local_deploy_special 执行成功")
	t.expect(session3.special.has_hidden_at(Vector2i(5, 5)), "隐子已部署 (5,5)")

# ===== 5. remote_resign 触发终局 =====
func _test_remote_resign() -> void:
	_reset_net_state()
	NetworkManager.local_color = Const.BLACK
	NetworkManager._is_host = true
	NetworkManager._state = NetworkManager.State.OFFLINE
	var session := GameSession.new(Const.KOMI_DEFAULT, true)
	session.emit_signals = true
	NetSync.session = session
	NetSync.active = true
	# 用 Dictionary（引用类型）避免 lambda 捕获 bool 不回传的问题
	var state: Dictionary = {"ended": false, "result": {}}
	session.game_ended.connect(func(r): state["ended"] = true; state["result"] = r)
	NetSync.remote_resign()
	t.expect(state.ended, "remote_resign 触发 game_ended")
	t.expect(session.game_over, "session.game_over=true")
	# local_color=BLACK(主机)，对端=WHITE(客户端)认输 → 黑方胜
	if state.ended:
		t.expect(state.result.winner == "黑方胜", "对端(白)认输 → 黑方胜")
	else:
		t.expect(false, "终局结果缺失")

# ===== 6. 完整对局同步模拟（主机视角：本地操作 + 模拟对端 remote 操作交替） =====
func _test_full_sync_simulation() -> void:
	_reset_net_state()
	var session := GameSession.new(Const.KOMI_DEFAULT, true)
	session.emit_signals = false
	NetSync.session = session
	NetSync.active = true
	# 模拟联机状态（但 _state=OFFLINE 避免 rpc_id 报错，因无真实 peer）
	NetworkManager._state = NetworkManager.State.OFFLINE
	NetworkManager._is_host = true
	NetworkManager.local_color = Const.BLACK
	# 主机(黑)下第一手 - local_play_move 用 local_color=BLACK
	var out: Dictionary = NetSync.local_play_move(9, 9)
	t.expect(out.ok, "主机首手 local_play_move")
	t.expect_eq(session.to_move, Const.WHITE, "轮到客户端(白)")
	# 模拟客户端(白)的 remote_play_move 到达主机
	# 主机视角：local_color=BLACK，remote_color=opponent(BLACK)=WHITE
	NetSync.remote_play_move(10, 10)
	t.expect_eq(session.ply, 2, "对端应手后 ply=2")
	t.expect_eq(session.to_move, Const.BLACK, "轮到主机(黑)")
	# 主机再下一手
	out = NetSync.local_play_move(8, 8)
	t.expect(out.ok, "主机第二手 local_play_move")
	t.expect_eq(session.ply, 3, "ply=3")
	# 模拟客户端虚手
	NetSync.remote_do_pass()
	t.expect_eq(session.ply, 4, "客户端虚手后 ply=4")
	t.expect_eq(session.consecutive_passes, 1, "连续虚手 1")

func _reset_net_state() -> void:
	NetSync.session = null
	NetSync.active = false
	NetworkManager._state = NetworkManager.State.OFFLINE
	NetworkManager._is_host = false
	NetworkManager.local_color = Const.BLACK

func _finish() -> void:
	print("\n========== 联机模块测试结果 ==========")
	print("通过: %d   失败: %d" % [t.passed, t.failed])
	if t.failures.size() > 0:
		print("--- 失败明细 ---")
		for f in t.failures:
			print(f)
	print("==============================")
	var code: int = 0 if t.failed == 0 else 1
	get_tree().quit(code)
