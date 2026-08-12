# 双进程完整联机流程诊断：A建主 → B发现房间 → B加入 → 连接成功
# 用法（两个 Godot 进程并行，启动顺序任意）：
#   godot --headless res://tests/e2e_roomlist.tscn -- host
#   godot --headless res://tests/e2e_roomlist.tscn -- client
extends Node

const ROLE_HOST: String = "host"
const ROLE_CLIENT: String = "client"
const TIMEOUT: float = 12.0

var _role: String = ""
var _t: float = 0.0
var _done: bool = false
var _screen: Control = null
var _dlg: AcceptDialog = null

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() >= 1:
		_role = args[0]
	if _role == ROLE_HOST:
		_start_host()
	elif _role == ROLE_CLIENT:
		_start_client()
	else:
		print("E2E: 用法 e2e_roomlist.tscn -- host|client")
		get_tree().quit(2)

# ===== 主机流程 =====
func _start_host() -> void:
	_screen = preload("res://scripts/ui/GameScreen.gd").new()
	add_child(_screen)
	await get_tree().process_frame
	var ok: bool = _screen.start_online_host(5005)
	print("E2E_HOST: start_online_host=", ok)
	if not ok:
		get_tree().quit(1)
		return
	var room_info: Dictionary = {
		"ip": _screen._get_local_ip(),
		"port": 5005,
		"time_setting": {"main": -1.0, "byoyomi": 0, "byoyomi_duration": 0.0},
		"piece_limit": 112,
		"komi": 3.5,
	}
	RoomDiscovery.start_broadcasting(room_info)
	print("E2E_HOST: 广播 ip=", room_info.ip, " 广播成功=", RoomDiscovery.is_broadcasting())
	NetworkManager.player_joined.connect(func(pid: int):
		print("E2E_HOST: 检测到客户端加入 pid=", pid, " remote=", NetworkManager.remote_peer_id(), " online=", NetworkManager.is_online())
		_done = true
		print("E2E_HOST: RESULT=OK 客户端已加入")
		await get_tree().create_timer(0.5).timeout
		get_tree().quit(0)
	)

# ===== 客户端流程 =====
func _start_client() -> void:
	_screen = preload("res://scripts/ui/GameScreen.gd").new()
	add_child(_screen)
	await get_tree().process_frame
	# 模拟用户点击"加入房间"：弹出 RoomListDialog
	_screen._on_online_join_entry()
	await get_tree().create_timer(0.5).timeout
	_dlg = _screen._room_list_dlg
	if _dlg == null:
		print("E2E_CLIENT: RoomListDialog 未创建")
		get_tree().quit(1)
		return
	print("E2E_CLIENT: RoomListDialog 已弹出，监听状态=", RoomDiscovery.is_listening())

func _process(delta: float) -> void:
	_t += delta
	if _role == ROLE_CLIENT and _done:
		return
	if _role == ROLE_CLIENT and _dlg != null and not _done:
		var cnt: int = _dlg._room_list.item_count if _dlg._room_list != null else -1
		if cnt > 0 and NetworkManager.is_offline():
			print("E2E_CLIENT: 发现房间 数=", cnt, " → 模拟点击加入")
			# 模拟用户选中房间并点击"加入房间"
			_dlg._on_join_pressed()
			await get_tree().create_timer(0.2).timeout
		if NetworkManager.is_online() and NetworkManager.remote_peer_id() > 0:
			_done = true
			print("E2E_CLIENT: RESULT=OK 已连接主机 local_color=", NetworkManager.local_color)
			await get_tree().create_timer(0.5).timeout
			get_tree().quit(0)
		if _t > TIMEOUT:
			print("E2E_CLIENT: RESULT=FAIL 列表项=", cnt, " 房间数=", RoomDiscovery.get_rooms().size(), " 连接状态=", NetworkManager.get_state())
			get_tree().quit(1)
	elif _role == ROLE_HOST and _t > TIMEOUT and not _done:
		print("E2E_HOST: RESULT=TIMEOUT 未等到客户端加入")
		get_tree().quit(1)
