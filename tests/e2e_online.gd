# 双进程端到端联机测试：验证权威主机模型完整对局同步 + 性能测量
# 流程：主机(黑)与客户端(白)交替落子至 MAX_MOVES 手，测量每手同步耗时
# 注意：落子由 _process 异步驱动（每手间隔一帧），避免在信号回调中同步递归
#   落子导致 confirm RPC 发送顺序错乱（ply+1 先于 ply 到达客户端被拒）
# 用法（两个 Godot 进程并行）：
#   godot --headless res://tests/e2e_online.tscn -- host 16097
#   godot --headless res://tests/e2e_online.tscn -- client 16097
extends Node

const ROLE_HOST: String = "host"
const ROLE_CLIENT: String = "client"
const TIMEOUT: float = 30.0
const MAX_MOVES: int = 40        # 总手数（每方 20 手）
const MAX_PER_MOVE_MS: float = 100.0  # 性能阈值：平均每手同步耗时（宽松，防 flaky）

var _role: String = ""
var _port: int = 0
var _t: float = 0.0
var _done: bool = false
var _last_ts: int = 0
var _durations: Array = []       # 每手耗时 us
var _my_turn: bool = false       # 该角色待落子（异步驱动）

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() >= 1:
		_role = args[0]
	if args.size() >= 2:
		_port = args[1].to_int()
	if _role == ROLE_HOST:
		_start_host()
	elif _role == ROLE_CLIENT:
		_start_client()
	else:
		print("E2E: 用法 e2e_online.tscn -- host|client port")
		get_tree().quit(2)

func _record_move_time() -> void:
	var now: int = Time.get_ticks_usec()
	if _last_ts > 0:
		_durations.append(now - _last_ts)
	_last_ts = now

func _print_stats() -> void:
	var total_us: int = 0
	var max_us: int = 0
	for d in _durations:
		total_us += int(d)
		if int(d) > max_us:
			max_us = int(d)
	var n: int = _durations.size()
	var avg_ms: float = total_us / 1000.0 / max(n, 1)
	print("E2E[%s]: 每手同步耗时 avg=%.2f ms max=%.2f ms (统计%d手)" % [_role, avg_ms, max_us / 1000.0, n])

# 顺序扫描找第一个合法落子点
func _find_legal_move() -> Array:
	var b = NetSync.session.board
	for row in range(b.size):
		for col in range(b.size):
			if b.get_at(row, col) != Const.EMPTY:
				continue
			if GoRules.is_legal(b, row, col, NetSync.session.to_move, NetSync.session.ko_point):
				return [row, col]
	return []

# 轮到本角色时落一手（_process 驱动）
func _try_play() -> void:
	if _done or not _my_turn or NetSync.session == null:
		return
	_my_turn = false
	var mv := _find_legal_move()
	if mv.is_empty():
		NetSync.local_do_pass()
	else:
		NetSync.local_play_move(mv[0], mv[1])

# ===== 主机流程 =====
func _start_host() -> void:
	var ok: bool = NetworkManager.host_game(_port)
	print("E2E_HOST: host_game=", ok)
	if not ok:
		get_tree().quit(1)
		return
	NetworkManager.player_joined.connect(_on_host_player_joined)

func _on_host_player_joined(pid: int) -> void:
	print("E2E_HOST: player_joined pid=", pid, " remote_peer_id=", NetworkManager.remote_peer_id(), " online=", NetworkManager.is_online())
	NetSync.session = GameSession.new(Const.KOMI_DEFAULT, true)
	NetSync.active = true
	NetSync.session.move_committed.connect(_on_move_committed)
	_my_turn = true  # 黑先手

# ===== 客户端流程 =====
func _start_client() -> void:
	var ok: bool = NetworkManager.join_game("127.0.0.1", _port)
	print("E2E_CLIENT: join_game=", ok)
	if not ok:
		get_tree().quit(1)
		return
	NetworkManager.joined.connect(_on_client_joined)

func _on_client_joined() -> void:
	print("E2E_CLIENT: joined local_color=", NetworkManager.local_color)
	NetSync.session = GameSession.new(Const.KOMI_DEFAULT, true)
	NetSync.active = true
	NetSync.session.move_committed.connect(_on_move_committed)

func _on_move_committed(_outcome: Dictionary) -> void:
	_record_move_time()
	var ply: int = NetSync.session.ply
	print("E2E[%s]: move_committed ply=%d to_move=%d" % [_role, ply, NetSync.session.to_move])
	if ply >= MAX_MOVES and not _done:
		_done = true
		_finish(true)
		return
	_my_turn = (NetSync.session.to_move == NetworkManager.local_color)

func _process(delta: float) -> void:
	_t += delta
	if _done:
		return
	if _t > TIMEOUT:
		print("E2E: TIMEOUT role=", _role, " ply=", NetSync.session.ply if NetSync.session != null else -1)
		await get_tree().create_timer(0.5).timeout
		get_tree().quit(1)
		return
	_try_play()

func _finish(ok: bool) -> void:
	_print_stats()
	var avg_ms: float = 0.0
	if _durations.size() > 0:
		var total_us: int = 0
		for d in _durations:
			total_us += int(d)
		avg_ms = total_us / 1000.0 / _durations.size()
	if ok and avg_ms <= MAX_PER_MOVE_MS:
		print("E2E[%s]: RESULT=OK ply=%d avg=%.2f ms (阈值%.0f ms)" % [_role, NetSync.session.ply, avg_ms, MAX_PER_MOVE_MS])
	else:
		print("E2E[%s]: RESULT=FAIL ply=%d avg=%.2f ms" % [_role, NetSync.session.ply, avg_ms])
	await get_tree().create_timer(1.0).timeout
	get_tree().quit(0 if (ok and avg_ms <= MAX_PER_MOVE_MS) else 1)
