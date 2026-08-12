# 联机模块测试：验证 NetworkManager 状态机 + NetSync 操作同步逻辑 + 房间模式
# 用法: godot --headless res://tests/test_net.tscn
#
# 注意：必须用「场景方式」运行而非 --script，因为 --script 模式下
# autoload（NetworkManager/NetSync/Log/RoomDiscovery）在编译期未注册。
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
	t.expect(RoomDiscovery != null, "RoomDiscovery autoload 可用")
	if NetworkManager == null or NetSync == null:
		_finish()
		return

	_test_nm_initial_state()
	_test_nm_host_close()
	_test_netsync_active_gate()
	_test_netsync_local_ops()
	_test_remote_resign()
	_test_full_sync_simulation()
	await _test_real_connection()
	_test_room_start_game_signals()
	_test_room_discovery_basic()

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
	# active=false 时 confirm_* 不应执行（客户端收确认）
	NetSync.confirm_move(5, 5, Const.BLACK)
	t.expect_eq(session.ply, 0, "active=false 时 confirm_move 不生效")
	t.expect_eq(session.board.get_at(5, 5), Const.EMPTY, "active=false 时盘面不变")
	# active=true 且模拟客户端视角（local_color=WHITE，对端=BLACK）
	NetSync.active = true
	NetworkManager._state = NetworkManager.State.OFFLINE  # 离线
	NetworkManager._is_host = false
	NetworkManager.local_color = Const.WHITE
	NetSync.confirm_move(9, 9, Const.BLACK)  # 主机确认：黑落子
	t.expect_eq(session.ply, 1, "confirm_move 后 ply=1")
	t.expect_eq(session.to_move, Const.WHITE, "轮到本地(白)")
	t.expect_eq(session.board.get_at(9, 9), Const.BLACK, "黑子已落 (9,9)")
	# 非法确认不崩溃：to_move=WHITE，confirm_pass(BLACK) → 非法（非黑方回合）
	var ply_before: int = session.ply
	NetSync.confirm_pass(Const.BLACK)
	t.expect_eq(session.ply, ply_before, "非法确认不影响 ply")

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

# ===== 5. 认输终局链路 =====
func _test_remote_resign() -> void:
	# ---- 主机视角：客户端(白)认输 → _finish_by_resign(WHITE) ----
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
	NetSync._finish_by_resign(Const.WHITE)  # 客户端(白)认输
	t.expect(state.ended, "客户端认输触发 game_ended")
	t.expect(session.game_over, "session.game_over=true")
	# local_color=BLACK(主机)，对端=WHITE(客户端)认输 → 黑方胜
	if state.ended:
		t.expect(state.result.winner == "黑方胜", "对端(白)认输 → 黑方胜")
	else:
		t.expect(false, "终局结果缺失")
	# ---- 客户端视角：收到主机 confirm_game_over 广播 ----
	_reset_net_state()
	NetworkManager._is_host = false
	NetworkManager.local_color = Const.WHITE
	var session2 := GameSession.new(Const.KOMI_DEFAULT, true)
	session2.emit_signals = true
	NetSync.session = session2
	NetSync.active = true
	var state2: Dictionary = {"ended": false, "result": {}}
	session2.game_ended.connect(func(r): state2["ended"] = true; state2["result"] = r)
	NetSync.confirm_game_over({"winner": "黑方胜", "reason": "黑方认输"})
	t.expect(state2.ended, "confirm_game_over 触发 game_ended")
	t.expect(session2.game_over, "客户端 session.game_over=true")
	if state2.ended:
		t.expect(state2.result.winner == "黑方胜", "确认结果 winner=黑方胜")

# ===== 6. 完整对局同步模拟（主机视角：本地操作 + 模拟对端 request 请求交替） =====
func _test_full_sync_simulation() -> void:
	_reset_net_state()
	var session := GameSession.new(Const.KOMI_DEFAULT, true)
	session.emit_signals = false
	NetSync.session = session
	NetSync.active = true
	# 模拟联机状态（但 _state=OFFLINE 避免真实 RPC 发送，因无真实 peer）
	NetworkManager._state = NetworkManager.State.OFFLINE
	NetworkManager._is_host = true
	NetworkManager.local_color = Const.BLACK
	# 主机(黑)下第一手 - local_play_move 用 local_color=BLACK
	var out: Dictionary = NetSync.local_play_move(9, 9)
	t.expect(out.ok, "主机首手 local_play_move")
	t.expect_eq(session.to_move, Const.WHITE, "轮到客户端(白)")
	# 模拟客户端(白)的 request_move 到达主机（离线时 sender_id=0 → 推断为 WHITE）
	NetSync.request_move(10, 10)
	t.expect_eq(session.ply, 2, "对端应手后 ply=2")
	t.expect_eq(session.to_move, Const.BLACK, "轮到主机(黑)")
	# 主机再下一手
	out = NetSync.local_play_move(8, 8)
	t.expect(out.ok, "主机第二手 local_play_move")
	t.expect_eq(session.ply, 3, "ply=3")
	# 模拟客户端虚手请求
	NetSync.request_pass()
	t.expect_eq(session.ply, 4, "客户端虚手后 ply=4")
	t.expect_eq(session.consecutive_passes, 1, "连续虚手 1")
	# 客户端非法请求不崩溃：轮到主机(黑)时客户端(白)再落子 → 非法
	var ply_before: int = session.ply
	NetSync.request_move(6, 6)
	t.expect_eq(session.ply, ply_before, "非法请求不影响 ply")

# ===== 7. 真实 ENet 连接：主机检测到客户端加入 =====
# 主机用默认 multiplayer 建主，客户端用独立 SceneMultiplayer 连接，
# 验证主机 peer_connected 信号驱动 player_joined（权威主机模型核心）
func _test_real_connection() -> void:
	_reset_net_state()
	var port: int = 16099
	var host_ok: bool = NetworkManager.host_game(port)
	t.expect(host_ok, "真实连接：建主成功")
	if not host_ok:
		return
	var joined_state: Dictionary = {"joined": false, "pid": -1}
	var cb := func(pid: int):
		joined_state.joined = true
		joined_state.pid = pid
	NetworkManager.player_joined.connect(cb)
	# 客户端：独立 SceneMultiplayer + ENet 客户端连接主机
	var mp_client := SceneMultiplayer.new()
	var peer_c := ENetMultiplayerPeer.new()
	var err: int = peer_c.create_client("127.0.0.1", port)
	t.expect(err == OK, "真实连接：客户端创建成功")
	mp_client.multiplayer_peer = peer_c
	# 轮询等待连接完成（主机默认 multiplayer 由引擎自动 poll）
	var deadline: int = Time.get_ticks_msec() + 4000
	var client_connected: bool = false
	while Time.get_ticks_msec() < deadline:
		mp_client.poll()
		if peer_c.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			client_connected = true
		if joined_state.joined and client_connected:
			break
		await get_tree().process_frame
	t.expect(client_connected, "真实连接：客户端连接成功")
	t.expect(joined_state.joined, "真实连接：主机检测到客户端加入")
	t.expect(NetworkManager.is_online(), "真实连接：主机状态 ONLINE")
	t.expect(NetworkManager.remote_peer_id() > 0, "真实连接：remote_peer_id 已设置")
	# 清理
	if NetworkManager.player_joined.is_connected(cb):
		NetworkManager.player_joined.disconnect(cb)
	peer_c.close()
	mp_client.multiplayer_peer = null
	NetworkManager.close()

func _reset_net_state() -> void:
	NetSync.session = null
	NetSync.active = false
	NetworkManager._state = NetworkManager.State.OFFLINE
	NetworkManager._is_host = false
	NetworkManager.local_color = Const.BLACK

# ===== 7. 房间模式：开始游戏 RPC 信号 =====
# 验证 NetSync 的 remote_start_game 信号链路（不实际传输，仅验证信号 emit 路径）
func _test_room_start_game_signals() -> void:
	# 客户端模式：模拟主机点开始游戏 → emit game_started
	NetworkManager._state = NetworkManager.State.ONLINE
	NetworkManager._is_host = false
	NetworkManager.local_color = Const.WHITE
	var gs_state: Dictionary = {"received": false, "piece": 0, "komi": 0.0, "special": false}
	var gs_cb := func(ts: Dictionary, p: int, k: float, s: bool):
		gs_state.received = true
		gs_state.piece = p
		gs_state.komi = k
		gs_state.special = s
	NetSync.game_started.connect(gs_cb)
	# 直接调用 remote_start_game 模拟主机 RPC 到达客户端
	NetSync.remote_start_game({"main": 600.0, "byoyomi": 3, "byoyomi_duration": 30.0}, 134, 3.5, true)
	t.expect(gs_state.received, "客户端收到 game_started 信号")
	t.expect_eq(gs_state.piece, 134, "开始游戏兵力=134")
	t.expect_eq(gs_state.komi, 3.5, "开始游戏贴目=3.5")
	t.expect(gs_state.special, "开始游戏特种部队=true")
	NetSync.game_started.disconnect(gs_cb)

	# 主机模式：不应 emit game_started（仅客户端接收）
	NetworkManager._is_host = true
	NetworkManager.local_color = Const.BLACK
	var host_state: Dictionary = {"received": false}
	var host_cb := func(ts, p, k, s): host_state.received = true
	NetSync.game_started.connect(host_cb)
	NetSync.remote_start_game({"main": 600.0}, 112, 3.5, true)
	t.expect(not host_state.received, "主机不接收 game_started 信号")
	NetSync.game_started.disconnect(host_cb)

# ===== 8. RoomDiscovery 基本功能 =====
# 验证 RoomDiscovery 的广播/监听接口不崩溃，房间列表为空时返回空数组
func _test_room_discovery_basic() -> void:
	# 初始状态：未广播未监听，房间列表为空
	t.expect_eq(RoomDiscovery.get_rooms().size(), 0, "初始房间列表为空")
	# 启动广播（不实际验证 UDP 传输，仅验证接口可用）
	var room_info: Dictionary = {
		"ip": "127.0.0.1",
		"port": 5005,
		"time_setting": {"main": -1.0, "byoyomi": 0, "byoyomi_duration": 0.0},
		"piece_limit": 112,
		"komi": 3.5,
	}
	RoomDiscovery.start_broadcasting(room_info)
	t.expect(RoomDiscovery.get_rooms().size() == 0, "主机广播中房间列表为空（自身不监听）")
	RoomDiscovery.stop_broadcasting()
	# 启动监听（端口可能被占用，不强制要求成功）
	RoomDiscovery.start_listening()
	RoomDiscovery.stop_listening()
	t.expect(RoomDiscovery.get_rooms().size() == 0, "停止监听后房间列表为空")

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
