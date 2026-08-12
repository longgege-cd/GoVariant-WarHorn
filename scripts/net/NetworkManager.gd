# 联机管理器（autoload）— 权威主机模型
#
# 职责：
#   - 管理 ENetMultiplayerPeer 生命周期（建主/加入/关闭）
#   - 维护连接状态机（OFFLINE/HOSTING/CONNECTING/ONLINE）
#   - 分配玩家颜色（主机=黑，客户端=白）
#   - 检测对端加入/断开（基于 ENet 底层 peer_connected/peer_disconnected 信号）
#   - 通知外部连接事件（信号）
#
# 架构：权威主机（参考《联机对战.txt》）
#   - 主机（Host）负责所有游戏逻辑的权威计算
#   - 客户端（Client）只发送操作请求、接收主机广播的状态确认
#   - 主机通过 multiplayer.peer_connected 信号检测客户端加入（ENet 底层，最可靠）
#
# 用法：
#   NetworkManager.host_game(5005)
#   NetworkManager.join_game("127.0.0.1", 5005)
#   NetworkManager.player_joined.connect(_on_player_joined)
#   NetworkManager.local_color  # 本地玩家颜色
extends Node

# 连接状态
enum State { OFFLINE, HOSTING, CONNECTING, ONLINE }

signal hosted()                    # 主机已创建（等待客户端加入）
signal joined()                    # 客户端已连接到主机
signal player_joined(peer_id: int)  # 主机检测到对端加入（ENet 信号驱动）
signal player_disconnected(peer_id: int)  # 对端断开
signal connection_failed()         # 连接失败
signal closed()                    # 连接已关闭

var _state: int = State.OFFLINE
var _peer: ENetMultiplayerPeer = null
var _is_host: bool = false
var _remote_peer_id: int = 0       # 对端 peer id（联机对手）
# 本地玩家颜色：主机=黑，客户端=白
var local_color: int = Const.BLACK

func _ready() -> void:
	# 权威主机：用 MultiplayerAPI.peer_connected 信号检测客户端加入（ENet 底层，最可靠）
	var mp := get_tree().get_multiplayer()
	mp.peer_connected.connect(_on_peer_connected)
	mp.peer_disconnected.connect(_on_peer_disconnected)

func _process(_delta: float) -> void:
	# 客户端侧：CONNECTING 状态下检测连接结果
	if _state == State.CONNECTING and _peer != null:
		match _peer.get_connection_status():
			MultiplayerPeer.CONNECTION_CONNECTED:
				_state = State.ONLINE
				_is_host = false
				local_color = Const.WHITE
				# 主机 peer_id 始终为 1
				_remote_peer_id = 1
				Log.i("NetworkManager: 已连接主机 peer_id=1")
				joined.emit()
			MultiplayerPeer.CONNECTION_DISCONNECTED:
				_state = State.OFFLINE
				connection_failed.emit()
				_peer = null
			_:
				pass  # 仍在连接中

# 当前状态
func get_state() -> int:
	return _state

func is_online() -> bool:
	return _state == State.ONLINE

func is_host() -> bool:
	return _is_host

func is_offline() -> bool:
	return _state == State.OFFLINE

# 主机：创建服务器
func host_game(port: int, max_peers: int = 2) -> bool:
	if _state != State.OFFLINE:
		push_warning("NetworkManager: 非离线状态，无法建主")
		return false
	_peer = ENetMultiplayerPeer.new()
	var err: int = _peer.create_server(port, max_peers)
	if err != OK:
		Log.w("NetworkManager: 建主失败 port=%d err=%d" % [port, err])
		_peer = null
		return false
	get_tree().get_multiplayer().multiplayer_peer = _peer
	_state = State.HOSTING
	_is_host = true
	local_color = Const.BLACK
	Log.i("NetworkManager: 主机已创建 port=%d" % port)
	hosted.emit()
	return true

# 客户端：加入主机
func join_game(ip: String, port: int) -> bool:
	if _state != State.OFFLINE:
		push_warning("NetworkManager: 非离线状态，无法加入")
		return false
	_peer = ENetMultiplayerPeer.new()
	var err: int = _peer.create_client(ip, port)
	if err != OK:
		Log.w("NetworkManager: 加入失败 ip=%s port=%d err=%d" % [ip, port, err])
		_peer = null
		return false
	get_tree().get_multiplayer().multiplayer_peer = _peer
	_state = State.CONNECTING
	_is_host = false
	local_color = Const.WHITE
	Log.i("NetworkManager: 正在连接 %s:%d" % [ip, port])
	return true

# 关闭连接
func close() -> void:
	if _peer != null:
		_peer.close()
		_peer = null
	get_tree().get_multiplayer().multiplayer_peer = null
	var was_online: bool = _state != State.OFFLINE
	_state = State.OFFLINE
	_is_host = false
	_remote_peer_id = 0
	local_color = Const.BLACK
	if was_online:
		closed.emit()
		Log.i("NetworkManager: 连接已关闭")

# 对端 peer id
func remote_peer_id() -> int:
	return _remote_peer_id

# 设置对端 peer id（供测试或扩展用）
func set_remote_peer_id(pid: int) -> void:
	if pid > 0:
		_remote_peer_id = pid
		if _state == State.HOSTING:
			_state = State.ONLINE
		Log.i("NetworkManager: 对端已加入 peer_id=%d" % pid)
		player_joined.emit(pid)

# 主机：ENet 对端连接信号 → 检测客户端加入（权威主机模型的核心）
func _on_peer_connected(peer_id: int) -> void:
	if _is_host and (_state == State.HOSTING or _state == State.ONLINE):
		_remote_peer_id = peer_id
		if _state == State.HOSTING:
			_state = State.ONLINE
		Log.i("NetworkManager: [ENet] 对端已加入 peer_id=%d" % peer_id)
		player_joined.emit(peer_id)

func _on_peer_disconnected(peer_id: int) -> void:
	if _remote_peer_id == peer_id:
		Log.i("NetworkManager: [ENet] 对端断开 peer_id=%d" % peer_id)
		_remote_peer_id = 0
		if _state == State.ONLINE:
			_state = State.HOSTING if _is_host else State.OFFLINE
		player_disconnected.emit(peer_id)
