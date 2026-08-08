# 行棋历史面板：显示每手棋的记录
#
# 设计：
#   - 紧凑列表，自动滚动到最新
#   - 点击某手可回看（Phase 5 实现回看功能）
extends ScrollContainer

signal move_selected(ply: int)

var _list: VBoxContainer
var _entries: Array = []  # Array[Dictionary] { ply, color, type, placed, captures, ... }

func _ready() -> void:
	custom_minimum_size = Vector2(240, 0)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 1)
	add_child(_list)

func clear() -> void:
	for c in _list.get_children():
		c.queue_free()
	_entries.clear()

func add_move(outcome: Dictionary) -> void:
	_entries.append(outcome)
	var label := Label.new()
	label.text = _format_move(outcome)
	label.add_theme_font_size_override("font", 11)
	_list.add_child(label)
	# 滚动到底部
	await get_tree().process_frame
	ensure_control_visible(label)

func _format_move(outcome: Dictionary) -> String:
	var ply: int = outcome.get("ply", 0)
	var t: String = outcome.get("type", "?")
	var color_str: String = ""
	if outcome.has("placed") and outcome.placed is Vector2i and outcome.placed.x >= 0:
		var p: Vector2i = outcome.placed
		var cols: String = "ABCDEFGHJKLMNOPQRST"
		color_str = "%s%d" % [cols[p.x], p.y + 1]
	var cap: int = 0
	if outcome.has("captures"):
		cap = outcome.captures.size()
	var cap_str: String = " 提%d" % cap if cap > 0 else ""
	var amb_str: String = " 伏击" if outcome.get("ambush", false) else ""
	var pass_str: String = " 虚手" if outcome.get("passed", false) else ""
	var dep_str: String = " 部署" if outcome.get("deployed", false) else ""
	return "%3d. %s%s%s%s%s" % [ply, color_str, cap_str, amb_str, pass_str, dep_str]
