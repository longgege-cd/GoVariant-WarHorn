# 联机入口菜单
#
# 玩家点击「联机对战」后弹出此菜单，提供两个选项：
#   - 建立房间（玩家A = 主机）：弹出 RoomHostDialog 设置房间参数
#   - 加入房间（玩家B = 客户端）：弹出 RoomListDialog 选择房间
extends AcceptDialog

signal host_requested  # 玩家选择建立房间
signal join_requested  # 玩家选择加入房间

const UITheme = preload("res://scripts/ui/UITheme.gd")

func _ready() -> void:
	title = LocaleManager.L("net.menu_title")
	ok_button_text = LocaleManager.L("net.menu_close")
	_build_ui()
	confirmed.connect(func(): hide())

func _build_ui() -> void:
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	add_child(vbox)
	# 说明
	var hint := Label.new()
	hint.text = LocaleManager.L("net.menu_role")
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", UITheme.C_TEXT_DIM)
	vbox.add_child(hint)
	# 建立房间按钮
	var host_btn := Button.new()
	host_btn.text = LocaleManager.L("net.menu_host")
	host_btn.custom_minimum_size = Vector2(280, 40)
	host_btn.add_theme_font_size_override("font_size", 14)
	host_btn.add_theme_color_override("font_color", UITheme.C_GOLD)
	host_btn.add_theme_color_override("font_hover_color", UITheme.C_GOLD_BRIGHT)
	host_btn.pressed.connect(func():
		host_requested.emit()
		queue_free()
	)
	vbox.add_child(host_btn)
	# 加入房间按钮
	var join_btn := Button.new()
	join_btn.text = LocaleManager.L("net.menu_join")
	join_btn.custom_minimum_size = Vector2(280, 40)
	join_btn.add_theme_font_size_override("font_size", 14)
	join_btn.add_theme_color_override("font_color", UITheme.C_GOLD)
	join_btn.add_theme_color_override("font_hover_color", UITheme.C_GOLD_BRIGHT)
	join_btn.pressed.connect(func():
		join_requested.emit()
		queue_free()
	)
	vbox.add_child(join_btn)
	min_size = Vector2i(340, 180)
