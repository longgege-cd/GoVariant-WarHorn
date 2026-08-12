# 暂停菜单（ESC 弹出）—— 完整设置菜单 + 动画
#
# 设计（基于 UITheme 战火夜幕色系）：
#   - 半透明遮罩淡入 + 居中对话框缩放进场
#   - 选项：继续 / 新对局 / 认输 / 部署特种 / 模式选择 / 联机 / 主题 / 返回主菜单 / 退出
#   - 按钮悬停动画（字色变亮金 + 轻微缩放）
#   - ESC 再次按下 = 继续游戏
extends Control

signal resume_requested
signal new_game_requested
signal resign_requested
signal deploy_special_requested
signal mode_selected(mode: String, difficulty: int)
signal online_pressed
signal online_quit_pressed
signal theme_cycle_requested
signal back_to_main_menu_requested
signal quit_requested

const AIManager = preload("res://scripts/ai/AIManager.gd")

var _mode_buttons: Array = []
var _online_active: bool = false  # 联机状态（外部设置）
var _dialog: Panel = null
var _overlay: ColorRect = null
var _online_btn: Button = null

func _ready() -> void:
	set_anchors_preset(PRESET_FULL_RECT)
	_build_ui()
	_play_entrance_animation()

func set_online_active(active: bool) -> void:
	_online_active = active
	if _online_btn != null:
		_online_btn.text = "退出联机" if active else "联机对战 …"

func _build_ui() -> void:
	# 1. 半透明遮罩层（淡入）
	_overlay = ColorRect.new()
	_overlay.set_anchors_preset(PRESET_FULL_RECT)
	_overlay.color = Color(0, 0, 0, 0.0)  # 初始透明，动画淡入
	add_child(_overlay)

	# 2. 居中对话框（用 CenterContainer 精确居中，缩放进场）
	var center := CenterContainer.new()
	center.set_anchors_preset(PRESET_FULL_RECT)
	add_child(center)

	_dialog = Panel.new()
	_dialog.custom_minimum_size = Vector2(380, 580)
	# 像素风外框样式
	var dialog_style := StyleBoxFlat.new()
	dialog_style.corner_detail = 1
	dialog_style.bg_color = UITheme.C_PANEL_BG
	dialog_style.border_width_left = 4
	dialog_style.border_width_right = 4
	dialog_style.border_width_top = 4
	dialog_style.border_width_bottom = 4
	dialog_style.border_color = UITheme.C_GOLD_DIM
	_dialog.add_theme_stylebox_override("panel", dialog_style)
	center.add_child(_dialog)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(PRESET_FULL_RECT)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.offset_left = 24
	vbox.offset_right = -24
	vbox.offset_top = 20
	vbox.offset_bottom = -20
	vbox.add_theme_constant_override("separation", 8)
	_dialog.add_child(vbox)

	# 标题
	var title := Label.new()
	title.text = "—— 设  置 ——"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", UITheme.C_GOLD)
	vbox.add_child(title)

	# 继续游戏按钮（默认高亮）
	var resume_btn := _make_button("继 续 游 戏", 320, 40)
	resume_btn.pressed.connect(func(): resume_requested.emit())
	resume_btn.call_deferred("grab_focus")
	vbox.add_child(resume_btn)

	# 新对局
	var new_btn := _make_button("新  对  局", 320, 40)
	new_btn.pressed.connect(func(): new_game_requested.emit())
	vbox.add_child(new_btn)

	# 认输（危险按钮）
	var resign_btn := _make_button("认      输", 320, 40, true)
	resign_btn.pressed.connect(func(): resign_requested.emit())
	vbox.add_child(resign_btn)

	# 部署特种
	var deploy_btn := _make_button("部 署 特 种 (S)", 320, 40)
	deploy_btn.pressed.connect(func(): deploy_special_requested.emit())
	vbox.add_child(deploy_btn)

	# 分隔线
	_add_separator(vbox)

	# 模式选择标签
	var mode_label := Label.new()
	mode_label.text = "—— 对战模式 ——"
	mode_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	mode_label.add_theme_font_size_override("font_size", 14)
	mode_label.add_theme_color_override("font_color", UITheme.C_TEXT_DIM)
	vbox.add_child(mode_label)

	# 模式按钮（2行）
	var mode_row1 := HBoxContainer.new()
	mode_row1.alignment = BoxContainer.ALIGNMENT_CENTER
	mode_row1.add_theme_constant_override("separation", 6)
	vbox.add_child(mode_row1)
	var mode_row2 := HBoxContainer.new()
	mode_row2.alignment = BoxContainer.ALIGNMENT_CENTER
	mode_row2.add_theme_constant_override("separation", 6)
	vbox.add_child(mode_row2)

	_add_mode_button(mode_row1, "本 地 双 人", "pvp", 0)
	_add_mode_button(mode_row1, "简  单", "pve", AIManager.Difficulty.EASY)
	_add_mode_button(mode_row1, "中  等", "pve", AIManager.Difficulty.NORMAL)
	_add_mode_button(mode_row2, "困  难", "pve", AIManager.Difficulty.HARD)

	# 分隔线
	_add_separator(vbox)

	# 联机按钮
	_online_btn = _make_button("联 机 对 战 …", 320, 36)
	_online_btn.pressed.connect(func():
		if _online_active:
			online_quit_pressed.emit()
		else:
			online_pressed.emit()
	)
	vbox.add_child(_online_btn)

	# 切换主题
	var theme_btn := _make_button("切 换 主 题 (T)", 320, 36)
	theme_btn.pressed.connect(func(): theme_cycle_requested.emit())
	vbox.add_child(theme_btn)

	# 返回主菜单
	var back_btn := _make_button("返 回 主 菜 单", 320, 40)
	back_btn.pressed.connect(func(): back_to_main_menu_requested.emit())
	vbox.add_child(back_btn)

	# 退出游戏（危险按钮）
	var quit_btn := _make_button("退 出 游 戏", 320, 40, true)
	quit_btn.pressed.connect(func(): quit_requested.emit())
	vbox.add_child(quit_btn)

	# 提示
	var hint := Label.new()
	hint.text = "按 ESC 继续"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", UITheme.C_TEXT_FAINT)
	vbox.add_child(hint)

func _add_mode_button(parent: Container, label: String, mode: String, difficulty: int) -> void:
	var btn := Button.new()
	btn.text = label
	btn.custom_minimum_size = Vector2(100, 32)
	btn.size_flags_horizontal = SIZE_SHRINK_CENTER
	btn.toggle_mode = true
	btn.button_pressed = (mode == "pvp")
	btn.add_theme_font_size_override("font_size", 14)
	btn.add_theme_color_override("font_color", UITheme.C_GOLD)
	btn.add_theme_color_override("font_hover_color", UITheme.C_GOLD_BRIGHT)
	btn.add_theme_color_override("font_pressed_color", UITheme.C_GOLD_BRIGHT)
	btn.add_theme_stylebox_override("normal", UITheme.make_button_style(mode == "pvp", false))
	btn.add_theme_stylebox_override("hover", UITheme.make_button_style(mode == "pvp", true))
	btn.add_theme_stylebox_override("pressed", UITheme.make_button_style(mode == "pvp", true))
	btn.pressed.connect(func(): _on_mode_selected(mode, difficulty))
	btn.mouse_entered.connect(func(): UITheme.animate_button_hover(btn, true))
	btn.mouse_exited.connect(func(): UITheme.animate_button_hover(btn, false))
	parent.add_child(btn)
	_mode_buttons.append({"btn": btn, "mode": mode, "difficulty": difficulty})

func _on_mode_selected(mode: String, difficulty: int) -> void:
	for entry in _mode_buttons:
		entry.btn.button_pressed = (entry.mode == mode and entry.difficulty == difficulty)
	mode_selected.emit(mode, difficulty)

func _make_button(label: String, w: int, h: int, danger: bool = false) -> Button:
	var b := Button.new()
	b.text = label
	b.custom_minimum_size = Vector2(w, h)
	b.size_flags_horizontal = SIZE_SHRINK_CENTER
	b.add_theme_font_size_override("font_size", 16)
	b.add_theme_color_override("font_color", UITheme.C_GOLD if not danger else UITheme.C_RED_WAR)
	b.add_theme_color_override("font_hover_color", UITheme.C_GOLD_BRIGHT if not danger else Color(1.0, 0.5, 0.35, 1.0))
	b.add_theme_color_override("font_pressed_color", UITheme.C_GOLD_BRIGHT if not danger else Color(1.0, 0.5, 0.35, 1.0))
	b.add_theme_stylebox_override("normal", UITheme.make_button_style(false, false, danger))
	b.add_theme_stylebox_override("hover", UITheme.make_button_style(false, true, danger))
	b.add_theme_stylebox_override("pressed", UITheme.make_button_style(false, true, danger))
	b.mouse_entered.connect(func(): UITheme.animate_button_hover(b, true))
	b.mouse_exited.connect(func(): UITheme.animate_button_hover(b, false))
	return b

func _add_separator(parent: Container) -> void:
	var sep := HSeparator.new()
	sep.add_theme_constant_override("separation", 6)
	parent.add_child(sep)

# ===== 入场动画：遮罩淡入 + 对话框缩放 =====
func _play_entrance_animation() -> void:
	# 遮罩淡入
	var t1 := _overlay.create_tween()
	t1.set_ease(Tween.EASE_OUT)
	t1.set_trans(Tween.TRANS_CUBIC)
	t1.tween_property(_overlay, "color:a", 0.72, 0.25)
	# 对话框缩放进场
	_dialog.scale = Vector2(0.85, 0.85)
	_dialog.modulate.a = 0.0
	var t2 := _dialog.create_tween()
	t2.set_ease(Tween.EASE_OUT)
	t2.set_trans(Tween.TRANS_BACK)
	t2.tween_property(_dialog, "scale", Vector2(1.0, 1.0), 0.25)
	t2.parallel().tween_property(_dialog, "modulate:a", 1.0, 0.25)

# ESC 处理：由 GameScreen 监听 ESC 弹出/关闭本菜单
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			resume_requested.emit()
			get_viewport().set_input_as_handled()
