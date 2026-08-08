# 赛博朋克/故障艺术主题：半透明深蓝黑底 + 发光霓虹网格 + 全息棋子
#
# 风格特征（契合用户偏好）：
#   - 棋盘底色：半透明深蓝或黑底
#   - 网格线：发光霓虹色
#   - 棋子：纯色发光体，霓虹色系（亮粉红/青色搭配）
#   - 落子位置：全息聚焦环
#   - 提子：故障信号闪烁（由特效系统实现）
#   - 围空填充跟随主题色（黑方冷蓝青、白方暖粉）
class_name CyberTheme
extends BaseTheme

func _init() -> void:
	id = "cyber"
	display_name = "赛博朋克"
	description = "深蓝黑底 + 霓虹网格 + 全息发光棋子 + 故障艺术"

	# 棋盘底色：深蓝黑
	board_bg_color = Color(0.03, 0.04, 0.08, 1.0)
	board_bg_gradient_top = Color(0.06, 0.04, 0.14, 1.0)   # 顶部暗紫蓝
	board_border_color = Color(0.20, 0.60, 0.90, 0.8)      # 青色霓虹边框

	# 网格：霓虹青色
	grid_line_color = Color(0.20, 0.80, 1.0, 0.7)
	grid_line_width = 1.0
	star_point_color = Color(0.40, 0.95, 1.0, 1.0)
	star_point_radius = 3.5

	# 领土分区
	border_zone_color = Color(1.0, 0.20, 0.80, 0.20)       # 亮粉红边境
	border_zone_pulse = true
	black_zone_hint = Color(0.10, 0.40, 0.60, 0.08)
	white_zone_hint = Color(0.60, 0.15, 0.45, 0.08)

	# 棋子：纯色发光体（亮粉红 vs 青色）
	black_stone_color = Color(0.90, 0.15, 0.65, 1.0)       # 亮粉红
	black_stone_rim = Color(1.0, 0.40, 0.85, 1.0)
	black_stone_radius_ratio = 0.46
	white_stone_color = Color(0.30, 0.90, 0.95, 1.0)       # 青色
	white_stone_rim = Color(0.60, 1.0, 1.0, 1.0)
	white_stone_radius_ratio = 0.46
	stone_shadow = true
	stone_shadow_color = Color(0, 0.5, 0.8, 0.4)
	stone_shadow_offset = Vector2(0, 0)  # 发光体阴影居中

	# 最后一手棋
	last_move_marker_color = Color(1.0, 1.0, 1.0, 0.95)
	last_move_marker_radius_ratio = 0.18

	# 围空填充：跟随主题色
	territory_fill_alpha = 0.42
	black_territory_color = Color(0.90, 0.15, 0.65, 0.42)  # 粉红
	white_territory_color = Color(0.30, 0.90, 0.95, 0.42)  # 青色

	# 围困标记
	siege_marker_color = Color(1.0, 0.10, 0.10, 0.95)
	siege_marker_size = 6.0

	# 特种部队
	special_marker_color = Color(1.0, 0.95, 0.20, 1.0)     # 电黄
	special_hidden_alpha = 0.45

	# 字体
	font_color = Color(0.60, 0.95, 1.0, 1.0)  # 青色字
	coord_font_size = 11
	score_font_size = 16
	score_total_font_size = 28

	# 行棋方高亮
	active_side_color = Color(0.40, 0.95, 1.0, 1.0)  # 青色

	# ===== 渲染风格 =====
	render_style = RenderStyle.NEON
	star_point_cross = false
	stone_glow = true                              # 棋子发光
	stone_glow_color = Color(0.40, 0.95, 1.0, 0.4)
	stone_glow_radius_ratio = 1.4
	grid_neon = true                               # 网格霓虹光晕
	grid_neon_color = Color(0.20, 0.80, 1.0, 0.5)
	holographic_ring = true                        # 落子全息环
