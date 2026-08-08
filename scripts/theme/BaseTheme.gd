# 主题基类（数据驱动）
#
# 设计理念：
#   - 主题是「数据」（颜色、尺寸、样式参数），不是「绘制逻辑」
#   - BoardView 统一负责绘制，从主题读取参数
#   - 新增主题 = 创建一个 BaseTheme 实例并填入不同数据
#   - 不依赖 Godot 节点，纯 RefCounted，便于测试与序列化
class_name BaseTheme
extends RefCounted

var id: String = "default"               # 唯一标识
var display_name: String = "默认"          # 显示名称
var description: String = ""

# 棋盘
var cell_size: int = 46                   # 单格像素（贴边布局后增大以填充中间区域）
var board_margin: int = 32                # 棋盘边距（留给坐标标签）
var board_bg_color: Color = Color(0.10, 0.10, 0.12, 1.0)  # 棋盘底色（深黑）
var board_bg_gradient_top: Color = Color(0.13, 0.10, 0.18, 1.0)  # 顶部渐变（暗紫）
var board_border_color: Color = Color(0.30, 0.25, 0.18, 1.0)  # 棋盘外框

# 网格
var grid_line_color: Color = Color(0.55, 0.45, 0.30, 0.85)
var grid_line_width: float = 1.2
var star_point_color: Color = Color(0.85, 0.75, 0.55, 1.0)
var star_point_radius: float = 3.0

# 领土分区
var border_zone_color: Color = Color(1.0, 0.85, 0.40, 0.18)  # 边境线带高亮
var border_zone_pulse: bool = true                          # 呼吸效果
var black_zone_hint: Color = Color(0.20, 0.30, 0.55, 0.06)  # 黑方领土淡淡提示
var white_zone_hint: Color = Color(0.55, 0.40, 0.20, 0.06)

# 棋子
var black_stone_color: Color = Color(0.05, 0.05, 0.08, 1.0)
var black_stone_rim: Color = Color(0.30, 0.30, 0.35, 1.0)
var black_stone_radius_ratio: float = 0.46  # 占格比例
var white_stone_color: Color = Color(0.95, 0.93, 0.88, 1.0)
var white_stone_rim: Color = Color(0.55, 0.50, 0.42, 1.0)
var white_stone_radius_ratio: float = 0.46
var stone_shadow: bool = true
var stone_shadow_color: Color = Color(0, 0, 0, 0.35)
var stone_shadow_offset: Vector2 = Vector2(2, 3)

# 最后一手棋标记
var last_move_marker_color: Color = Color(1.0, 0.95, 0.40, 0.95)
var last_move_marker_radius_ratio: float = 0.18

# 围空填充
var territory_fill_alpha: float = 0.42  # 用户偏好：透明度 0.42
var black_territory_color: Color = Color(0.30, 0.55, 0.75, 0.42)  # 黑方围空：冷蓝青
var white_territory_color: Color = Color(0.95, 0.75, 0.30, 0.42)  # 白方围空：暖金

# 围困标记
var siege_marker_color: Color = Color(1.0, 0.30, 0.20, 0.95)
var siege_marker_size: float = 6.0

# 特种部队
var special_marker_color: Color = Color(1.0, 0.85, 0.30, 1.0)  # 金色
var special_hidden_alpha: float = 0.45  # 己方半透明

# 字体
var font_color: Color = Color(0.85, 0.80, 0.70, 1.0)
var coord_font_size: int = 11
var score_font_size: int = 16
var score_total_font_size: int = 28

# 行棋方高亮
var active_side_color: Color = Color(1.0, 0.85, 0.40, 1.0)  # 亮金

# ===== 渲染风格提示（BoardView 据此分支渲染）=====
# 渲染风格枚举
enum RenderStyle { SMOOTH, PIXEL, NEON }
var render_style: int = RenderStyle.SMOOTH

# 星位样式：false=圆点（默认），true=锐利十字像素
var star_point_cross: bool = false

# 棋子发光（赛博朋克用）
var stone_glow: bool = false
var stone_glow_color: Color = Color(1, 1, 1, 0.35)
var stone_glow_radius_ratio: float = 1.35  # 发光半径 = 棋子半径 * 此值

# 网格霓虹光晕
var grid_neon: bool = false
var grid_neon_color: Color = Color(0.4, 0.9, 1.0, 0.6)

# 棋子像素颗粒纹理（像素古典用）
var pixel_grain: bool = false
var pixel_grain_color: Color = Color(1, 1, 1, 0.15)

# 落子全息聚焦环（赛博朋克用）
var holographic_ring: bool = false

# 边角印章装饰（像素古典用）
var corner_seal: bool = false
var corner_seal_color: Color = Color(0.6, 0.25, 0.15, 0.7)

# 计算辅助：得到棋子像素半径
func stone_radius() -> float:
	return cell_size * black_stone_radius_ratio

# 棋盘像素大小（不含外框）
func board_pixel_size() -> int:
	return cell_size * (Const.BOARD_SIZE - 1) + board_margin * 2
