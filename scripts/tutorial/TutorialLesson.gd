# 教程关卡界面：讲解 + 交互棋盘 + 完成判定
#
# 设计（参考《规则体系教学模块设计文档》v2.0）：
#   - 渐进式：每关只讲 1-2 个概念，讲解后立即在棋盘实操
#   - 即时反馈：正确/错误操作都有状态提示
#   - 视觉化：区域色块 / 气高亮 / 推荐落点标记
#
# 教学棋盘为「自由落子」模式：玩家可连续执黑（或切白）落子，
# 便于演示提吃/围空/围困等场景（规则引擎轮流限制在教学模式下放宽）。
class_name TutorialLesson
extends Control

signal back_requested
signal lesson_completed(idx: int)

var lesson_idx: int = 0
var lesson: Dictionary = {}
var session: GameSession = null
var progress: Dictionary = {}
var _player_color: int = Const.BLACK
var _completed: bool = false
var _zone_step: int = 0       # click_zone 已完成的子步骤
var _pass_done: bool = false  # 虚手关完成标记
var _deploy_armed: bool = false
var _last_outcome: Dictionary = {}  # 最近一手结果（capture 判定用）
var _status_timer: float = 0.0
var _status_text: String = ""
var _status_error: bool = false

# 棋盘区域与几何
var _board_rect := Rect2(40, 130, 560, 560)
var _cell: float = 560.0 / 19.0
var _hover: Vector2i = Vector2i(-1, -1)

# UI 节点
var _title_label: Label = null
var _stage_label: Label = null
var _goal_label: Label = null
var _info: RichTextLabel = null
var _status_label: Label = null
var _stones_left_label: Label = null
var _back_btn: Button = null
var _retry_btn: Button = null
var _complete_btn: Button = null
var _pass_btn: Button = null
var _deploy_btn: Button = null
var _color_btn: Button = null

func _ready() -> void:
	set_anchors_preset(PRESET_FULL_RECT)
	_build_ui()
	_start_lesson()

func configure(idx: int, prog: Dictionary) -> void:
	lesson_idx = idx
	progress = prog
	lesson = LessonData.get_lesson(idx)

# ===== UI 构建 =====
func _build_ui() -> void:
	# 顶部标题栏
	var top := HBoxContainer.new()
	top.position = Vector2(20, 12)
	top.size = Vector2(1460, 40)
	top.add_theme_constant_override("separation", 16)
	add_child(top)
	_back_btn = _make_button("← 关卡列表", 140, 36)
	_back_btn.pressed.connect(func(): back_requested.emit())
	top.add_child(_back_btn)
	_stage_label = Label.new()
	_stage_label.add_theme_font_size_override("font_size", 15)
	_stage_label.add_theme_color_override("font_color", UITheme.C_GOLD_DIM)
	top.add_child(_stage_label)
	_title_label = Label.new()
	_title_label.add_theme_font_size_override("font_size", 24)
	_title_label.add_theme_color_override("font_color", UITheme.C_GOLD)
	top.add_child(_title_label)
	var spacer := Control.new()
	spacer.size_flags_horizontal = SIZE_EXPAND_FILL
	top.add_child(spacer)
	_retry_btn = _make_button("重 试", 100, 36)
	_retry_btn.pressed.connect(_start_lesson)
	top.add_child(_retry_btn)

	# 右侧信息区
	var info_panel := PanelContainer.new()
	info_panel.position = Vector2(660, 80)
	info_panel.size = Vector2(820, 620)
	info_panel.add_theme_stylebox_override("panel", _make_panel_style())
	add_child(info_panel)
	var info_vbox := VBoxContainer.new()
	info_vbox.add_theme_constant_override("separation", 12)
	info_vbox.offset_left = 16
	info_vbox.offset_top = 14
	info_vbox.offset_right = -16
	info_vbox.offset_bottom = -14
	info_panel.add_child(info_vbox)

	_goal_label = Label.new()
	_goal_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_goal_label.add_theme_font_size_override("font_size", 16)
	_goal_label.add_theme_color_override("font_color", UITheme.C_GOLD_BRIGHT)
	info_vbox.add_child(_goal_label)

	var sep := HSeparator.new()
	info_vbox.add_child(sep)

	_info = RichTextLabel.new()
	_info.bbcode_enabled = true
	_info.scroll_active = true
	_info.size_flags_vertical = SIZE_EXPAND_FILL
	_info.add_theme_font_size_override("normal_font_size", 15)
	info_vbox.add_child(_info)

	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.add_theme_font_size_override("font_size", 15)
	info_vbox.add_child(_status_label)

	# 操作按钮行
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 10)
	info_vbox.add_child(btn_row)
	_complete_btn = _make_button("我已理解，下一关", 200, 40)
	_complete_btn.visible = false
	_complete_btn.pressed.connect(func(): _complete())
	btn_row.add_child(_complete_btn)
	_pass_btn = _make_button("虚 手", 120, 40)
	_pass_btn.visible = false
	_pass_btn.pressed.connect(_on_pass)
	btn_row.add_child(_pass_btn)
	_deploy_btn = _make_button("部署特种", 120, 40)
	_deploy_btn.visible = false
	_deploy_btn.pressed.connect(_on_deploy_armed)
	btn_row.add_child(_deploy_btn)
	_color_btn = _make_button("执子：黑", 120, 40)
	_color_btn.pressed.connect(_toggle_color)
	btn_row.add_child(_color_btn)

	_stones_left_label = Label.new()
	_stones_left_label.add_theme_font_size_override("font_size", 13)
	_stones_left_label.add_theme_color_override("font_color", UITheme.C_GOLD_DIM)
	info_vbox.add_child(_stones_left_label)

# ===== 关卡开始 =====
func _start_lesson() -> void:
	_completed = false
	_zone_step = 0
	_pass_done = false
	_deploy_armed = false
	_last_outcome = {}
	_player_color = Const.BLACK
	session = GameSession.new(Const.KOMI_DEFAULT, true)
	session.emit_signals = true
	# 布置初始棋子
	for s in lesson.get("setup", []):
		session.board.set_at(s[0], s[1], s[2])
	_stage_label.text = lesson.get("stage", "") + " 关卡"
	_title_label.text = "%s %s" % [lesson.get("id", ""), lesson.get("title", "")]
	_goal_label.text = "目标：" + lesson.get("goal", "")
	_refresh_info()
	_update_complete_btn()
	_update_stones_label()
	_update_color_btn()
	_status_label.text = ""
	queue_redraw()

# 讲解文本（bbcode）
func _refresh_info() -> void:
	var parts: Array = []
	var explains: Array = lesson.get("explain", [])
	for i in explains.size():
		var line: String = explains[i]
		if line.begins_with("- "):
			parts.append("[color=#c9b283]•[/color] " + line.substr(2))
		else:
			parts.append(line)
		if i < explains.size() - 1:
			parts.append("")
	_info.text = "\n".join(parts)

# ===== 落子交互 =====
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var pos: Vector2 = event.position
		if _board_rect.has_point(pos):
			var local: Vector2 = pos - _board_rect.position
			var col: int = int(local.x / _cell)
			var row: int = int(local.y / _cell)
			if row >= 0 and row < 19 and col >= 0 and col < 19:
				_on_board_clicked(row, col)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion:
		var pos2: Vector2 = event.position
		var nh: Vector2i = Vector2i(-1, -1)
		if _board_rect.has_point(pos2):
			var local: Vector2 = pos2 - _board_rect.position
			var col: int = int(local.x / _cell)
			var row: int = int(local.y / _cell)
			if row >= 0 and row < 19 and col >= 0 and col < 19:
				nh = Vector2i(col, row)
		if nh != _hover:
			_hover = nh
			queue_redraw()

func _on_board_clicked(row: int, col: int) -> void:
	if _completed:
		return
	if lesson.get("target", "free") == "click_zone":
		_handle_zone_click(row, col)
		return
	# 部署模式：先选点
	if _deploy_armed:
		session.to_move = _player_color
		var out: Dictionary = session.deploy_special(_player_color, row, col)
		if out.ok:
			_deploy_armed = false
			_last_outcome = out
			_set_status("特种部队已部署（隐藏棋子）", false)
			_update_complete_btn()
			_check_complete()
			queue_redraw()
		else:
			_set_status(out.get("reason", "部署失败"), true)
		return
	# 自由落子（教学模式放宽轮流限制）
	session.to_move = _player_color
	var out: Dictionary = session.play_move(_player_color, row, col)
	if out.ok:
		_last_outcome = out
		if out.get("captured", []).size() > 0:
			_set_status("提吃 %d 子！" % out.captured.size(), false)
		else:
			_set_status("落子成功", false)
		queue_redraw()
		_check_complete()
	else:
		_set_status("禁止落子：" + out.get("reason", ""), true)
		queue_redraw()

# 1-1 区域点击
func _handle_zone_click(row: int, col: int) -> void:
	var zone: int = TutorialChecks.zone_of(row)
	if zone == _zone_step:
		_zone_step += 1
		_set_status("✓ 正确（%s）" % _zone_name(zone), false)
		if _zone_step >= 3:
			_complete()
	else:
		_set_status("点错了：需要点击「%s」区域" % _zone_name(_zone_step), true)
	queue_redraw()

func _zone_name(z: int) -> String:
	match z:
		0: return "黑方领土（第1-9行）"
		1: return "边境线（第10行）"
		2: return "白方领土（第11-19行）"
	return ""

# 虚手
func _on_pass() -> void:
	if _completed:
		return
	session.to_move = _player_color
	var out: Dictionary = session.do_pass(_player_color)
	if out.ok:
		_pass_done = true
		_set_status("虚手成功：保留棋子，等待对方落子", false)
		_check_complete()
	else:
		_set_status("虚手失败：" + out.get("reason", ""), true)

# 部署特种武装
func _on_deploy_armed() -> void:
	if _completed:
		return
	_deploy_armed = not _deploy_armed
	if _deploy_armed:
		_set_status("请点击白方领土（第11行以下）的任意空点部署", false)
	else:
		_set_status("已取消部署", false)

func _toggle_color() -> void:
	_player_color = Const.opponent(_player_color)
	_update_color_btn()

func _update_color_btn() -> void:
	if _color_btn != null:
		_color_btn.text = "执子：" + ("黑" if _player_color == Const.BLACK else "白")

# ===== 完成判定 =====
func _check_complete() -> void:
	if _completed:
		return
	var target: String = lesson.get("target", "free")
	if TutorialChecks.is_complete(target, session, _player_color, {"pass_done": _pass_done, "last_outcome": _last_outcome}):
		_complete()

func _complete() -> void:
	if _completed:
		return
	_completed = true
	_set_status("🎉 关卡完成！", false)
	TutorialProgress.mark_completed(progress, lesson_idx)
	_update_complete_btn()
	lesson_completed.emit(lesson_idx)
	queue_redraw()

func _update_complete_btn() -> void:
	if _complete_btn == null:
		return
	var target: String = lesson.get("target", "free")
	# free 类关卡显示「我已理解」按钮；任务类完成后也显示（可继续/下一关由列表控制）
	_complete_btn.visible = (target == "free" or _completed)
	_complete_btn.text = "下一关" if _completed and lesson_idx < TutorialProgress.TOTAL_LESSONS - 1 else "我已理解，下一关"
	_pass_btn.visible = (target == "pass")
	_deploy_btn.visible = (target == "deploy")

# ===== 状态提示 =====
func _set_status(msg: String, is_error: bool) -> void:
	_status_text = msg
	_status_error = is_error
	_status_label.text = msg
	_status_label.add_theme_color_override("font_color", Color(0.95, 0.4, 0.35) if is_error else UITheme.C_GOLD_BRIGHT)
	_status_timer = 4.0

func _update_stones_label() -> void:
	if _stones_left_label != null:
		_stones_left_label.text = "剩余棋子：黑 %d / 白 %d" % [session.pieces_left(Const.BLACK), session.pieces_left(Const.WHITE)]

func _process(delta: float) -> void:
	if _status_timer > 0:
		_status_timer -= delta
		if _status_timer <= 0 and _status_label != null:
			_status_label.text = ""

# ===== 绘制 =====
func _draw() -> void:
	_draw_background()
	_draw_board()

func _draw_background() -> void:
	draw_rect(Rect2(0, 0, size.x, size.y), Color(0.03, 0.03, 0.05), true)

func _draw_board() -> void:
	var rect: Rect2 = _board_rect
	var n: int = 19
	# 棋盘底色
	draw_rect(rect, Color(0.12, 0.10, 0.08), true)
	# 区域色块（1-1）
	if lesson.get("id", "") == "1-1":
		var mid_row: int = Const.BORDER_ROW
		var top_h: float = rect.position.y + (mid_row + 0.5) * _cell
		var bot_h: float = rect.position.y + (mid_row + 0.5) * _cell
		draw_rect(Rect2(rect.position, Vector2(rect.size.x, top_h - rect.position.y)), Color(0.15, 0.20, 0.32, 0.55), true)
		draw_rect(Rect2(Vector2(rect.position.x, bot_h), Vector2(rect.size.x, rect.end.y - bot_h)), Color(0.32, 0.16, 0.15, 0.55), true)
	# 网格
	for i in n:
		var p: float = rect.position.x + i * _cell
		draw_line(Vector2(p, rect.position.y), Vector2(p, rect.end.y), Color(0.35, 0.32, 0.28, 0.8), 1.0)
		var q: float = rect.position.y + i * _cell
		draw_line(Vector2(rect.position.x, q), Vector2(rect.end.x, q), Color(0.35, 0.32, 0.28, 0.8), 1.0)
	# 星位
	for srow in [3, 9, 15]:
		for scol in [3, 9, 15]:
			var sp: Vector2 = _point(srow, scol)
			draw_circle(sp, 3.0, Color(0.55, 0.52, 0.45))
	# 边框
	draw_rect(rect, UITheme.C_GOLD_DIM, false, 2.0)
	# 提示点（hint）
	for h in lesson.get("hint", []):
		var hp: Vector2 = _point(h[0], h[1])
		draw_circle(hp, 6.0, Color(0.3, 0.85, 0.4, 0.9))
	# 气高亮（1-2：中央黑子的气）
	if lesson.get("id", "") == "1-2":
		for n2 in session.board.neighbors(9, 9):
			if session.board.get_at(n2[0], n2[1]) == Const.EMPTY:
				draw_circle(_point(n2[0], n2[1]), 5.0, Color(0.3, 0.8, 0.9, 0.7))
	# 棋子
	for r in 19:
		for c in 19:
			var v: int = session.board.get_at(r, c)
			if v == Const.EMPTY:
				continue
			var center: Vector2 = _point(r, c)
			var radius: float = _cell * 0.42
			if v == Const.BLACK:
				draw_circle(center, radius, Color(0.12, 0.12, 0.14))
				draw_circle(center, radius, Color(0.35, 0.35, 0.38), false, 2.0)
			else:
				draw_circle(center, radius, Color(0.92, 0.92, 0.90))
				draw_circle(center, radius, Color(0.55, 0.55, 0.52), false, 2.0)
	# 悬停指示
	if _hover.x >= 0 and not _completed:
		draw_rect(Rect2(_point(_hover.y, _hover.x) - Vector2(_cell * 0.5, _cell * 0.5), Vector2(_cell, _cell)), Color(1, 1, 1, 0.08), true)

func _point(row: int, col: int) -> Vector2:
	return _board_rect.position + Vector2((col + 0.5) * _cell, (row + 0.5) * _cell)

# ===== 辅助 =====
func _make_button(text: String, w: int, h: int) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(w, h)
	b.add_theme_font_size_override("font_size", 14)
	b.add_theme_color_override("font_color", UITheme.C_GOLD)
	b.add_theme_color_override("font_hover_color", UITheme.C_GOLD_BRIGHT)
	b.add_theme_stylebox_override("normal", _make_btn_style(false))
	b.add_theme_stylebox_override("hover", _make_btn_style(true))
	b.add_theme_stylebox_override("pressed", _make_btn_style(true))
	return b

func _make_btn_style(hover: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.corner_detail = 1
	sb.border_width_left = 1
	sb.border_width_right = 1
	sb.border_width_top = 1
	sb.border_width_bottom = 1
	sb.border_color = UITheme.C_GOLD_BRIGHT if hover else UITheme.C_GOLD_DIM
	sb.bg_color = Color(0.10, 0.08, 0.06, 0.9) if hover else Color(0.05, 0.04, 0.03, 0.9)
	return sb

func _make_panel_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.corner_detail = 1
	sb.bg_color = Color(0.06, 0.05, 0.04, 0.95)
	sb.border_width_left = 1
	sb.border_width_right = 1
	sb.border_width_top = 1
	sb.border_width_bottom = 1
	sb.border_color = UITheme.C_GOLD_DIM
	return sb
