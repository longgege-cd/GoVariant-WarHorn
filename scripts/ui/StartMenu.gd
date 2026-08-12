# 主菜单（开始界面）—— 极简战争号角 · 第三次设计
#
# 设计理念（stark 极简原则）：
#   - 纯黑背景，不抢主体
#   - 信息层级清晰：标题 > 副标题 > 模式列表 > 开始按钮 > 辅助
#   - 模式列表：竖排细长项，左侧竖条指示选中，悬停背景微亮
#   - 无卡片、无氛围灯、无装饰块，只保留标题下方一根细线
#   - 动效：统一淡入+微上移，按阅读顺序逐个出现
extends Control

signal start_requested(mode: String, difficulty: int, time_setting: Dictionary, options: Dictionary)
signal replay_requested
signal tutorial_requested
signal theme_cycle_requested
signal quit_requested

const AIManager = preload("res://scripts/ai/AIManager.gd")

const MODE_ENTRIES := [
	{"name": "本地双人", "desc": "同一屏幕对弈", "mode": "pvp", "diff": 0},
	{"name": "人机对战", "desc": "选择 AI 难度", "mode": "pve", "diff": -1},
	{"name": "联机对战", "desc": "主机或加入", "mode": "online", "diff": 0},
]

# 思考时间选项（分业余/专业两组，参考传统围棋设定）
# { "label": 显示名, "group": "amateur"|"pro", "main": 秒(-1=无限), "byoyomi": 读秒次数, "byoyomi_duration": 读秒时长 }
const TIME_ENTRIES := [
	# 业余组
	{"label": "无限制", "group": "amateur", "main": -1.0, "byoyomi": 0, "byoyomi_duration": 0.0},
	{"label": "闪电 5分", "group": "amateur", "main": 300.0, "byoyomi": 0, "byoyomi_duration": 0.0},
	{"label": "快棋 15分", "group": "amateur", "main": 900.0, "byoyomi": 3, "byoyomi_duration": 30.0},
	{"label": "标准 30分", "group": "amateur", "main": 1800.0, "byoyomi": 3, "byoyomi_duration": 30.0},
	{"label": "业余 60分", "group": "amateur", "main": 3600.0, "byoyomi": 5, "byoyomi_duration": 30.0},
	# 专业组
	{"label": "快棋赛 1h", "group": "pro", "main": 3600.0, "byoyomi": 5, "byoyomi_duration": 30.0},
	{"label": "普通赛 3h", "group": "pro", "main": 10800.0, "byoyomi": 5, "byoyomi_duration": 60.0},
	{"label": "大赛 5h", "group": "pro", "main": 18000.0, "byoyomi": 5, "byoyomi_duration": 60.0},
	{"label": "头衔战 8h", "group": "pro", "main": 28800.0, "byoyomi": 10, "byoyomi_duration": 60.0},
]

# 贴目步进参数
const KOMI_STEP: float = 0.5      # 每次加减的变化量
const KOMI_MIN: float = 0.0       # 最小贴目
const KOMI_MAX: float = 20.5      # 最大贴目（上限保险）
# 兵力上限选项（默认 112）
const PIECE_ENTRIES := [90, 112, 134, 152]
const DEFAULT_PIECE_IDX: int = 1  # 默认兵力索引（PIECE_ENTRIES[1] = 112）

var _selected_idx: int = 0
var _selected_time_idx: int = 0  # 思考时间选项索引
var _selected_piece_idx: int = 1  # 兵力上限选项索引（默认 112）
var _items: Array = []  # 模式列表项节点
var _time_items: Array = []  # 思考时间列表项节点
var _komi_value: float = Const.KOMI_DEFAULT  # 当前贴目（默认 3.5）
var _komi_label: Label = null  # 贴目显示标签
var _piece_option: OptionButton = null  # 兵力下拉

# 主菜单根容器与二级难度选择视图
var _main_root: Control = null
var _difficulty_view: Control = null

# 动画引用节点
var _title: Label = null
var _subtitle: Label = null
var _divider: Control = null
var _list: VBoxContainer = null
var _start_btn: Button = null
var _bottom_row: HBoxContainer = null

func _ready() -> void:
	set_anchors_preset(PRESET_FULL_RECT)
	_build_ui()
	_play_entrance()

# ===== UI 构建 =====
func _build_ui() -> void:
	# 根容器：垂直居中，紧凑
	var root := VBoxContainer.new()
	_main_root = root
	root.set_anchors_preset(PRESET_FULL_RECT)
	root.alignment = BoxContainer.ALIGNMENT_CENTER
	root.add_theme_constant_override("separation", 0)
	root.offset_top = 24
	root.offset_bottom = -28
	add_child(root)

	_title = Label.new()
	_title.text = "战争号角"
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_size_override("font_size", 64)
	_title.add_theme_color_override("font_color", UITheme.C_GOLD)
	# 文字描边增加层次感（不使用色块）
	_title.add_theme_color_override("font_shadow_color", Color(0.05, 0.03, 0.02, 0.9))
	_title.add_theme_constant_override("shadow_offset_x", 3)
	_title.add_theme_constant_override("shadow_offset_y", 4)
	_title.add_theme_constant_override("shadow_outline_size", 2)
	root.add_child(_title)

	# 标题与副标题间距
	_add_spacer(root, 6)

	_subtitle = Label.new()
	_subtitle.text = "边境线"
	_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_subtitle.add_theme_font_size_override("font_size", 18)
	_subtitle.add_theme_color_override("font_color", UITheme.C_GOLD_DIM)
	root.add_child(_subtitle)

	_add_spacer(root, 8)

	_divider = Control.new()
	_divider.custom_minimum_size = Vector2(280, 2)
	_divider.size_flags_horizontal = SIZE_SHRINK_CENTER
	root.add_child(_divider)

	_add_spacer(root, 24)

	# 模式列表
	_list = VBoxContainer.new()
	_list.alignment = BoxContainer.ALIGNMENT_CENTER
	_list.add_theme_constant_override("separation", 2)
	_list.size_flags_horizontal = SIZE_SHRINK_CENTER
	root.add_child(_list)
	for i in MODE_ENTRIES.size():
		_add_mode_item(_list, i)

	_add_spacer(root, 20)

	# 思考时间设置标签
	var time_title := Label.new()
	time_title.text = "思考时间"
	time_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	time_title.add_theme_font_size_override("font_size", 14)
	time_title.add_theme_color_override("font_color", UITheme.C_GOLD_DIM)
	root.add_child(time_title)

	_add_spacer(root, 6)

	# 思考时间选项（分业余/专业两行横排）
	_add_time_row(root, "业 余", "amateur")
	_add_spacer(root, 4)
	_add_time_row(root, "专 业", "pro")

	_add_spacer(root, 24)

	# 对局设置：贴目（加减步进） + 兵力上限（下拉）
	var settings_row := HBoxContainer.new()
	settings_row.alignment = BoxContainer.ALIGNMENT_CENTER
	settings_row.add_theme_constant_override("separation", 24)
	settings_row.size_flags_horizontal = SIZE_SHRINK_CENTER
	root.add_child(settings_row)

	# 贴目加减步进器：[−] 3.5 目 [+]
	var komi_col := VBoxContainer.new()
	komi_col.add_theme_constant_override("separation", 4)
	komi_col.size_flags_horizontal = SIZE_SHRINK_CENTER
	settings_row.add_child(komi_col)
	var komi_title := Label.new()
	komi_title.text = "贴  目"
	komi_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	komi_title.add_theme_font_size_override("font_size", 12)
	komi_title.add_theme_color_override("font_color", UITheme.C_GOLD_DIM)
	komi_col.add_child(komi_title)
	var komi_row := HBoxContainer.new()
	komi_row.alignment = BoxContainer.ALIGNMENT_CENTER
	komi_row.add_theme_constant_override("separation", 6)
	komi_col.add_child(komi_row)
	var komi_dec := _make_step_btn("−")
	komi_dec.pressed.connect(func(): _on_komi_step(-1))
	komi_row.add_child(komi_dec)
	_komi_label = Label.new()
	_komi_label.text = "%.1f 目" % _komi_value
	_komi_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_komi_label.custom_minimum_size = Vector2(72, 28)
	_komi_label.add_theme_font_size_override("font_size", 15)
	_komi_label.add_theme_color_override("font_color", UITheme.C_GOLD)
	komi_row.add_child(_komi_label)
	var komi_inc := _make_step_btn("+")
	komi_inc.pressed.connect(func(): _on_komi_step(1))
	komi_row.add_child(komi_inc)

	# 兵力上限下拉
	var piece_col := VBoxContainer.new()
	piece_col.add_theme_constant_override("separation", 4)
	piece_col.size_flags_horizontal = SIZE_SHRINK_CENTER
	settings_row.add_child(piece_col)
	var piece_title := Label.new()
	piece_title.text = "兵  力"
	piece_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	piece_title.add_theme_font_size_override("font_size", 12)
	piece_title.add_theme_color_override("font_color", UITheme.C_GOLD_DIM)
	piece_col.add_child(piece_title)
	_piece_option = OptionButton.new()
	_piece_option.custom_minimum_size = Vector2(100, 28)
	_piece_option.add_theme_font_size_override("font_size", 13)
	_piece_option.add_theme_color_override("font_color", UITheme.C_GOLD)
	_piece_option.add_theme_color_override("font_hover_color", UITheme.C_GOLD_BRIGHT)
	for p in PIECE_ENTRIES:
		_piece_option.add_item("%d 子" % p)
	_piece_option.select(_selected_piece_idx)
	piece_col.add_child(_piece_option)

	_add_spacer(root, 24)

	# 开始按钮
	_start_btn = Button.new()
	_start_btn.text = "开 始 对 局"
	_start_btn.custom_minimum_size = Vector2(280, 48)
	_start_btn.size_flags_horizontal = SIZE_SHRINK_CENTER
	_start_btn.add_theme_font_size_override("font_size", 20)
	_start_btn.add_theme_color_override("font_color", UITheme.C_GOLD)
	_start_btn.add_theme_color_override("font_hover_color", UITheme.C_GOLD_BRIGHT)
	_start_btn.add_theme_stylebox_override("normal", _make_btn_style(false))
	_start_btn.add_theme_stylebox_override("hover", _make_btn_style(true))
	_start_btn.add_theme_stylebox_override("pressed", _make_btn_style(true))
	_start_btn.pressed.connect(_on_start)
	_start_btn.mouse_entered.connect(func(): UITheme.animate_button_hover(_start_btn, true))
	_start_btn.mouse_exited.connect(func(): UITheme.animate_button_hover(_start_btn, false))
	root.add_child(_start_btn)

	_add_spacer(root, 16)

	# 底部辅助按钮
	_bottom_row = HBoxContainer.new()
	_bottom_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_bottom_row.add_theme_constant_override("separation", 24)
	root.add_child(_bottom_row)

	var theme_btn := _make_text_button("切换主题", false)
	theme_btn.pressed.connect(func(): theme_cycle_requested.emit())
	_bottom_row.add_child(theme_btn)

	var replay_btn := _make_text_button("棋 谱 回 放", false)
	replay_btn.pressed.connect(func(): replay_requested.emit())
	_bottom_row.add_child(replay_btn)

	var tutorial_btn := _make_text_button("规 则 教 程", false)
	tutorial_btn.pressed.connect(func(): tutorial_requested.emit())
	_bottom_row.add_child(tutorial_btn)

	var quit_btn := _make_text_button("退出", true)
	quit_btn.pressed.connect(func(): quit_requested.emit())
	_bottom_row.add_child(quit_btn)

	# 二级难度选择视图（人机对战：选择 AI 难度）
	_build_difficulty_view()

# ===== 二级难度选择视图（人机对战） =====
func _build_difficulty_view() -> void:
	_difficulty_view = Control.new()
	_difficulty_view.set_anchors_preset(PRESET_FULL_RECT)
	_difficulty_view.visible = false
	add_child(_difficulty_view)

	var root := VBoxContainer.new()
	root.set_anchors_preset(PRESET_FULL_RECT)
	root.alignment = BoxContainer.ALIGNMENT_CENTER
	root.add_theme_constant_override("separation", 12)
	_difficulty_view.add_child(root)

	var title := Label.new()
	title.text = "选择 AI 难度"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", UITheme.C_GOLD)
	root.add_child(title)

	_add_spacer(root, 10)

	# 5 档难度按钮（文档第六章：简单/普通/困难/专家/大师）
	var diffs := [
		AIDifficulty.Difficulty.EASY,
		AIDifficulty.Difficulty.NORMAL,
		AIDifficulty.Difficulty.HARD,
		AIDifficulty.Difficulty.EXPERT,
		AIDifficulty.Difficulty.MASTER,
	]
	for d in diffs:
		var btn := Button.new()
		btn.text = "%s  —  %s" % [AIDifficulty.name_of(d), AIDifficulty.desc_of(d)]
		btn.custom_minimum_size = Vector2(320, 42)
		btn.size_flags_horizontal = SIZE_SHRINK_CENTER
		btn.add_theme_font_size_override("font_size", 16)
		btn.add_theme_color_override("font_color", UITheme.C_GOLD)
		btn.add_theme_color_override("font_hover_color", UITheme.C_GOLD_BRIGHT)
		btn.add_theme_stylebox_override("normal", _make_btn_style(false))
		btn.add_theme_stylebox_override("hover", _make_btn_style(true))
		btn.add_theme_stylebox_override("pressed", _make_btn_style(true))
		btn.pressed.connect(_on_difficulty_chosen.bind(d))
		root.add_child(btn)

	_add_spacer(root, 16)

	var back_btn := Button.new()
	back_btn.text = "返 回"
	back_btn.custom_minimum_size = Vector2(160, 36)
	back_btn.size_flags_horizontal = SIZE_SHRINK_CENTER
	back_btn.flat = true
	back_btn.add_theme_font_size_override("font_size", 14)
	back_btn.add_theme_color_override("font_color", UITheme.C_GOLD_DIM)
	back_btn.add_theme_color_override("font_hover_color", UITheme.C_GOLD_BRIGHT)
	back_btn.pressed.connect(_hide_difficulty_view)
	root.add_child(back_btn)

func _show_difficulty_view() -> void:
	if _main_root != null:
		_main_root.visible = false
	if _difficulty_view != null:
		_difficulty_view.visible = true

func _hide_difficulty_view() -> void:
	if _difficulty_view != null:
		_difficulty_view.visible = false
	if _main_root != null:
		_main_root.visible = true

func _on_difficulty_chosen(difficulty: int) -> void:
	_hide_difficulty_view()
	var entry: Dictionary = MODE_ENTRIES[_selected_idx]
	_emit_start(entry, difficulty)

# 构建一行思考时间选项（带组标签）
func _add_time_row(parent: Container, group_label: String, group_key: String) -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	row.size_flags_horizontal = SIZE_SHRINK_CENTER
	parent.add_child(row)
	# 组标签
	var lbl := Label.new()
	lbl.text = group_label
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", UITheme.C_GOLD_DIM)
	lbl.custom_minimum_size = Vector2(40, 28)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(lbl)
	# 该组所有选项
	for i in TIME_ENTRIES.size():
		if TIME_ENTRIES[i].get("group", "") != group_key:
			continue
		_add_time_item(row, i)

# 添加思考时间选项项
func _add_time_item(parent: Container, idx: int) -> void:
	var entry: Dictionary = TIME_ENTRIES[idx]
	var active: bool = (idx == _selected_time_idx)
	var btn := Button.new()
	btn.text = entry.label
	btn.flat = true
	btn.add_theme_font_size_override("font_size", 13)
	btn.add_theme_color_override("font_color", UITheme.C_GOLD if active else UITheme.C_TEXT_DIM)
	btn.add_theme_color_override("font_hover_color", UITheme.C_GOLD_BRIGHT)
	btn.add_theme_stylebox_override("normal", _make_time_style(active, false))
	btn.add_theme_stylebox_override("hover", _make_time_style(active, true))
	btn.add_theme_stylebox_override("pressed", _make_time_style(active, true))
	btn.pressed.connect(func(): _on_time_selected(idx))
	parent.add_child(btn)
	_time_items.append({"btn": btn, "idx": idx})

func _make_time_style(active: bool, hover: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.corner_detail = 1
	if active:
		sb.bg_color = Color(0.12, 0.09, 0.06, 0.75)
		sb.border_width_left = 1
		sb.border_width_right = 1
		sb.border_width_top = 1
		sb.border_width_bottom = 1
		sb.border_color = UITheme.C_GOLD
	elif hover:
		sb.bg_color = Color(0.10, 0.08, 0.07, 0.55)
	else:
		sb.bg_color = Color(0, 0, 0, 0)
	return sb

func _on_time_selected(idx: int) -> void:
	_selected_time_idx = idx
	for entry in _time_items:
		var active: bool = (entry.idx == _selected_time_idx)
		entry.btn.add_theme_color_override("font_color", UITheme.C_GOLD if active else UITheme.C_TEXT_DIM)
		entry.btn.add_theme_stylebox_override("normal", _make_time_style(active, false))
		entry.btn.add_theme_stylebox_override("hover", _make_time_style(active, true))

# 添加模式列表项
func _add_mode_item(parent: Container, idx: int) -> void:
	var entry: Dictionary = MODE_ENTRIES[idx]
	var active: bool = (idx == _selected_idx)

	var item := PanelContainer.new()
	item.custom_minimum_size = Vector2(360, 44)
	item.size_flags_horizontal = SIZE_SHRINK_CENTER
	item.add_theme_stylebox_override("panel", _make_item_style(active, false))
	item.mouse_entered.connect(func(): item.add_theme_stylebox_override("panel", _make_item_style(idx == _selected_idx, true)))
	item.mouse_exited.connect(func(): item.add_theme_stylebox_override("panel", _make_item_style(idx == _selected_idx, false)))
	item.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			_on_item_selected(idx)
	)
	parent.add_child(item)

	var hbox := HBoxContainer.new()
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.add_theme_constant_override("separation", 12)
	hbox.offset_left = 16
	hbox.offset_right = -16
	item.add_child(hbox)

	# 选中指示器放最左侧
	var indicator := Control.new()
	indicator.custom_minimum_size = Vector2(3, 16)
	indicator.add_theme_stylebox_override("panel", _make_indicator_style(active))
	hbox.add_child(indicator)

	var name_lbl := Label.new()
	name_lbl.text = entry.name
	name_lbl.add_theme_font_size_override("font_size", 16)
	name_lbl.add_theme_color_override("font_color", UITheme.C_GOLD if active else UITheme.C_TEXT)
	name_lbl.size_flags_horizontal = SIZE_SHRINK_CENTER
	hbox.add_child(name_lbl)

	var desc_lbl := Label.new()
	desc_lbl.text = entry.desc
	desc_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	desc_lbl.add_theme_font_size_override("font_size", 12)
	desc_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_DIM)
	desc_lbl.size_flags_horizontal = SIZE_EXPAND_FILL
	hbox.add_child(desc_lbl)

	_items.append({"item": item, "idx": idx, "name_lbl": name_lbl, "indicator": indicator})

func _make_item_style(active: bool, hover: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.corner_detail = 1
	if active:
		# 选中态：左侧区域微亮 + 微金边框
		sb.bg_color = Color(0.12, 0.09, 0.06, 0.75)
		sb.border_width_left = 3
		sb.border_color = UITheme.C_GOLD
	elif hover:
		# 悬停：背景微亮
		sb.bg_color = Color(0.10, 0.08, 0.07, 0.55)
	else:
		sb.bg_color = Color(0, 0, 0, 0)
	return sb

func _make_indicator_style(active: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.corner_detail = 1
	sb.bg_color = UITheme.C_GOLD if active else Color(0.25, 0.22, 0.16, 0.6)
	return sb

func _make_btn_style(hover: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.corner_detail = 1
	sb.border_width_left = 2
	sb.border_width_right = 2
	sb.border_width_top = 2
	sb.border_width_bottom = 2
	sb.border_color = UITheme.C_GOLD_BRIGHT if hover else UITheme.C_GOLD
	sb.bg_color = Color(0.08, 0.06, 0.04, 0.9) if hover else Color(0.04, 0.03, 0.02, 0.9)
	return sb

func _make_text_button(label: String, danger: bool) -> Button:
	var b := Button.new()
	b.text = label
	b.flat = true
	b.add_theme_font_size_override("font_size", 13)
	b.add_theme_color_override("font_color", UITheme.C_GOLD_DIM if not danger else UITheme.C_RED_WAR)
	b.add_theme_color_override("font_hover_color", UITheme.C_GOLD_BRIGHT if not danger else Color(1.0, 0.5, 0.35, 1.0))
	return b

func _on_item_selected(idx: int) -> void:
	_selected_idx = idx
	for entry in _items:
		var active: bool = (entry.idx == _selected_idx)
		entry.item.add_theme_stylebox_override("panel", _make_item_style(active, false))
		entry.name_lbl.add_theme_color_override("font_color", UITheme.C_GOLD if active else UITheme.C_TEXT)
		entry.indicator.add_theme_stylebox_override("panel", _make_indicator_style(active))

func _on_start() -> void:
	var entry: Dictionary = MODE_ENTRIES[_selected_idx]
	if entry.mode == "pve":
		# 人机对战：进入二级页选择 AI 难度
		_show_difficulty_view()
		return
	_emit_start(entry, entry.diff)

func _emit_start(entry: Dictionary, difficulty: int) -> void:
	var time_entry: Dictionary = TIME_ENTRIES[_selected_time_idx]
	var time_setting: Dictionary = {
		"main": time_entry.main,
		"byoyomi": time_entry.byoyomi,
		"byoyomi_duration": time_entry.byoyomi_duration,
	}
	var options: Dictionary = {
		"komi": _komi_value,
		"piece_limit": PIECE_ENTRIES[_piece_option.selected],
	}
	start_requested.emit(entry.mode, difficulty, time_setting, options)

# 贴目加减按钮：dir = -1 减 / +1 加，变化量 0.5
func _on_komi_step(dir: int) -> void:
	_komi_value = clamp(_komi_value + dir * KOMI_STEP, KOMI_MIN, KOMI_MAX)
	if _komi_label != null:
		_komi_label.text = "%.1f 目" % _komi_value

# 创建步进按钮（用于贴目加减）
func _make_step_btn(label: String) -> Button:
	var b := Button.new()
	b.text = label
	b.custom_minimum_size = Vector2(28, 28)
	b.add_theme_font_size_override("font_size", 16)
	b.add_theme_color_override("font_color", UITheme.C_GOLD)
	b.add_theme_color_override("font_hover_color", UITheme.C_GOLD_BRIGHT)
	var sb := StyleBoxFlat.new()
	sb.corner_detail = 1
	sb.bg_color = Color(0.04, 0.03, 0.02, 0.9)
	sb.border_width_left = 1
	sb.border_width_right = 1
	sb.border_width_top = 1
	sb.border_width_bottom = 1
	sb.border_color = UITheme.C_GOLD_DIM
	b.add_theme_stylebox_override("normal", sb)
	var sb_hover := sb.duplicate()
	sb_hover.border_color = UITheme.C_GOLD
	b.add_theme_stylebox_override("hover", sb_hover)
	b.add_theme_stylebox_override("pressed", sb_hover)
	return b

func _add_spacer(parent: Container, h: int) -> void:
	var sp := Control.new()
	sp.custom_minimum_size = Vector2(0, h)
	parent.add_child(sp)

# ===== 入场动画 =====
func _play_entrance() -> void:
	var delay: float = 0.0
	_animate_in(_title, 0.6, 0.0, delay); delay += 0.4
	_animate_in(_subtitle, 0.5, 0.0, delay); delay += 0.3
	_animate_in(_divider, 0.4, 0.0, delay); delay += 0.3
	for entry in _items:
		_animate_in(entry.item, 0.35, 0.0, delay)
		delay += 0.08
	delay += 0.15
	# 思考时间选项逐个淡入
	for entry in _time_items:
		_animate_in(entry.btn, 0.3, 0.0, delay)
		delay += 0.05
	delay += 0.15
	# 对局设置淡入（贴目步进器和兵力下拉）
	if _komi_label != null:
		_animate_in(_komi_label.get_parent(), 0.35, 0.0, delay); delay += 0.1
	if _piece_option != null:
		_animate_in(_piece_option, 0.35, 0.0, delay); delay += 0.1
	delay += 0.1
	_animate_in(_start_btn, 0.45, 0.0, delay); delay += 0.3
	_animate_in(_bottom_row, 0.35, 0.0, delay)

func _animate_in(node: Control, duration: float, y_offset: float, wait: float) -> void:
	node.modulate.a = 0.0
	if y_offset != 0:
		node.position.y += y_offset
	var t := node.create_tween()
	t.set_ease(Tween.EASE_OUT)
	t.set_trans(Tween.TRANS_CUBIC)
	t.tween_interval(wait)
	t.tween_property(node, "modulate:a", 1.0, duration)
	if y_offset != 0:
		t.parallel().tween_property(node, "position:y", node.position.y - y_offset, duration)

# ===== 键盘操作 =====
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_UP:
				_on_item_selected((_selected_idx - 1 + MODE_ENTRIES.size()) % MODE_ENTRIES.size())
				get_viewport().set_input_as_handled()
			KEY_DOWN:
				_on_item_selected((_selected_idx + 1) % MODE_ENTRIES.size())
				get_viewport().set_input_as_handled()
			KEY_ENTER, KEY_KP_ENTER:
				_on_start()
				get_viewport().set_input_as_handled()
			KEY_T:
				theme_cycle_requested.emit()
				get_viewport().set_input_as_handled()

# ===== 绘制 =====
func _draw() -> void:
	var w: float = size.x
	var h: float = size.y
	if w <= 0 or h <= 0:
		return
	# 纯黑背景
	draw_rect(Rect2(0, 0, w, h), Color.BLACK, true)
	# 标题下方一根细线
	if _divider != null:
		var pos: Vector2 = _divider.global_position
		var dw: float = _divider.size.x
		var dy: float = pos.y + _divider.size.y * 0.5
		var c: Color = UITheme.C_GOLD_DIM
		c.a = 0.7
		draw_line(Vector2(pos.x, dy), Vector2(pos.x + dw, dy), c, 1.0)
