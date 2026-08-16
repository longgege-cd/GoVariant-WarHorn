# 主机等待对手对话框
#
# 主机建立房间后弹出此对话框：
#   - 显示「等待对手加入…」状态
#   - 客户端连接后切换为「对手已加入，点击开始游戏」
#   - 主机点击「开始游戏」→ emit start_requested
#   - 主机点击「取消」→ emit canceled（关闭房间）
extends AcceptDialog

signal start_requested
# 注：canceled 信号继承自 AcceptDialog，无需在此重新声明

const UITheme = preload("res://scripts/ui/UITheme.gd")

var _status_label: Label
var _peer_joined: bool = false

func _ready() -> void:
	title = LocaleManager.L("net.wait_title")
	ok_button_text = LocaleManager.L("net.wait_start")
	add_cancel_button(LocaleManager.L("net.wait_cancel"))
	_build_ui()
	_update_state(false)
	confirmed.connect(func():
		if _peer_joined:
			start_requested.emit()
	)

func _build_ui() -> void:
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	add_child(vbox)
	_status_label = Label.new()
	_status_label.text = LocaleManager.L("net.wait_waiting")
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 14)
	_status_label.add_theme_color_override("font_color", UITheme.C_GOLD)
	_status_label.custom_minimum_size = Vector2(320, 40)
	vbox.add_child(_status_label)
	min_size = Vector2i(400, 120)

# 客户端加入后调用
func set_peer_joined(joined: bool) -> void:
	_peer_joined = joined
	_update_state(joined)

func _update_state(joined: bool) -> void:
	if joined:
		_status_label.text = LocaleManager.L("net.wait_joined")
		_status_label.add_theme_color_override("font_color", UITheme.C_GOLD_BRIGHT)
		get_ok_button().disabled = false
	else:
		_status_label.text = LocaleManager.L("net.wait_waiting")
		_status_label.add_theme_color_override("font_color", UITheme.C_GOLD_DIM)
		get_ok_button().disabled = true  # 未加入时禁用开始按钮
