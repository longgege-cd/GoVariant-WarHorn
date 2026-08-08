# 对局日志覆盖弹窗 —— 按 L 键呼出
#
# 设计：
#   - 全屏半透明遮罩淡入
#   - 中央对话框缩放进场
#   - 滚动列表显示每手详细记录（手数/玩家/动作/位置/提子/得分变化）
#   - 主题感知配色（像素风边框）
#   - ESC / L 再次按下关闭
#
# 数据由 GameScreen 注入（entries: Array[Dictionary]）
extends Control

signal dismissed

var _overlay: ColorRect = null
var _dialog: Panel = null
var _list: VBoxContainer = null
var _scroll_ref: ScrollContainer = null

const UITheme = preload("res://scripts/ui/UITheme.gd")

func _ready() -> void:
	set_anchors_preset(PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP  # 拦截下层输入

# 工厂方法：构建弹窗并填充日志条目
static func create(entries: Array, role_names: Dictionary) -> Control:
	var inst := preload("res://scripts/ui/GameLogOverlay.gd").new()
	inst._build(entries, role_names)
	return inst

func _build(entries: Array, role_names: Dictionary) -> void:
	# 1. 半透明遮罩
	_overlay = ColorRect.new()
	_overlay.set_anchors_preset(PRESET_FULL_RECT)
	_overlay.color = Color(0, 0, 0, 0.0)
	add_child(_overlay)

	# 2. 居中容器
	var center := CenterContainer.new()
	center.set_anchors_preset(PRESET_FULL_RECT)
	add_child(center)

	# 3. 对话框面板
	_dialog = Panel.new()
	_dialog.custom_minimum_size = Vector2(720, 560)
	var sb := StyleBoxFlat.new()
	sb.corner_detail = 1
	sb.bg_color = UITheme.C_PANEL_BG
	sb.border_width_left = 4
	sb.border_width_right = 4
	sb.border_width_top = 4
	sb.border_width_bottom = 4
	sb.border_color = UITheme.C_GOLD_DIM
	_dialog.add_theme_stylebox_override("panel", sb)
	center.add_child(_dialog)

	# 4. 对话框内容：标题 + 滚动列表 + 底部提示
	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(PRESET_FULL_RECT)
	vbox.offset_left = 16
	vbox.offset_right = -16
	vbox.offset_top = 12
	vbox.offset_bottom = -12
	vbox.add_theme_constant_override("separation", 8)
	_dialog.add_child(vbox)

	# 标题
	var title := Label.new()
	title.text = "对 局 日 志"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", UITheme.C_GOLD_BRIGHT)
	vbox.add_child(title)

	# 表头
	var header := Label.new()
	header.text = "  手  | 方  | 动作       | 位置  | 提子 | 得分变化"
	header.add_theme_font_size_override("font_size", 12)
	header.add_theme_color_override("font_color", UITheme.C_TEXT_DIM)
	vbox.add_child(header)

	# 分隔线
	var sep := HSeparator.new()
	sep.add_theme_constant_override("separation", 2)
	vbox.add_child(sep)

	# 滚动列表
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	vbox.add_child(scroll)

	_list = VBoxContainer.new()
	_list.size_flags_horizontal = SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 2)
	scroll.add_child(_list)

	# 填充条目
	if entries.is_empty():
		var empty := Label.new()
		empty.text = "（暂无对局记录）"
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.add_theme_font_size_override("font_size", 14)
		empty.add_theme_color_override("font_color", UITheme.C_TEXT_DIM)
		_list.add_child(empty)
	else:
		for e in entries:
			_list.add_child(_make_entry_label(e, role_names))
		# 滚动到底部（延迟到进入场景树后执行）
		_scroll_ref = scroll
		call_deferred("_scroll_to_bottom")

	# 底部提示
	var hint := Label.new()
	hint.text = "L / ESC 关闭"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", UITheme.C_TEXT_DIM)
	vbox.add_child(hint)

	# 入场动画
	_play_entrance()

# 格式化单条日志为 Label
func _make_entry_label(e: Dictionary, role_names: Dictionary) -> Label:
	var ply: int = e.get("ply", 0)
	var color: int = e.get("color", Const.BLACK)
	var side_name: String = role_names.get(color, "黑方" if color == Const.BLACK else "白方")
	var action: String = _action_label(e)
	var pos_str: String = _pos_label(e)
	var cap: int = e.get("captures", 0)
	var score_str: String = _score_label(e)
	var text: String = "%3d. | %-5s | %-8s | %-5s | %s%d | %s" % [
		ply, side_name, action, pos_str, "提" if cap > 0 else "  ", cap, score_str
	]
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_color_override("font_color", UITheme.C_TEXT)
	return lbl

func _action_label(e: Dictionary) -> String:
	if e.get("passed", false):
		return "虚手"
	if e.get("deployed", false):
		return "部署特种"
	if e.get("ambush", false):
		return "落子·伏击"
	return "落子"

func _pos_label(e: Dictionary) -> String:
	var placed = e.get("placed", null)
	if placed == null or not (placed is Vector2i) or placed.x < 0:
		return "—"
	var cols: String = "ABCDEFGHJKLMNOPQRST"
	return "%s%d" % [cols[placed.x], Const.BOARD_SIZE - placed.y]

func _score_label(e: Dictionary) -> String:
	var before: int = e.get("score_before", 0)
	var after: int = e.get("score_after", 0)
	var delta: int = after - before
	var sign: String = "+" if delta >= 0 else ""
	return "%d→%d (%s%d)" % [before, after, sign, delta]

func _play_entrance() -> void:
	var t1 := _overlay.create_tween()
	t1.set_ease(Tween.EASE_OUT)
	t1.set_trans(Tween.TRANS_CUBIC)
	t1.tween_property(_overlay, "color:a", 0.7, 0.25)
	_dialog.modulate.a = 0.0
	_dialog.scale = Vector2(0.9, 0.9)
	var t2 := _dialog.create_tween()
	t2.set_ease(Tween.EASE_OUT)
	t2.set_trans(Tween.TRANS_BACK)
	t2.tween_interval(0.08)
	t2.tween_property(_dialog, "modulate:a", 1.0, 0.32)
	t2.parallel().tween_property(_dialog, "scale", Vector2(1.0, 1.0), 0.32)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_ESCAPE, KEY_L:
				_close()
				get_viewport().set_input_as_handled()

func _close() -> void:
	dismissed.emit()
	queue_free()

# 滚动列表到底部（显示最新一手）；由 call_deferred 触发，确保已进入场景树
func _scroll_to_bottom() -> void:
	if _scroll_ref == null or not is_instance_valid(_scroll_ref):
		return
	if _list == null or _list.get_child_count() == 0:
		return
	_scroll_ref.ensure_control_visible(_list.get_child(_list.get_child_count() - 1))
