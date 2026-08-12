# 房间发现模块（autoload）
#
# 基于 UDP 查询-响应模式在局域网内发现房间：
#   - 主机：bind HOST_PORT，监听查询包，收到后单播回复房间信息
#   - 客户端：bind CLIENT_PORT，广播查询包到 255.255.255.255:HOST_PORT
#             （同时发送到 127.0.0.1 支持同机器测试），监听回复
#
# 房间信息字段：
#   { ip, port, time_setting, piece_limit, komi, ts }
#
# 用法：
#   RoomDiscovery.start_broadcasting(room_info)   # 主机
#   RoomDiscovery.start_listening()               # 客户端
#   RoomDiscovery.get_rooms()                     # 获取房间列表
extends Node

const HOST_PORT: int = 5006              # 主机监听查询端口
const CLIENT_PORT: int = 5007            # 客户端监听回复端口
const BROADCAST_ADDR: String = "255.255.255.255"
const QUERY_INTERVAL: float = 2.0        # 客户端每 2 秒发送一次查询
const ROOM_TIMEOUT: float = 5.0          # 5 秒未刷新视为房间失效

signal room_list_changed  # 房间列表变化（新增/移除/更新）

var _host_sock: PacketPeerUDP = null     # 主机监听套接字
var _client_sock: PacketPeerUDP = null   # 客户端监听+查询套接字
var _room_info: Dictionary = {}          # 主机当前房间信息
var _query_timer: float = 0.0            # 客户端查询计时器
var _rooms: Dictionary = {}              # 已发现的房间 {key -> room_info}
# key = ip + ":" + port（同一主机+端口视为同一房间）

# ===== 主机：监听查询并回复 =====
func start_broadcasting(room_info: Dictionary) -> void:
	stop_broadcasting()
	_room_info = room_info.duplicate(true)
	_host_sock = PacketPeerUDP.new()
	_host_sock.set_broadcast_enabled(true)
	var bind_err: int = _host_sock.bind(HOST_PORT, "0.0.0.0")
	if bind_err != OK:
		Log.w("RoomDiscovery: 主机端口 %d 绑定失败 err=%d（可能被占用）" % [HOST_PORT, bind_err])
		_host_sock = null
		return
	Log.i("RoomDiscovery: 主机监听查询 port=%d 房间=%s:%d" % [HOST_PORT, room_info.get("ip", "?"), room_info.get("port", 0)])

func stop_broadcasting() -> void:
	if _host_sock != null:
		_host_sock.close()
		_host_sock = null
	_room_info = {}

func _process_host() -> void:
	if _host_sock == null:
		return
	# 处理收到的查询包
	while _host_sock.get_available_packet_count() > 0:
		var packet: PackedByteArray = _host_sock.get_packet()
		var text: String = packet.get_string_from_utf8()
		if text == "QUERY":
			# 收到查询，向发送者单播回复房间信息
			var client_ip: String = _host_sock.get_packet_ip()
			var client_port: int = _host_sock.get_packet_port()
			_room_info["ts"] = Time.get_ticks_msec()
			var data: PackedByteArray = JSON.stringify(_room_info).to_utf8_buffer()
			_host_sock.set_dest_address(client_ip, CLIENT_PORT)
			var err: int = _host_sock.put_packet(data)
			if err != OK:
				Log.w("RoomDiscovery: 回复查询失败 err=%d ip=%s:%d" % [err, client_ip, client_port])

# ===== 客户端：发送查询并监听回复 =====
func start_listening() -> void:
	stop_listening()
	_client_sock = PacketPeerUDP.new()
	_client_sock.set_broadcast_enabled(true)
	var err: int = _client_sock.bind(CLIENT_PORT, "0.0.0.0")
	if err != OK:
		Log.w("RoomDiscovery: 客户端端口 %d 绑定失败 err=%d（可能被占用）" % [CLIENT_PORT, err])
		_client_sock = null
		return
	_rooms.clear()
	# 立即发送一次查询
	_send_query()
	Log.i("RoomDiscovery: 客户端开始查询房间 port=%d" % CLIENT_PORT)

func stop_listening() -> void:
	if _client_sock != null:
		_client_sock.close()
		_client_sock = null
	_rooms.clear()

func get_rooms() -> Array:
	return _rooms.values()

# 客户端是否在监听（start_listening 成功后为 true）
func is_listening() -> bool:
	return _client_sock != null

# 主机是否在广播（start_broadcasting 成功后为 true）
func is_broadcasting() -> bool:
	return _host_sock != null

# 清空房间列表（客户端主动刷新时调用）
func clear_rooms() -> void:
	if not _rooms.is_empty():
		_rooms.clear()
		room_list_changed.emit()

# 立即发送一次查询（客户端刷新列表时调用，不重绑端口避免 bind 失败）
func force_query() -> void:
	_send_query()

func _send_query() -> void:
	if _client_sock == null:
		return
	var query: PackedByteArray = "QUERY".to_utf8_buffer()
	# 发送到广播地址
	_client_sock.set_dest_address(BROADCAST_ADDR, HOST_PORT)
	var err1: int = _client_sock.put_packet(query)
	# 同时发送到回环地址（支持同机器测试）
	_client_sock.set_dest_address("127.0.0.1", HOST_PORT)
	var err2: int = _client_sock.put_packet(query)
	if err1 != OK and err2 != OK:
		Log.w("RoomDiscovery: 查询发送失败 err1=%d err2=%d" % [err1, err2])

func _process_client(delta: float) -> void:
	if _client_sock == null:
		return
	# 定期发送查询
	_query_timer += delta
	if _query_timer >= QUERY_INTERVAL:
		_query_timer = 0.0
		_send_query()
	# 处理收到的回复
	while _client_sock.get_available_packet_count() > 0:
		var packet: PackedByteArray = _client_sock.get_packet()
		var text: String = packet.get_string_from_utf8()
		if text.is_empty():
			continue
		var parsed: Variant = JSON.parse_string(text)
		if not parsed is Dictionary:
			continue
		var room: Dictionary = parsed
		var ip: String = str(room.get("ip", ""))
		var port: int = int(room.get("port", 0))
		if ip.is_empty() or port <= 0:
			continue
		var key: String = "%s:%d" % [ip, port]
		var is_new: bool = not _rooms.has(key)
		_rooms[key] = room
		if is_new:
			room_list_changed.emit()
	# 清理超时房间
	_cleanup_stale_rooms()

# ===== 主循环 =====
func _process(delta: float) -> void:
	_process_host()
	_process_client(delta)

func _cleanup_stale_rooms() -> void:
	var now: int = Time.get_ticks_msec()
	var stale_keys: Array = []
	for key in _rooms.keys():
		var room: Dictionary = _rooms[key]
		var ts: int = int(room.get("ts", 0))
		if now - ts > int(ROOM_TIMEOUT * 1000.0):
			stale_keys.append(key)
	if not stale_keys.is_empty():
		for key in stale_keys:
			_rooms.erase(key)
		room_list_changed.emit()

func _exit_tree() -> void:
	stop_broadcasting()
	stop_listening()
