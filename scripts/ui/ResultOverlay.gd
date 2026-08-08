# 终局结果浮层 —— 棋盘中央半透明对话框
#
# 设计：
#   - 全屏半透明遮罩淡入
#   - 中央对话框缩放进场
#   - 显示胜方 + 原因 + 重新开始/返回主菜单按钮
#   - 主题感知配色
extends Control

signal new_game_requested
signal back_to_main_menu_requested
signal dismissed

var _overlay: ColorRect = null
var _dialog: Panel = null

func _ready() -> void:
	set_anchors_preset(PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP  # 拦截下层输入

static func create(result: Dictionary) -> Control:
	var inst := preload("res://scripts/ui/ResultOverlay.gd").new()
	inst._build(result)
	return inst

func _build(result: Dictionary) -> void:
	# 遮罩
	_overlay = ColorRect.new()
	_overlay.set_anchors_preset(PRESET_FULL_RECT)
	_overlay.color = Color(0, 0, 0, 0.0)
	add_child(_overlay)

	# 居中容器
	var center := CenterContainer.new()
	center.set_anchors_preset(PRESET_FULL_RECT)
	add_child(center)

	_dialog = Panel.new()
	_dialog.custom_minimum_size = Vector2(420, 240)
	var sb := StyleBoxFlat.new()
	sb.corner_detail = 1
	sb.bg_color = UITheme.C_PANEL_BG
	sb.border_width_left = 3
	sb.border_width_right = 3
	sb.border_width_top = 3
	sb.border_width_bottom = 3
	sb.border_color = UITheme.C_GOLD
	_dialog.add_theme_stylebox_override("panel", sb)
	center.add_child(_dialog)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(PRESET_FULL_RECT)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.offset_left = 24
	vbox.offset_right = -24
	vbox.add_theme_constant_override("separation", 14)
	_dialog.add_child(vbox)

	# 胜方
	var winner_str: String = result.get("winner", "和棋")
	var title := Label.new()
	title.text = winner_str
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 36)
	title.add_theme_color_override("font_color", UITheme.C_GOLD_BRIGHT)
	vbox.add_child(title)

	# 原因
	var reason_str: String = result.get("reason", "")
	if reason_str != "":
		var reason := Label.new()
		reason.text = reason_str
		reason.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		reason.add_theme_font_size_override("font_size", 16)
		reason.add_theme_color_override("font_color", UITheme.C_TEXT_DIM)
		vbox.add_child(reason)

	# 分隔
	var sep := HSeparator.new()
	sep.add_theme_constant_override("separation", 4)
	vbox.add_child(sep)

	# 按钮行
	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 16)
	vbox.add_child(btn_row)

	var again_btn := _make_button("再 来 一 局", false)
	again_btn.pressed.connect(func():
		new_game_requested.emit()
		queue_free()
	)
	btn_row.add_child(again_btn)

	var menu_btn := _make_button("返 回 主 菜 单", false)
	menu_btn.pressed.connect(func():
		back_to_main_menu_requested.emit()
		queue_free()
	)
	btn_row.add_child(menu_btn)

	# 入场动画
	_play_entrance()

func _make_button(label: String, _danger: bool) -> Button:
	var b := Button.new()
	b.text = label
	b.custom_minimum_size = Vector2(150, 38)
	b.add_theme_font_size_override("font_size", 15)
	b.add_theme_color_override("font_color", UITheme.C_GOLD)
	b.add_theme_color_override("font_hover_color", UITheme.C_GOLD_BRIGHT)
	var sb_n := StyleBoxFlat.new()
	sb_n.corner_detail = 1
	sb_n.border_width_left = 2
	sb_n.border_width_right = 2
	sb_n.border_width_top = 2
	sb_n.border_width_bottom = 2
	sb_n.bg_color = Color(0.04, 0.03, 0.02, 0.9)
	sb_n.border_color = UITheme.C_GOLD_DIM
	var sb_h := sb_n.duplicate()
	sb_h.border_color = UITheme.C_GOLD
	sb_h.bg_color = Color(0.10, 0.08, 0.05, 0.95)
	b.add_theme_stylebox_override("normal", sb_n)
	b.add_theme_stylebox_override("hover", sb_h)
	b.add_theme_stylebox_override("pressed", sb_h)
	b.mouse_entered.connect(func(): UITheme.animate_button_hover(b, true))
	b.mouse_exited.connect(func(): UITheme.animate_button_hover(b, false))
	return b

func _play_entrance() -> void:
	var t1 := _overlay.create_tween()
	t1.set_ease(Tween.EASE_OUT)
	t1.set_trans(Tween.TRANS_CUBIC)
	t1.tween_property(_overlay, "color:a", 0.65, 0.3)
	_dialog.modulate.a = 0.0
	_dialog.scale = Vector2(0.88, 0.88)
	var t2 := _dialog.create_tween()
	t2.set_ease(Tween.EASE_OUT)
	t2.set_trans(Tween.TRANS_BACK)
	t2.tween_interval(0.1)
	t2.tween_property(_dialog, "modulate:a", 1.0, 0.35)
	t2.parallel().tween_property(_dialog, "scale", Vector2(1.0, 1.0), 0.35)

# ESC 关闭（仅终局时 ESC 视为返回主菜单）
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			dismissed.emit()
			queue_free()
			get_viewport().set_input_as_handled()
