# 房间设置对话框（玩家A = 主机用）
#
# 玩家A点击"建立房间"后弹出此对话框，设置房间参数：
#   - 思考时间（业余/专业两组下拉）
#   - 棋子兵力上限（下拉）
#   - 贴目（加减步进）
#
# 点击"建立房间" → emit room_created(time_setting, piece_limit, komi)
# 点击"取消"     → emit canceled
extends AcceptDialog

signal room_created(time_setting: Dictionary, piece_limit: int, komi: float)
# 注：canceled 信号继承自 AcceptDialog，无需在此重新声明

const StartMenu = preload("res://scripts/ui/StartMenu.gd")
const UITheme = preload("res://scripts/ui/UITheme.gd")

var _time_option: OptionButton
var _piece_option: OptionButton
var _komi_label: Label
var _komi_value: float = Const.KOMI_DEFAULT
var _port_edit: LineEdit

func _ready() -> void:
	title = "建立房间 · 房间设置"
	ok_button_text = "建立房间"
	add_cancel_button("取消")
	_build_ui()
	confirmed.connect(func(): room_created.emit(_collect_time_setting(), _collect_piece_limit(), _komi_value))

func _build_ui() -> void:
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	add_child(vbox)
	# 说明
	var hint := Label.new()
	hint.text = "您将作为黑方（主机）建立房间\n设置完成后点击「建立房间」等待白方加入"
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", UITheme.C_TEXT_DIM)
	vbox.add_child(hint)
	# ===== 房间设定行 =====
	var cfg_row := HBoxContainer.new()
	cfg_row.add_theme_constant_override("separation", 12)
	cfg_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(cfg_row)
	# 思考时间
	var time_col := VBoxContainer.new()
	time_col.add_theme_constant_override("separation", 2)
	cfg_row.add_child(time_col)
	var time_title := Label.new()
	time_title.text = "思考时间"
	time_title.add_theme_font_size_override("font_size", 11)
	time_title.add_theme_color_override("font_color", UITheme.C_GOLD_DIM)
	time_col.add_child(time_title)
	_time_option = OptionButton.new()
	_time_option.custom_minimum_size = Vector2(130, 28)
	_time_option.add_theme_font_size_override("font_size", 12)
	for e in StartMenu.TIME_ENTRIES:
		_time_option.add_item(e.label)
	_time_option.select(0)
	time_col.add_child(_time_option)
	# 兵力
	var piece_col := VBoxContainer.new()
	piece_col.add_theme_constant_override("separation", 2)
	cfg_row.add_child(piece_col)
	var piece_title := Label.new()
	piece_title.text = "兵力"
	piece_title.add_theme_font_size_override("font_size", 11)
	piece_title.add_theme_color_override("font_color", UITheme.C_GOLD_DIM)
	piece_col.add_child(piece_title)
	_piece_option = OptionButton.new()
	_piece_option.custom_minimum_size = Vector2(90, 28)
	_piece_option.add_theme_font_size_override("font_size", 12)
	for p in StartMenu.PIECE_ENTRIES:
		_piece_option.add_item("%d 子" % p)
	_piece_option.select(StartMenu.DEFAULT_PIECE_IDX)
	piece_col.add_child(_piece_option)
	# 贴目
	var komi_col := VBoxContainer.new()
	komi_col.add_theme_constant_override("separation", 2)
	cfg_row.add_child(komi_col)
	var komi_title := Label.new()
	komi_title.text = "贴目"
	komi_title.add_theme_font_size_override("font_size", 11)
	komi_title.add_theme_color_override("font_color", UITheme.C_GOLD_DIM)
	komi_col.add_child(komi_title)
	var komi_row := HBoxContainer.new()
	komi_row.add_theme_constant_override("separation", 4)
	komi_col.add_child(komi_row)
	var komi_dec := Button.new()
	komi_dec.text = "−"
	komi_dec.custom_minimum_size = Vector2(24, 28)
	komi_dec.add_theme_font_size_override("font_size", 14)
	komi_dec.pressed.connect(func(): _on_komi_step(-1))
	komi_row.add_child(komi_dec)
	_komi_label = Label.new()
	_komi_label.text = "%.1f" % _komi_value
	_komi_label.custom_minimum_size = Vector2(48, 28)
	_komi_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_komi_label.add_theme_font_size_override("font_size", 13)
	_komi_label.add_theme_color_override("font_color", UITheme.C_GOLD)
	komi_row.add_child(_komi_label)
	var komi_inc := Button.new()
	komi_inc.text = "+"
	komi_inc.custom_minimum_size = Vector2(24, 28)
	komi_inc.add_theme_font_size_override("font_size", 14)
	komi_inc.pressed.connect(func(): _on_komi_step(1))
	komi_row.add_child(komi_inc)
	# ===== 端口行 =====
	var port_row := HBoxContainer.new()
	port_row.add_theme_constant_override("separation", 6)
	vbox.add_child(port_row)
	var port_label := Label.new()
	port_label.text = "端口:"
	port_label.custom_minimum_size = Vector2(40, 0)
	port_row.add_child(port_label)
	_port_edit = LineEdit.new()
	_port_edit.text = "5005"
	_port_edit.custom_minimum_size = Vector2(120, 0)
	_port_edit.placeholder_text = "5005"
	port_row.add_child(_port_edit)
	min_size = Vector2i(520, 240)

# 贴目步进
func _on_komi_step(dir: int) -> void:
	_komi_value = clamp(_komi_value + dir * StartMenu.KOMI_STEP, StartMenu.KOMI_MIN, StartMenu.KOMI_MAX)
	_komi_label.text = "%.1f" % _komi_value

func get_port() -> int:
	return _port_edit.text.to_int()

func _collect_time_setting() -> Dictionary:
	var entry: Dictionary = StartMenu.TIME_ENTRIES[_time_option.selected]
	return {
		"main": entry.main,
		"byoyomi": entry.byoyomi,
		"byoyomi_duration": entry.byoyomi_duration,
	}

func _collect_piece_limit() -> int:
	return StartMenu.PIECE_ENTRIES[_piece_option.selected]
