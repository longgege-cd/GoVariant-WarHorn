# 控制面板：精简按钮（悔棋/虚手/认输/设置）
#
# 设计：
#   - 显示 4 个常用按钮：悔棋、虚手、认输、设置（ESC 菜单）
#   - 其他功能（新局/部署/主题/模式/联机）移入 ESC 暂停菜单
#   - 隐藏按钮仍保留变量供 update_state 引用，避免空引用
extends HBoxContainer

signal pass_pressed
signal resign_pressed
signal new_game_pressed
signal deploy_special_pressed
signal undo_pressed
signal cycle_theme_pressed
signal mode_selected(mode: String, difficulty: int)
signal online_pressed
signal online_quit_pressed
signal menu_pressed  # ESC 菜单按钮（设置）

const AIManager = preload("res://scripts/ai/AIManager.gd")

var _pass_btn: Button
var _resign_btn: Button
var _new_game_btn: Button
var _deploy_btn: Button
var _undo_btn: Button
var _theme_btn: Button
var _menu_btn: Button
# 模式按钮组
var _mode_pvp_btn: Button
var _mode_easy_btn: Button
var _mode_med_btn: Button
var _mode_hard_btn: Button
var _mode_buttons: Array = []
var _current_mode: String = "pvp"
var _special_enabled: bool = false
var _deploy_mode: bool = false
# 联机按钮
var _online_btn: Button
var _online_quit_btn: Button
var _all_buttons: Array = []  # 所有按钮（供主题切换时刷新）

func _ready() -> void:
	_build_ui()
	_apply_theme()
	_refresh_button_texts()
	ThemeManager.theme_changed.connect(_on_theme_changed)
	LocaleManager.locale_changed.connect(_refresh_button_texts)

func _on_theme_changed(_t: BaseTheme) -> void:
	_apply_theme()

func _build_ui() -> void:
	add_theme_constant_override("separation", 10)
	alignment = BoxContainer.ALIGNMENT_CENTER

	# 显示的 3 个按钮：悔棋 | 虚手 | 设置(菜单)
	_undo_btn = _make_button(LocaleManager.L("control.undo"), 100, 36)
	_undo_btn.pressed.connect(func(): undo_pressed.emit())
	add_child(_undo_btn)

	_pass_btn = _make_button(LocaleManager.L("control.pass"), 100, 36)
	_pass_btn.pressed.connect(func(): pass_pressed.emit())
	add_child(_pass_btn)

	_resign_btn = _make_button(LocaleManager.L("control.resign"), 100, 36)
	_resign_btn.pressed.connect(func(): resign_pressed.emit())
	add_child(_resign_btn)

	_menu_btn = _make_button(LocaleManager.L("control.menu"), 120, 36)
	_menu_btn.pressed.connect(func(): menu_pressed.emit())
	add_child(_menu_btn)

	# 隐藏按钮（保留变量供 update_state 引用，避免空引用崩溃）
	_new_game_btn = _make_button(LocaleManager.L("control.new_game"), 60, 30)
	_new_game_btn.visible = false
	_new_game_btn.pressed.connect(func(): new_game_pressed.emit())
	add_child(_new_game_btn)

	_deploy_btn = _make_button(LocaleManager.L("control.deploy"), 70, 30)
	_deploy_btn.visible = false
	_deploy_btn.pressed.connect(func(): deploy_special_pressed.emit())
	add_child(_deploy_btn)

	_theme_btn = _make_button(LocaleManager.L("control.theme"), 70, 30)
	_theme_btn.visible = false
	_theme_btn.pressed.connect(func(): cycle_theme_pressed.emit())
	add_child(_theme_btn)

	# 隐藏的模式按钮
	_mode_pvp_btn = _make_button(LocaleManager.L("control.local_2p"), 60, 30)
	_mode_pvp_btn.toggle_mode = true
	_mode_pvp_btn.button_pressed = true
	_mode_pvp_btn.visible = false
	_mode_pvp_btn.pressed.connect(func(): _on_mode_selected("pvp", 0))
	add_child(_mode_pvp_btn)

	_mode_easy_btn = _make_button(LocaleManager.L("ai.easy"), 60, 30)
	_mode_easy_btn.toggle_mode = true
	_mode_easy_btn.visible = false
	_mode_easy_btn.pressed.connect(func(): _on_mode_selected("pve", AIManager.Difficulty.EASY))
	add_child(_mode_easy_btn)

	_mode_med_btn = _make_button(LocaleManager.L("control.mode_med"), 60, 30)
	_mode_med_btn.toggle_mode = true
	_mode_med_btn.visible = false
	_mode_med_btn.pressed.connect(func(): _on_mode_selected("pve", AIManager.Difficulty.NORMAL))
	add_child(_mode_med_btn)

	_mode_hard_btn = _make_button(LocaleManager.L("ai.hard"), 60, 30)
	_mode_hard_btn.toggle_mode = true
	_mode_hard_btn.visible = false
	_mode_hard_btn.pressed.connect(func(): _on_mode_selected("pve", AIManager.Difficulty.HARD))
	add_child(_mode_hard_btn)
	_mode_buttons = [_mode_pvp_btn, _mode_easy_btn, _mode_med_btn, _mode_hard_btn]

	# 隐藏的联机按钮
	_online_btn = _make_button(LocaleManager.L("control.online"), 70, 30)
	_online_btn.visible = false
	_online_btn.pressed.connect(func(): online_pressed.emit())
	add_child(_online_btn)

	_online_quit_btn = _make_button(LocaleManager.L("control.exit_online"), 80, 30)
	_online_quit_btn.visible = false
	_online_quit_btn.disabled = true
	_online_quit_btn.pressed.connect(func(): online_quit_pressed.emit())
	add_child(_online_quit_btn)

func _make_button(label: String, w: int, h: int) -> Button:
	var b := Button.new()
	b.text = label
	b.custom_minimum_size = Vector2(w, h)
	b.size_flags_horizontal = SIZE_SHRINK_CENTER
	_all_buttons.append(b)
	return b

# 刷新所有按钮文字（语言切换时调用）
func _refresh_button_texts() -> void:
	if _undo_btn != null:
		_undo_btn.text = LocaleManager.L("control.undo")
	if _pass_btn != null:
		_pass_btn.text = LocaleManager.L("control.pass")
	if _resign_btn != null:
		_resign_btn.text = LocaleManager.L("control.resign")
	if _menu_btn != null:
		_menu_btn.text = LocaleManager.L("control.menu")
	if _new_game_btn != null:
		_new_game_btn.text = LocaleManager.L("control.new_game")
	if _deploy_btn != null:
		_deploy_btn.text = LocaleManager.L("control.cancel_deploy") if _deploy_mode else LocaleManager.L("control.deploy")
	if _theme_btn != null:
		_theme_btn.text = LocaleManager.L("control.theme")
	if _mode_pvp_btn != null:
		_mode_pvp_btn.text = LocaleManager.L("control.local_2p")
	if _mode_easy_btn != null:
		_mode_easy_btn.text = LocaleManager.L("ai.easy")
	if _mode_med_btn != null:
		_mode_med_btn.text = LocaleManager.L("control.mode_med")
	if _mode_hard_btn != null:
		_mode_hard_btn.text = LocaleManager.L("ai.hard")
	if _online_btn != null:
		_online_btn.text = LocaleManager.L("control.online")
	if _online_quit_btn != null:
		_online_quit_btn.text = LocaleManager.L("control.exit_online")

# 应用当前主题到所有按钮（字色 + 像素风 stylebox）
func _apply_theme() -> void:
	var t: BaseTheme = ThemeManager.current
	if t == null:
		return
	var font_c: Color = t.font_color
	var hover_c: Color = t.active_side_color
	var border_c: Color = t.active_side_color
	for btn in _all_buttons:
		if btn == null or not is_instance_valid(btn):
			continue
		btn.add_theme_color_override("font_color", font_c)
		btn.add_theme_color_override("font_hover_color", hover_c)
		btn.add_theme_color_override("font_pressed_color", hover_c)
		btn.add_theme_color_override("font_disabled_color", font_c.darkened(0.5))
		var sb_normal := StyleBoxFlat.new()
		sb_normal.corner_detail = 1
		sb_normal.border_width_left = 2
		sb_normal.border_width_right = 2
		sb_normal.border_width_top = 2
		sb_normal.border_width_bottom = 2
		sb_normal.bg_color = Color(0.04, 0.03, 0.05, 0.9)
		sb_normal.border_color = border_c.darkened(0.4)
		var sb_hover := sb_normal.duplicate()
		sb_hover.bg_color = Color(0.10, 0.08, 0.06, 0.95)
		sb_hover.border_color = border_c
		btn.add_theme_stylebox_override("normal", sb_normal)
		btn.add_theme_stylebox_override("hover", sb_hover)
		btn.add_theme_stylebox_override("pressed", sb_hover)
		btn.add_theme_stylebox_override("disabled", sb_normal)

# 模式按钮互斥处理
func _on_mode_selected(mode: String, difficulty: int) -> void:
	_current_mode = mode
	for btn in _mode_buttons:
		btn.button_pressed = false
	var active_btn: Button = _mode_pvp_btn
	if mode == "pve":
		match difficulty:
			AIManager.Difficulty.EASY:
				active_btn = _mode_easy_btn
			AIManager.Difficulty.NORMAL:
				active_btn = _mode_med_btn
			AIManager.Difficulty.HARD:
				active_btn = _mode_hard_btn
	active_btn.button_pressed = true
	mode_selected.emit(mode, difficulty)

# 根据当前局面更新按钮状态
# deploy_phase=true（布局阶段）：禁用虚手/认输/部署/悔棋，仅允许布局落子
func update_state(session: GameSession, deploy_mode: bool, deploy_phase: bool = false) -> void:
	if session == null:
		return
	var game_over: bool = session.game_over
	if deploy_phase:
		_pass_btn.disabled = true
		_resign_btn.disabled = true
		_deploy_btn.disabled = true
		_undo_btn.disabled = true
		return
	_pass_btn.disabled = game_over
	_resign_btn.disabled = game_over
	_deploy_btn.disabled = game_over or not session.special.enabled
	_undo_btn.disabled = game_over or not session.can_undo()
	_deploy_mode = deploy_mode
	if deploy_mode:
		_deploy_btn.text = LocaleManager.L("control.cancel_deploy")
	else:
		_deploy_btn.text = LocaleManager.L("control.deploy")
	# 特种部队冷却/次数
	if not game_over and session.special.enabled:
		var can_deploy: bool = session.special.can_deploy(session.to_move, session.ply)
		_deploy_btn.disabled = not can_deploy and not deploy_mode

# 更新联机按钮状态
func update_online_state(online: bool) -> void:
	_online_quit_btn.disabled = not online
	_online_btn.disabled = online
