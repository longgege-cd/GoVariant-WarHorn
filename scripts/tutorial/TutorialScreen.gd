# 规则教程主界面：关卡列表（按阶段分组）+ 进度解锁
#
# 解锁规则：完成前一关解锁下一关（可选关 5-1 可跳过）
# 完成状态持久化到 user://tutorial_progress.json
class_name TutorialScreen
extends Control

signal back_to_main_menu_requested

var _progress: Dictionary = {}
var _lesson_view: TutorialLesson = null
var _lesson_btns: Array = []  # Array[Button]：关卡行按钮（索引=关卡索引）

func _ready() -> void:
	set_anchors_preset(PRESET_FULL_RECT)
	_progress = TutorialProgress.load_progress()
	_build_ui()

func _build_ui() -> void:
	_lesson_btns.clear()
	# 背景
	var bg := ColorRect.new()
	bg.set_anchors_preset(PRESET_FULL_RECT)
	bg.color = Color(0.03, 0.03, 0.05)
	add_child(bg)

	var root := VBoxContainer.new()
	root.set_anchors_preset(PRESET_FULL_RECT)
	root.offset_left = 60
	root.offset_top = 30
	root.offset_right = -60
	root.offset_bottom = -40
	root.add_theme_constant_override("separation", 8)
	add_child(root)

	# 标题栏
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 20)
	root.add_child(top)
	var back_btn := _make_button("← 返回主菜单", 160, 40)
	back_btn.pressed.connect(func(): back_to_main_menu_requested.emit())
	top.add_child(back_btn)
	var title := Label.new()
	title.text = "规则教程"
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", UITheme.C_GOLD)
	top.add_child(title)
	var sub := Label.new()
	sub.text = "共 %d 关 · 完成前一关解锁下一关" % TutorialProgress.TOTAL_LESSONS
	sub.add_theme_font_size_override("font_size", 14)
	sub.add_theme_color_override("font_color", UITheme.C_GOLD_DIM)
	sub.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	top.add_child(sub)
	var spacer := Control.new()
	spacer.size_flags_horizontal = SIZE_EXPAND_FILL
	top.add_child(spacer)
	var reset_btn := _make_button("重置进度", 100, 36)
	reset_btn.pressed.connect(_on_reset_progress)
	top.add_child(reset_btn)

	# 关卡列表（滚动）
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	root.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 4)
	scroll.add_child(list)

	# 按阶段分组
	var stages := ["基础", "核心", "进阶", "高级", "可选"]
	var stage_color := {
		"基础": UITheme.C_GOLD_BRIGHT,
		"核心": Color(0.7, 0.85, 1.0),
		"进阶": Color(0.85, 0.7, 1.0),
		"高级": Color(1.0, 0.8, 0.5),
		"可选": Color(0.6, 0.6, 0.6),
	}
	for stage in stages:
		var stage_header := Label.new()
		stage_header.text = "—— %s ——" % stage
		stage_header.add_theme_font_size_override("font_size", 18)
		stage_header.add_theme_color_override("font_color", stage_color.get(stage, UITheme.C_GOLD_DIM))
		list.add_child(stage_header)
		for i in LessonData.LESSONS.size():
			var lesson: Dictionary = LessonData.get_lesson(i)
			if lesson.get("stage", "") != stage:
				continue
			_add_lesson_row(list, i, lesson)

func _add_lesson_row(parent: Container, idx: int, lesson: Dictionary) -> void:
	var unlocked: bool = TutorialProgress.is_unlocked(_progress, idx)
	var completed: bool = TutorialProgress.is_completed(_progress, idx)

	var row := Button.new()
	row.custom_minimum_size = Vector2(0, 46)
	row.size_flags_horizontal = SIZE_EXPAND_FILL
	row.disabled = not unlocked
	row.text = "%s  %s    %s    %s" % [
		lesson.get("id", ""),
		lesson.get("title", ""),
		lesson.get("goal", ""),
		"✓ 已完成" if completed else ("🔒 未解锁" if not unlocked else "点击学习"),
	]
	row.add_theme_font_size_override("font_size", 14)
	row.add_theme_color_override("font_color", UITheme.C_GOLD if unlocked else Color(0.4, 0.4, 0.4))
	row.add_theme_color_override("font_hover_color", UITheme.C_GOLD_BRIGHT)
	row.add_theme_stylebox_override("normal", _make_row_style(unlocked, false))
	row.add_theme_stylebox_override("hover", _make_row_style(unlocked, true))
	row.add_theme_stylebox_override("pressed", _make_row_style(unlocked, true))
	row.pressed.connect(_open_lesson.bind(idx))
	_lesson_btns.append(row)
	parent.add_child(row)

func _open_lesson(idx: int) -> void:
	if _lesson_view != null:
		_lesson_view.queue_free()
	_lesson_view = preload("res://scripts/tutorial/TutorialLesson.gd").new()
	_lesson_view.set_anchors_preset(PRESET_FULL_RECT)
	_lesson_view.configure(idx, _progress)
	add_child(_lesson_view)
	_lesson_view.back_requested.connect(func():
		_lesson_view.queue_free()
		_lesson_view = null
		_progress = TutorialProgress.load_progress()
		_rebuild_list()
	)
	_lesson_view.lesson_completed.connect(func(_i: int):
		_progress = TutorialProgress.load_progress()
	)

func _rebuild_list() -> void:
	# 简单重建整个界面
	for child in get_children():
		child.queue_free()
	_build_ui()

func _on_reset_progress() -> void:
	TutorialProgress.reset_progress()
	_progress = TutorialProgress.load_progress()
	_rebuild_list()

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

func _make_row_style(unlocked: bool, hover: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.corner_detail = 1
	sb.border_width_left = 1
	sb.border_width_right = 1
	sb.border_width_top = 1
	sb.border_width_bottom = 1
	sb.border_color = UITheme.C_GOLD_DIM
	if unlocked:
		sb.bg_color = Color(0.10, 0.08, 0.06, 0.9) if hover else Color(0.05, 0.04, 0.03, 0.9)
	else:
		sb.bg_color = Color(0.04, 0.04, 0.04, 0.8)
	return sb
