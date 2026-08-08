# 像素古典主题：低饱和米色/淡褐色像素点模拟木纹或宣纸纹理
#
# 风格特征（契合用户偏好）：
#   - 棋盘底色：低饱和米色/淡褐色，模拟宣纸/木纹
#   - 网格线：深褐色像素硬边
#   - 星位：锐利十字像素点
#   - 边角：复古篆刻印章像素装饰
#   - 棋子：颗粒感像素圆，黑子加深灰像素点高光，白子暖白到浅黄渐变
#   - 配色协调统一，暖色调
class_name PixelClassicTheme
extends BaseTheme

func _init() -> void:
	id = "pixel_classic"
	display_name = "像素古典"
	description = "低饱和米色宣纸底 + 深褐像素网格 + 十字星位 + 颗粒棋子"

	# 棋盘底色：宣纸米色（低饱和暖色）
	board_bg_color = Color(0.82, 0.74, 0.60, 1.0)
	board_bg_gradient_top = Color(0.88, 0.82, 0.70, 1.0)  # 顶部略亮
	board_border_color = Color(0.45, 0.35, 0.22, 1.0)      # 深褐外框

	# 网格：深褐色
	grid_line_color = Color(0.32, 0.24, 0.16, 0.95)
	grid_line_width = 1.0  # 像素风细硬线
	star_point_color = Color(0.28, 0.20, 0.12, 1.0)
	star_point_radius = 3.0

	# 领土分区提示（极淡）
	border_zone_color = Color(0.55, 0.40, 0.20, 0.14)
	border_zone_pulse = false  # 像素古典不呼吸
	black_zone_hint = Color(0.40, 0.50, 0.55, 0.05)
	white_zone_hint = Color(0.55, 0.45, 0.25, 0.05)

	# 棋子：颗粒感像素圆
	black_stone_color = Color(0.12, 0.10, 0.10, 1.0)
	black_stone_rim = Color(0.30, 0.26, 0.22, 1.0)
	black_stone_radius_ratio = 0.46
	white_stone_color = Color(0.94, 0.90, 0.80, 1.0)       # 暖白
	white_stone_rim = Color(0.70, 0.62, 0.45, 1.0)
	white_stone_radius_ratio = 0.46
	stone_shadow = true
	stone_shadow_color = Color(0, 0, 0, 0.25)
	stone_shadow_offset = Vector2(1, 2)

	# 最后一手棋
	last_move_marker_color = Color(0.70, 0.25, 0.15, 0.95)
	last_move_marker_radius_ratio = 0.20

	# 围空填充：低饱和暖色
	territory_fill_alpha = 0.42
	black_territory_color = Color(0.35, 0.50, 0.60, 0.42)
	white_territory_color = Color(0.80, 0.65, 0.35, 0.42)

	# 围困标记
	siege_marker_color = Color(0.75, 0.20, 0.15, 0.95)
	siege_marker_size = 6.0

	# 特种部队
	special_marker_color = Color(0.65, 0.30, 0.15, 1.0)  # 印章红褐
	special_hidden_alpha = 0.45

	# 字体
	font_color = Color(0.30, 0.22, 0.14, 1.0)  # 深褐字
	coord_font_size = 11
	score_font_size = 16
	score_total_font_size = 28

	# 行棋方高亮
	active_side_color = Color(0.65, 0.30, 0.15, 1.0)  # 印章红

	# ===== 渲染风格 =====
	render_style = RenderStyle.PIXEL
	star_point_cross = true       # 十字像素星位
	pixel_grain = true            # 棋子颗粒纹理
	pixel_grain_color = Color(1, 1, 1, 0.12)
	corner_seal = true            # 边角篆刻印章
	corner_seal_color = Color(0.55, 0.22, 0.15, 0.6)
