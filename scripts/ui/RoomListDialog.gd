# 房间列表对话框（玩家B = 客户端用）
#
# 玩家B点击"加入房间"后弹出此对话框：
#   - 自动开始监听局域网内主机的 UDP 广播
#   - 显示发现的房间列表（IP、端口、思考时间、兵力、贴目）
#   - 选中房间后点击「加入房间」→ emit join_confirmed(ip, port)
#   - 点击「取消」→ emit canceled
#
# 房间数据来源：RoomDiscovery autoload
extends AcceptDialog

signal join_confirmed(ip: String, port: int)
# 注：canceled 信号继承自 AcceptDialog，无需在此重新声明

const UITheme = preload("res://scripts/ui/UITheme.gd")
const StartMenu = preload("res://scripts/ui/StartMenu.gd")

var _room_list: ItemList
var _refresh_btn: Button
var _status_label: Label
var _rooms: Array = []  # 当前显示的房间列表

func _ready() -> void:
	title = LocaleManager.L("net.list_title")
	ok_button_text = LocaleManager.L("net.list_join")
	add_cancel_button(LocaleManager.L("net.list_cancel"))
	_build_ui()
	confirmed.connect(_on_join_pressed)
	# 启动监听
	RoomDiscovery.room_list_changed.connect(_on_room_list_changed)
	RoomDiscovery.start_listening()
	_refresh_rooms()
	# 监听状态提示：绑定失败时告知用户（否则列表空白但无提示，难以排查）
	if not RoomDiscovery.is_listening():
		_status_label.text = LocaleManager.L("net.list_port_failed")
		_status_label.add_theme_color_override("font_color", Color(0.95, 0.4, 0.35))
	else:
		_status_label.text = LocaleManager.L("net.list_searching")

func _build_ui() -> void:
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	add_child(vbox)
	# 说明
	var hint := Label.new()
	hint.text = LocaleManager.L("net.list_hint")
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", UITheme.C_TEXT_DIM)
	vbox.add_child(hint)
	# 监听状态提示
	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", 12)
	_status_label.add_theme_color_override("font_color", UITheme.C_GOLD_DIM)
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_status_label)
	# 房间列表
	_room_list = ItemList.new()
	_room_list.custom_minimum_size = Vector2(520, 180)
	_room_list.add_theme_font_size_override("font_size", 12)
	_room_list.item_activated.connect(_on_item_activated)
	vbox.add_child(_room_list)
	# 刷新按钮
	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 8)
	vbox.add_child(btn_row)
	_refresh_btn = Button.new()
	_refresh_btn.text = LocaleManager.L("net.list_refresh")
	_refresh_btn.custom_minimum_size = Vector2(120, 28)
	_refresh_btn.pressed.connect(_on_refresh_pressed)
	btn_row.add_child(_refresh_btn)
	min_size = Vector2i(560, 320)

func _on_room_list_changed() -> void:
	_refresh_rooms()

func _on_refresh_pressed() -> void:
	RoomDiscovery.clear_rooms()
	# 立即重新查询（不重绑端口，避免 bind 失败导致监听中断）
	RoomDiscovery.force_query()

func _refresh_rooms() -> void:
	_rooms = RoomDiscovery.get_rooms()
	_room_list.clear()
	for room in _rooms:
		var ip: String = str(room.get("ip", ""))
		var port: int = int(room.get("port", 0))
		var time_setting: Dictionary = room.get("time_setting", {})
		var piece_limit: int = int(room.get("piece_limit", 0))
		var komi: float = float(room.get("komi", 0.0))
		var text: String = "%s:%d  |  %s  |  %s" % [
			ip, port, _format_time(time_setting),
			LocaleManager.L("net.list_forces_komi", {"forces": piece_limit, "komi": "%.1f" % komi}),
		]
		_room_list.add_item(text)
	# 默认选中第一项
	if _room_list.item_count > 0:
		_room_list.select(0)
	# 更新状态提示
	if RoomDiscovery.is_listening():
		if _room_list.item_count > 0:
			_status_label.text = LocaleManager.L("net.list_found", {"n": _room_list.item_count})
			_status_label.add_theme_color_override("font_color", UITheme.C_GOLD)
		else:
			_status_label.text = LocaleManager.L("net.list_searching")
			_status_label.add_theme_color_override("font_color", UITheme.C_GOLD_DIM)

func _format_time(ts: Dictionary) -> String:
	var main: float = float(ts.get("main", -1.0))
	var byo: int = int(ts.get("byoyomi", 0))
	var byo_dur: float = float(ts.get("byoyomi_duration", 0.0))
	if main < 0:
		return LocaleManager.L("net.list_unlimited")
	var txt := LocaleManager.L("net.list_time_format", {"n": int(main / 60.0), "m": int(main) % 60})
	if byo > 0:
		txt += " + %s" % LocaleManager.L("net.list_time_format", {"n": byo, "m": int(byo_dur)})
	return txt

func _on_join_pressed() -> void:
	var idx: int = _room_list.get_selected_items()[0] if _room_list.get_selected_items().size() > 0 else -1
	if idx < 0 or idx >= _rooms.size():
		return
	var room: Dictionary = _rooms[idx]
	join_confirmed.emit(str(room.get("ip", "")), int(room.get("port", 0)))

func _on_item_activated(_idx: int) -> void:
	_on_join_pressed()
	hide()

func _exit_tree() -> void:
	# 关闭对话框时停止监听（避免后台占用端口）
	if RoomDiscovery.room_list_changed.is_connected(_on_room_list_changed):
		RoomDiscovery.room_list_changed.disconnect(_on_room_list_changed)
	RoomDiscovery.stop_listening()
