# 联机对战菜单：主机/加入选择对话框
#
# 用法：
#   var menu = NetworkMenu.new()
#   add_child(menu)
#   menu.popup_centered()
#   menu.host_requested.connect(_on_host)
#   menu.join_requested.connect(_on_join)
extends AcceptDialog

signal host_requested(port: int)
signal join_requested(ip: String, port: int)

var _port_edit: LineEdit
var _ip_edit: LineEdit
var _host_btn: Button
var _join_btn: Button
var _hint_label: Label

func _ready() -> void:
	title = "联机对战"
	# 隐藏默认 OK 按钮，使用自定义按钮
	ok_button_text = "关闭"
	_build_ui()
	# 自定义按钮替代默认行为
	confirmed.connect(func(): hide())

func _build_ui() -> void:
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	add_child(vbox)
	# 说明
	_hint_label = Label.new()
	_hint_label.text = "主机=黑方先手，客户端=白方\n默认端口 5005"
	_hint_label.add_theme_font_size_override("font_size", 12)
	vbox.add_child(_hint_label)
	# 主机区
	var host_box := VBoxContainer.new()
	host_box.add_theme_constant_override("separation", 4)
	var host_label := Label.new()
	host_label.text = "—— 创建主机 ——"
	host_label.add_theme_font_size_override("font_size", 12)
	host_box.add_child(host_label)
	var port_row := HBoxContainer.new()
	port_row.add_child(_make_label("端口:"))
	_port_edit = LineEdit.new()
	_port_edit.text = "5005"
	_port_edit.custom_minimum_size = Vector2(120, 0)
	_port_edit.placeholder_text = "5005"
	port_row.add_child(_port_edit)
	host_box.add_child(port_row)
	_host_btn = Button.new()
	_host_btn.text = "创建主机"
	_host_btn.pressed.connect(_on_host_pressed)
	host_box.add_child(_host_btn)
	vbox.add_child(host_box)
	# 加入区
	var join_box := VBoxContainer.new()
	join_box.add_theme_constant_override("separation", 4)
	var join_label := Label.new()
	join_label.text = "—— 加入主机 ——"
	join_label.add_theme_font_size_override("font_size", 12)
	join_box.add_child(join_label)
	var ip_row := HBoxContainer.new()
	ip_row.add_child(_make_label("IP:"))
	_ip_edit = LineEdit.new()
	_ip_edit.text = "127.0.0.1"
	_ip_edit.custom_minimum_size = Vector2(160, 0)
	_ip_edit.placeholder_text = "如 192.168.1.100"
	ip_row.add_child(_ip_edit)
	join_box.add_child(ip_row)
	var join_port_row := HBoxContainer.new()
	join_port_row.add_child(_make_label("端口:"))
	var join_port_edit := LineEdit.new()
	join_port_edit.text = "5005"
	join_port_edit.custom_minimum_size = Vector2(120, 0)
	join_port_edit.placeholder_text = "5005"
	join_port_row.add_child(join_port_edit)
	# 复用：加入端口共用 _port_edit 引用不便，单独存
	join_port_edit.name = "JoinPortEdit"
	join_box.add_child(join_port_row)
	# 把 join_port_edit 绑定到 _port_edit 同值（简化：用元数据存储）
	_join_btn = Button.new()
	_join_btn.text = "加入主机"
	_join_btn.pressed.connect(func(): _on_join_pressed(join_port_edit.text))
	join_box.add_child(_join_btn)
	vbox.add_child(join_box)
	# 最小尺寸（AcceptDialog 继承 Window，使用 min_size）
	min_size = Vector2i(360, 280)

func _make_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.custom_minimum_size = Vector2(50, 0)
	return l

func _on_host_pressed() -> void:
	var port: int = _port_edit.text.to_int()
	if port <= 0 or port > 65535:
		_hint_label.text = "端口无效（1-65535）"
		return
	host_requested.emit(port)
	hide()

func _on_join_pressed(port_str: String) -> void:
	var ip: String = _ip_edit.text.strip_edges()
	if ip.is_empty():
		_hint_label.text = "请输入主机 IP"
		return
	var port: int = port_str.to_int()
	if port <= 0 or port > 65535:
		_hint_label.text = "端口无效（1-65535）"
		return
	join_requested.emit(ip, port)
	hide()
