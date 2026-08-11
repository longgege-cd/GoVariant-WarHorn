# 得分弹出文字：围空/歼灭/围困时显示 +N 浮动动画
#
# 使用方式：
#   var popup := ScorePopup.new("围空 +4", board_pos, UITheme.C_GOLD)
#   board_view.add_child(popup)
#
# 动画：从棋盘格子上方出现 → 向上漂浮 → 放大闪烁 → 淡出销毁
extends Label

const UITheme = preload("res://scripts/ui/UITheme.gd")

# 动画参数
const RISE_DISTANCE: float = 56.0       # 上浮距离（像素）
const DURATION: float = 1.2             # 总时长（秒）
const INITIAL_OFFSET: float = -18.0     # 初始位置上偏移（相对棋盘格中心）

# 字体大小（按类型区分）
const FONT_SIZE_LARGE: int = 22         # 围空/歼灭（高分动作）
const FONT_SIZE_NORMAL: int = 18        # 围困

var _board_pos: Vector2i = Vector2i(-1, -1)
var _type: String = ""

func _init(text: String, board_pos: Vector2i, popup_type: String) -> void:
	_board_pos = board_pos
	_type = popup_type
	self.text = text
	self.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	self.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# 默认位置会在加入父节点后由 _ready 根据 BoardView 计算
	self.position = Vector2.ZERO

func _ready() -> void:
	# 根据类型设置样式
	var font_size: int = FONT_SIZE_NORMAL
	var font_color: Color = UITheme.C_GOLD
	var outline_color: Color = Color(0.0, 0.0, 0.0, 1.0)
	match _type:
		"territory":
			font_size = FONT_SIZE_LARGE
			font_color = UITheme.C_GOLD_BRIGHT
			outline_color = Color(0.35, 0.22, 0.05, 1.0)
		"annihilate":
			font_size = FONT_SIZE_LARGE
			font_color = UITheme.C_RED_WAR
			outline_color = Color(0.25, 0.05, 0.04, 1.0)
		"siege":
			font_size = FONT_SIZE_NORMAL
			font_color = Color(0.85, 0.45, 0.95, 1.0)  # 魔法紫
			outline_color = Color(0.25, 0.05, 0.30, 1.0)
		"territory_lost":
			# 围空失守：暗金（与围空形成对照）
			font_size = FONT_SIZE_LARGE
			font_color = Color(0.55, 0.42, 0.20, 1.0)
			outline_color = Color(0.18, 0.10, 0.02, 1.0)
		"siege_broken":
			# 围困解除：暗紫（与围困形成对照）
			font_size = FONT_SIZE_NORMAL
			font_color = Color(0.55, 0.35, 0.65, 1.0)
			outline_color = Color(0.18, 0.05, 0.22, 1.0)
	add_theme_font_size_override("font_size", font_size)
	add_theme_color_override("font_color", font_color)
	add_theme_constant_override("outline_size", 4)
	add_theme_color_override("font_outline_color", outline_color)

	# 在父节点 BoardView 中计算屏幕坐标
	var board_view: Control = get_parent() as Control
	var start_pos: Vector2 = Vector2.ZERO
	if board_view != null and board_view.has_method("_cell_to_pixel"):
		var cell_center: Vector2 = board_view.call("_cell_to_pixel", _board_pos.y, _board_pos.x)
		start_pos = cell_center - Vector2(0, RISE_DISTANCE * 0.3 + INITIAL_OFFSET)
		# 用字体测量预估文字尺寸，实现真正居中（Label 尚未布局，size 为 0）
		var font: Font = get_theme_default_font()
		if font == null:
			font = ThemeDB.fallback_font
		var str_size: Vector2 = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
		self.position = start_pos - Vector2(str_size.x * 0.5, str_size.y * 0.5)
	else:
		self.position = start_pos

	# 初始状态：透明、缩小
	modulate.a = 0.0
	scale = Vector2(0.6, 0.6)

	# 创建动画
	var tween := create_tween()
	tween.set_ease(Tween.EASE_OUT)
	tween.set_trans(Tween.TRANS_CUBIC)

	# 第一阶段：快速弹出（0→0.25秒）：淡入 + 放大到 1.3 倍
	tween.tween_property(self, "modulate:a", 1.0, 0.18)
	tween.parallel().tween_property(self, "scale", Vector2(1.3, 1.3), 0.22).set_trans(Tween.TRANS_BACK)
	tween.parallel().tween_property(self, "position:y", position.y - 12.0, 0.22)

	# 第二阶段（0.25→1.2秒）：回缩到 1.0 倍 + 持续上浮 + 淡出
	tween.tween_property(self, "scale", Vector2(1.0, 1.0), 0.25)
	tween.parallel().tween_property(self, "position:y", position.y - RISE_DISTANCE, DURATION - 0.22).set_trans(Tween.TRANS_SINE)
	tween.parallel().tween_property(self, "modulate:a", 0.0, DURATION - 0.35).set_delay(0.35)

	# 动画结束自动销毁
	tween.finished.connect(queue_free)
