# 棋谱播放器：竖向紧凑布局（棋谱库下拉 + 播放控制 + 分数曲线）
#
# 设计：
#   - 分类下拉（独占一行）
#   - 棋谱下拉（独占一行）
#   - 导入按钮 + 进度（同一行）
#   - 分数变化曲线（双线：黑/白）
#   - 控制按钮行：⏮ ◀ ▶ ▷ ⏭
#   - 速度按钮行：0.5x 1x 2x 4x
#   - 放在右上角，竖向紧凑，不遮挡棋盘
extends Control

signal move_requested(ply: int)        # 跳转到指定 ply
signal import_requested                # 请求导入 SGF 文件
signal game_selected(path: String)     # 从下拉菜单选择棋谱
signal closed                          # 关闭面板

const SGFLoader = preload("res://scripts/core/SGFLoader.gd")

var _game_option: OptionButton = null   # 棋谱下拉菜单
var _category_option: OptionButton = null  # 分类下拉菜单
var _info_label: Label = null
var _progress_label: Label = null
var _play_btn: Button = null
var _playing: bool = false
var _speed: float = 1.0                # 每秒走子数
var _timer: float = 0.0
var _current_ply: int = 0
var _total_moves: int = 0
var _info_text: String = ""
# 棋谱库：{category_key -> Array[{path, display}]}
var _library: Dictionary = {}
# 当前分类下下拉菜单项对应的 path 列表（与 OptionButton item 索引对齐）
var _current_paths: Array = []

# 棋谱库分类
const CATEGORIES := [
	{"key": "classic", "name": "经典对局", "dir": "res://sgf/classic/"},
	{"key": "masters", "name": "棋圣名局", "dir": "res://sgf/masters/"},
	{"key": "modern", "name": "当代对局", "dir": "res://sgf/modern/"},
]

# 统一日志输出（仅 print，不写文件，避免卡顿；文件日志由 ReplayScreen 统一管理）
func _log(msg: String) -> void:
	print("[REPLAY][Panel] %s" % msg)

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	set_process(true)
	_log("面板初始化")
	_build_ui()
	# 加载棋谱库（不在此 emit 信号，由父场景在完全初始化后调用 load_initial_game）
	_load_library()

# 由父场景在完全初始化后调用，加载第一个棋谱
func load_initial_game() -> void:
	if _current_paths.size() > 0:
		_log("自动加载第一个棋谱: %s" % _current_paths[0])
		game_selected.emit(_current_paths[0])
	else:
		_log("棋谱库为空，无法自动加载")

func _build_ui() -> void:
	# 外层 Panel（撑满本 Control）
	var panel := Panel.new()
	panel.set_anchors_preset(PRESET_FULL_RECT)
	var sb := StyleBoxFlat.new()
	sb.corner_detail = 1
	sb.bg_color = Color(0.04, 0.03, 0.05, 0.95)
	sb.border_width_left = 2
	sb.border_width_right = 2
	sb.border_width_top = 2
	sb.border_width_bottom = 2
	sb.border_color = UITheme.C_GOLD_DIM
	panel.add_theme_stylebox_override("panel", sb)
	add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(PRESET_FULL_RECT)
	vbox.offset_left = 8
	vbox.offset_right = -8
	vbox.offset_top = 4
	vbox.offset_bottom = -4
	vbox.add_theme_constant_override("separation", 3)
	panel.add_child(vbox)

	# 分类下拉（独占一行）
	_category_option = OptionButton.new()
	_category_option.custom_minimum_size = Vector2(0, 24)
	_category_option.size_flags_horizontal = SIZE_EXPAND_FILL
	_category_option.add_theme_font_size_override("font_size", 12)
	_category_option.add_theme_color_override("font_color", UITheme.C_GOLD)
	for cat in CATEGORIES:
		_category_option.add_item(cat.name)
	_category_option.item_selected.connect(_on_category_selected)
	vbox.add_child(_category_option)

	# 棋谱下拉（独占一行）
	_game_option = OptionButton.new()
	_game_option.custom_minimum_size = Vector2(0, 24)
	_game_option.size_flags_horizontal = SIZE_EXPAND_FILL
	_game_option.add_theme_font_size_override("font_size", 12)
	_game_option.add_theme_color_override("font_color", UITheme.C_GOLD)
	_game_option.item_selected.connect(_on_game_option_selected)
	vbox.add_child(_game_option)

	# 导入按钮 + 进度（同一行）
	var imp_row := HBoxContainer.new()
	imp_row.add_theme_constant_override("separation", 4)
	vbox.add_child(imp_row)

	var import_btn := Button.new()
	import_btn.text = "导入"
	import_btn.custom_minimum_size = Vector2(50, 22)
	import_btn.add_theme_font_size_override("font_size", 12)
	import_btn.add_theme_color_override("font_color", UITheme.C_GOLD)
	import_btn.add_theme_color_override("font_hover_color", UITheme.C_GOLD_BRIGHT)
	import_btn.pressed.connect(func(): import_requested.emit())
	imp_row.add_child(import_btn)

	_progress_label = Label.new()
	_progress_label.text = "— / —"
	_progress_label.add_theme_font_size_override("font_size", 12)
	_progress_label.add_theme_color_override("font_color", UITheme.C_GOLD_DIM)
	_progress_label.size_flags_horizontal = SIZE_EXPAND_FILL
	_progress_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	imp_row.add_child(_progress_label)

	# 信息标签（棋谱信息：黑方 vs 白方 | 结果 | 日期）
	_info_label = Label.new()
	_info_label.text = "未导入棋谱"
	_info_label.add_theme_font_size_override("font_size", 10)
	_info_label.add_theme_color_override("font_color", UITheme.C_TEXT_DIM)
	_info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info_label.size_flags_horizontal = SIZE_EXPAND_FILL
	_info_label.custom_minimum_size = Vector2(0, 28)
	vbox.add_child(_info_label)

	# 控制按钮行：⏮ ◀ ▶ ▷ ⏭
	var ctrl_row := HBoxContainer.new()
	ctrl_row.alignment = BoxContainer.ALIGNMENT_CENTER
	ctrl_row.custom_minimum_size = Vector2(0, 24)
	ctrl_row.add_theme_constant_override("separation", 3)
	vbox.add_child(ctrl_row)

	var first_btn := _make_ctrl_btn("⏮", 34)
	first_btn.pressed.connect(func(): _jump_to(0))
	ctrl_row.add_child(first_btn)

	var prev_btn := _make_ctrl_btn("◀", 34)
	prev_btn.pressed.connect(func(): _step(-1))
	ctrl_row.add_child(prev_btn)

	_play_btn = _make_ctrl_btn("▶", 40)
	_play_btn.pressed.connect(_toggle_play)
	ctrl_row.add_child(_play_btn)

	var next_btn := _make_ctrl_btn("▷", 34)
	next_btn.pressed.connect(func(): _step(1))
	ctrl_row.add_child(next_btn)

	var last_btn := _make_ctrl_btn("⏭", 34)
	last_btn.pressed.connect(func(): _jump_to(_total_moves))
	ctrl_row.add_child(last_btn)

	# 速度按钮行：0.5x 1x 2x 4x
	var speed_row := HBoxContainer.new()
	speed_row.alignment = BoxContainer.ALIGNMENT_CENTER
	speed_row.custom_minimum_size = Vector2(0, 22)
	speed_row.add_theme_constant_override("separation", 3)
	vbox.add_child(speed_row)

	for sp in [0.5, 1.0, 2.0, 4.0]:
		var btn := Button.new()
		btn.text = "%.1fx" % sp
		btn.toggle_mode = true
		btn.custom_minimum_size = Vector2(0, 22)
		btn.size_flags_horizontal = SIZE_EXPAND_FILL
		btn.add_theme_font_size_override("font_size", 11)
		btn.add_theme_color_override("font_color", UITheme.C_TEXT_DIM)
		btn.add_theme_color_override("font_hover_color", UITheme.C_GOLD_BRIGHT)
		if sp == _speed:
			btn.button_pressed = true
			btn.add_theme_color_override("font_color", UITheme.C_GOLD)
		btn.pressed.connect(func(): _on_speed_selected(sp, speed_row))
		speed_row.add_child(btn)

func _make_ctrl_btn(label: String, w: int) -> Button:
	var b := Button.new()
	b.text = label
	b.custom_minimum_size = Vector2(w, 24)
	b.mouse_filter = Control.MOUSE_FILTER_STOP  # 确保接收点击
	b.add_theme_font_size_override("font_size", 13)
	b.add_theme_color_override("font_color", UITheme.C_GOLD)
	b.add_theme_color_override("font_hover_color", UITheme.C_GOLD_BRIGHT)
	return b

func _on_speed_selected(sp: float, row: HBoxContainer) -> void:
	var prev_speed: float = _speed
	_speed = sp
	# 遍历 row 中所有按钮，仅匹配速度按钮（文本以 "x" 结尾）
	for child in row.get_children():
		if child is Button:
			var btn: Button = child
			if btn.text.ends_with("x"):
				var active: bool = (btn.text == "%.1fx" % sp)
				btn.button_pressed = active
				btn.add_theme_color_override("font_color", UITheme.C_GOLD if active else UITheme.C_TEXT_DIM)
	if prev_speed != sp:
		_log("速度切换: %.1fx → %.1fx" % [prev_speed, sp])

# ===== 棋谱库管理 =====
# 加载所有分类的棋谱到 _library
func _load_library() -> void:
	_library.clear()
	for cat in CATEGORIES:
		var files: Array = []
		var dir := DirAccess.open(cat.dir)
		if dir != null:
			dir.list_dir_begin()
			var f: String = dir.get_next()
			while f != "":
				if f.ends_with(".sgf"):
					var path: String = cat.dir + f
					var parsed: Dictionary = SGFLoader.load_from_file(path)
					var display: String = f
					if parsed.ok:
						var pb: String = parsed.get("black_player", "")
						var pw: String = parsed.get("white_player", "")
						if pb != "" or pw != "":
							display = "%s vs %s" % [pb, pw]
					files.append({"path": path, "display": display})
				f = dir.get_next()
			dir.list_dir_end()
		files.sort_custom(func(a, b): return a.display < b.display)
		_library[cat.key] = files
	# 刷新棋谱下拉（默认第一个分类）；初始选择由 _ready 中的 call_deferred 延迟 emit
	_refresh_game_options(0)

# 根据分类索引刷新棋谱下拉菜单
func _refresh_game_options(cat_idx: int) -> void:
	if cat_idx < 0 or cat_idx >= CATEGORIES.size():
		return
	var cat_key: String = CATEGORIES[cat_idx].key
	var files: Array = _library.get(cat_key, [])
	_game_option.clear()
	_current_paths.clear()
	if files.is_empty():
		_game_option.add_item("（无棋谱）")
		_game_option.disabled = true
		return
	_game_option.disabled = false
	for f in files:
		_game_option.add_item(f.display)
		_current_paths.append(f.path)
	_log("分类 '%s' 刷新棋谱下拉: %d 个棋谱" % [CATEGORIES[cat_idx].name, files.size()])

func _on_category_selected(idx: int) -> void:
	_refresh_game_options(idx)

func _on_game_option_selected(idx: int) -> void:
	if idx < 0 or idx >= _current_paths.size():
		return
	var path: String = _current_paths[idx]
	_log("下拉选择棋谱: %s" % path)
	game_selected.emit(path)

# 选中下拉菜单中指定路径的棋谱（加载后高亮当前项）
func select_game_by_path(path: String) -> void:
	for i in _current_paths.size():
		if _current_paths[i] == path:
			_game_option.select(i)
			return

# ===== 数据接口 =====
# 设置棋谱信息
func set_game_info(info: Dictionary) -> void:
	_info_text = ""
	var pb: String = info.get("black_player", "")
	var pw: String = info.get("white_player", "")
	if pb != "" and pw != "":
		_info_text = "%s vs %s" % [pb, pw]
	elif pb != "":
		_info_text = pb
	elif pw != "":
		_info_text = pw
	if info.get("result", "") != "":
		_info_text += "\n结果: %s" % info.result
	if _info_text == "":
		_info_text = "未命名对局"
	_info_label.text = _info_text
	_total_moves = info.get("total_moves", 0)
	_current_ply = 0
	_log("设置棋谱信息: '%s' | 总手数=%d" % [_info_text.replace("\n", " "), _total_moves])
	_update_progress()

# 设置当前 ply（不触发跳转，仅更新显示）
func set_current_ply(ply: int) -> void:
	_current_ply = clamp(ply, 0, _total_moves)
	_update_progress()

# ===== 播放控制 =====
func _toggle_play() -> void:
	_playing = not _playing
	_play_btn.text = "⏸" if _playing else "▶"
	if _playing:
		_log("▶ 播放开始 (速度=%.1fx, 当前 ply=%d/%d)" % [_speed, _current_ply, _total_moves])
		if _current_ply >= _total_moves:
			_log("  已到末尾，从头开始播放")
			_jump_to(0)
	else:
		_log("⏸ 播放暂停 (当前 ply=%d/%d)" % [_current_ply, _total_moves])

func _step(delta: int) -> void:
	_playing = false
	_play_btn.text = "▶"
	var action: String = "上一手" if delta < 0 else "下一手"
	_log("⏹ 手动步进: %s (ply %d → %d)" % [action, _current_ply, _current_ply + delta])
	_jump_to(_current_ply + delta)

func _jump_to(ply: int) -> void:
	var target: int = clamp(ply, 0, _total_moves)
	if target == _current_ply:
		return
	_current_ply = target
	_update_progress()
	move_requested.emit(target)

func _update_progress() -> void:
	if _total_moves == 0:
		_progress_label.text = "— / —"
	else:
		_progress_label.text = "%d / %d" % [_current_ply, _total_moves]

func _process(delta: float) -> void:
	if not _playing:
		return
	_timer += delta
	var interval: float = 1.0 / _speed
	# 每帧最多走一步（避免 _timer 累积过多时批量前进导致卡死）
	# 之前用 while 循环批量前进时，每步 emit 都会触发 _jump_to_replay_ply，
	# 但增量优化条件 ply == _current_ply + 1 在批量前进时不成立，
	# 导致每次都走"任意跳转"路径（重置 session + 重放所有手），O(n²) 复杂度
	if _timer >= interval and _current_ply < _total_moves:
		_timer = fmod(_timer, interval)  # 保留余数，避免累积
		_current_ply += 1
		_update_progress()
		move_requested.emit(_current_ply)
	if _current_ply >= _total_moves and _playing:
		_playing = false
		_play_btn.text = "▶"
		_log("⏹ 自动播放结束 (已到末尾 ply=%d/%d)" % [_current_ply, _total_moves])
