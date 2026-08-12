# 双进程房间发现诊断：验证查询-响应模式
# 用法（两个 Godot 进程并行）：
#   godot --headless res://tests/e2e_discover.tscn -- host
#   godot --headless res://tests/e2e_discover.tscn -- client
extends Node

const ROLE_HOST: String = "host"
const ROLE_CLIENT: String = "client"
const TIMEOUT: float = 8.0

var _role: String = ""
var _t: float = 0.0
var _done: bool = false

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() >= 1:
		_role = args[0]
	if _role == ROLE_HOST:
		_start_host()
	elif _role == ROLE_CLIENT:
		_start_client()
	else:
		print("E2E: 用法 e2e_discover.tscn -- host|client")
		get_tree().quit(2)

func _start_host() -> void:
	# 延迟 3 秒广播：模拟"客户端先打开列表，主机后建主"的反时序场景
	await get_tree().create_timer(3.0).timeout
	var ip: String = "127.0.0.1"
	for addr in IP.get_local_addresses():
		var s: String = str(addr)
		if not s.begins_with("127.") and not s.begins_with(":") and s.find(":") < 0:
			ip = s
			break
	var room_info: Dictionary = {
		"ip": ip,
		"port": 5005,
		"time_setting": {"main": -1.0, "byoyomi": 0, "byoyomi_duration": 0.0},
		"piece_limit": 112,
		"komi": 3.5,
	}
	RoomDiscovery.start_broadcasting(room_info)
	print("E2E_DISCOVER_HOST: 延迟3秒后开始广播 ip=", ip)

func _start_client() -> void:
	RoomDiscovery.room_list_changed.connect(_on_list_changed)
	RoomDiscovery.start_listening()
	print("E2E_DISCOVER_CLIENT: 开始监听")

func _on_list_changed() -> void:
	print("E2E_DISCOVER_CLIENT: room_list_changed rooms=", RoomDiscovery.get_rooms().size())
	for r in RoomDiscovery.get_rooms():
		print("E2E_DISCOVER_CLIENT: 发现房间 ", r.get("ip"), ":", r.get("port"))

func _process(delta: float) -> void:
	_t += delta
	if _role == ROLE_CLIENT:
		var rooms: Array = RoomDiscovery.get_rooms()
		if rooms.size() > 0 and not _done:
			_done = true
			print("E2E_DISCOVER_CLIENT: RESULT=OK rooms=", rooms.size())
			get_tree().quit(0)
		if _t > TIMEOUT and not _done:
			print("E2E_DISCOVER_CLIENT: RESULT=FAIL rooms=", rooms.size())
			get_tree().quit(1)
	elif _t > TIMEOUT and not _done:
		_done = true
		print("E2E_DISCOVER_HOST: RESULT=OK 运行结束")
		get_tree().quit(0)
