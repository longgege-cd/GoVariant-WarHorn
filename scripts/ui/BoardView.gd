# 棋盘视图：渲染棋盘 + 处理点击输入
#
# 设计：
#   - 自定义 _draw() 渲染（性能优、便于主题切换）
#   - 从 ThemeManager 读取当前主题
#   - 主题切换时重绘
#   - 通过 signal 通知父节点落子请求
#   - 支持悬停预览（可选）
extends Control

signal cell_clicked(row: int, col: int)
signal hover_changed(row: int, col: int)

var session: GameSession = null  # 由 GameScreen 注入
var last_move: Vector2i = Vector2i(-1, -1)
var hover_pos: Vector2i = Vector2i(-1, -1)
var show_coords: bool = true
var show_zone_hints: bool = true
var show_territory: bool = true
var show_siege_markers: bool = true
var show_last_move: bool = true
var observer_view: int = -1  # -1=观战(全可见)；否则仅该方视角隐子可见，对手隐子隐藏
# 特效层叠加（用于动画）
var effect_overlays: Array = []  # Array[Dictionary] {type, ...}

var _theme: BaseTheme = null
var _last_redraw_time: int = 0  # 限频重绘（呼吸动画 30fps）
var _error_flash: float = 0.0  # 非法操作红色边框闪烁强度（0~1，逐帧衰减）
var _deploy_mode: bool = false  # 部署特种部队模式（边框呼吸 + 顶部小横条提示）
# 布局阶段（双方在己方领土布子）：领土呼吸辉光 + 未开放的前线封条
var deploy_phase: bool = false
# 开局领土/边境线波浪动画（新对局后持续 1.7 秒）
var _opening_anim_time: float = 0.0  # 剩余秒数（>0 表示动画进行中）
const OPENING_ANIM_DURATION: float = 1.7  # 总时长
# 正式开局圆形扩散波浪：从棋盘中央开始，波纹沿方格向四周扩散，持续 1.4 秒
var _circular_wave_time: float = 0.0  # 剩余秒数（>0 表示动画进行中）
const CIRCULAR_WAVE_DURATION: float = 1.4  # 总时长

func _ready() -> void:
	_theme = ThemeManager.current
	ThemeManager.theme_changed.connect(_on_theme_changed)
	resized.connect(queue_redraw)
	set_process(true)
	# 初始化棋盘最小尺寸（否则 VBoxContainer 会压缩为 0，_draw 画 712px 内容溢出底部）
	if _theme != null:
		custom_minimum_size = Vector2(_theme.board_pixel_size(), _theme.board_pixel_size())

func _on_theme_changed(new_theme: BaseTheme) -> void:
	_theme = new_theme
	custom_minimum_size = Vector2(_theme.board_pixel_size(), _theme.board_pixel_size())
	queue_redraw()

func set_session(s: GameSession, is_deploy_phase: bool = false) -> void:
	session = s
	last_move = Vector2i(-1, -1)
	# 仅在非布局阶段（正式开局/无布局阶段模式）触发领土/边境线波浪动画；
	# 布局阶段有自己的氛围（领土呼吸辉光 + 前线封条），不播放正式开局波浪避免覆盖整个棋盘领土
	if not is_deploy_phase:
		_opening_anim_time = OPENING_ANIM_DURATION
	queue_redraw()

# 设置布局阶段状态（开启后绘制布局氛围：领土呼吸辉光 + 前线封条）
func set_deploy_phase(m: bool) -> void:
	deploy_phase = m
	queue_redraw()

# 正式开局时重放领土/边境线波浪动画（过渡到正式对局视觉）
func replay_opening_anim() -> void:
	_opening_anim_time = OPENING_ANIM_DURATION
	queue_redraw()

# 正式开局圆形扩散波浪：从棋盘中央开始，波纹沿方格向四周扩散
func play_opening_circular_wave() -> void:
	_circular_wave_time = CIRCULAR_WAVE_DURATION
	queue_redraw()

# 接收行棋结果并更新视图
func on_move_committed(outcome: Dictionary) -> void:
	if outcome.has("placed") and outcome.placed is Vector2i and outcome.placed.x >= 0:
		last_move = outcome.placed
	else:
		last_move = Vector2i(-1, -1)
	queue_redraw()

# 检查某位置是否是当前观察视角下不可见的隐子（对方未现形特种部队）
# 用于避免 last_move 标记/落子特效等泄露特种部队位置
func _is_hidden_from_observer(pos: Vector2i) -> bool:
	if observer_view == -1:
		return false  # 观战视角，全可见
	if session == null:
		return false
	var sp: Dictionary = session.special.get_special_at(pos)
	if sp.is_empty():
		return false  # 非特种部队
	if not sp.get("hidden", false):
		return false  # 已现形
	return sp.color != observer_view  # 对方未现形隐子 → 不可见

# 添加特效叠加层（带过期时间）
func add_effect_overlay(overlay: Dictionary) -> void:
	overlay["start_time"] = Time.get_ticks_msec()
	effect_overlays.append(overlay)
	queue_redraw()

# 生成得分浮动文字（围空/歼灭/围困）
func spawn_score_popup(text: String, board_pos: Vector2i, popup_type: String) -> void:
	var popup := preload("res://scripts/effects/ScorePopup.gd").new(text, board_pos, popup_type)
	add_child(popup)

# 在 _process 中清理过期叠加层
func _cleanup_overlays() -> void:
	var now: int = Time.get_ticks_msec()
	var kept: Array = []
	for ov in effect_overlays:
		var elapsed: float = (now - ov.start_time) / 1000.0
		var duration: float = ov.get("duration", 0.5)
		if elapsed < duration:
			kept.append(ov)
	if kept.size() != effect_overlays.size():
		effect_overlays = kept
		queue_redraw()

# ===== 渲染 =====
func _draw() -> void:
	if not _theme:
		return
	if not session:
		return
	var size: int = _theme.board_pixel_size()
	# 1. 背景
	_draw_board_bg(size)
	# 2. 领土分区提示
	if show_zone_hints:
		_draw_zone_hints(size)
	# 3. 边境线高亮
	_draw_border_zone_highlight(size)
	# 3.5 布局阶段氛围（领土呼吸辉光 + 未开放的前线封条）
	if deploy_phase:
		_draw_deploy_ambience(size)
	# 4. 网格 + 星位
	_draw_grid(size)
	# 5. 坐标标签
	if show_coords:
		_draw_coordinates(size)
	# 6. 边角印章装饰（像素古典）
	if _theme.corner_seal:
		_draw_corner_seals(size)
	# 7. 围空填充
	if show_territory:
		_draw_territory_fills()
	# 8. 棋子
	_draw_stones()
	# 9. 围困标记
	if show_siege_markers:
		_draw_siege_markers()
	# 10. 最后一手棋行列线高亮 + 标记
	if show_last_move:
		_draw_last_move_lines()
		_draw_last_move_marker()
	# 11. 悬停预览
	_draw_hover_preview()
	# 12. 特效叠加
	_draw_effect_overlays()
	# 12.5 正式开局圆形扩散波浪（棋盘方格波纹，绘制在棋子上层）
	if _circular_wave_time > 0:
		_draw_circular_wave()
	# 13. 非法操作红色边框闪烁
	if _error_flash > 0.01:
		var c := Color(0.95, 0.20, 0.15, _error_flash * 0.85)
		draw_rect(Rect2(0, 0, size, size), c, false, 4.0)
		# 内层柔光
		var c2 := Color(0.95, 0.20, 0.15, _error_flash * 0.25)
		draw_rect(Rect2(2, 2, size - 4, size - 4), c2, false, 2.0)
	# 14. 部署特种部队模式指示（边框呼吸变色 + 顶部小横条）
	if _deploy_mode:
		_draw_deploy_indicator(size)

func _draw_board_bg(total_size: int) -> void:
	var rect: Rect2 = Rect2(0, 0, total_size, total_size)
	# 渐变背景（顶部暗紫→底部深黑）
	var top: Color = _theme.board_bg_gradient_top
	var bot: Color = _theme.board_bg_color
	# 用分段绘制模拟垂直渐变
	var steps: int = 32
	var step_h: float = float(total_size) / steps
	for i in steps:
		var t: float = float(i) / (steps - 1)
		var c: Color = top.lerp(bot, t)
		draw_rect(Rect2(0, i * step_h, total_size, step_h + 1), c, true)
	# 外框
	draw_rect(rect, _theme.board_border_color, false, 2.0)

# 边角篆刻印章装饰（像素古典）
func _draw_corner_seals(total_size: int) -> void:
	var seal_color: Color = _theme.corner_seal_color
	var sz: float = 8.0  # 印章像素块大小
	var off: float = 6.0  # 距离边角的偏移
	# 四角各画一个 2x2 像素方块印章
	var corners: Array = [
		Vector2(off, off),                              # 左上
		Vector2(total_size - off - sz, off),            # 右上
		Vector2(off, total_size - off - sz),            # 左下
		Vector2(total_size - off - sz, total_size - off - sz),  # 右下
	]
	for cp in corners:
		# 外框
		draw_rect(Rect2(cp.x, cp.y, sz, sz), seal_color, false, 1.0)
		# 内部像素点
		draw_rect(Rect2(cp.x + 2, cp.y + 2, sz - 4, sz - 4), Color(seal_color.r, seal_color.g, seal_color.b, seal_color.a * 0.6), true)

func _draw_zone_hints(total_size: int) -> void:
	# 黑境(行0-8) 淡蓝提示；白境(行10-18) 淡金提示
	# 方格归属：方格 gr=k 对应行k-1 到行k 之间；黑境方格 gr=0..8（行0-9之间），
	# 白境方格 gr=9..17（行9-18之间）。两块领土紧邻行9线（边境线），不留空白带
	var margin: int = _theme.board_margin
	var cs: int = _theme.cell_size
	var top_h: int = cs * 9  # 黑境方格带 y=[margin, margin+cs*9]
	var bot_y: int = margin + cs * 9  # 白境从行9线起，紧接黑境
	var bot_h: int = cs * 9  # 白境方格带 y=[margin+cs*9, margin+cs*18]
	# 开局方格波浪动画：每个方格按到边境线距离呈现波纹起伏
	if _opening_anim_time > 0:
		var progress: float = 1.0 - _opening_anim_time / OPENING_ANIM_DURATION  # 0→1
		var intensity: float = sin(progress * PI)  # 整体强度 0→1→0
		var time_phase: float = Time.get_ticks_msec() / 280.0  # 波浪传播速度
		var base_black: Color = _theme.black_zone_hint
		var base_white: Color = _theme.white_zone_hint
		# 底色
		draw_rect(Rect2(margin, margin, cs * 18, top_h), base_black, true)
		draw_rect(Rect2(margin, bot_y, cs * 18, bot_h), base_white, true)
		# 遍历每个方格（18×18）绘制波浪高亮
		for gr in 18:  # 方格行 0-17
			var row_center: float = gr + 0.5
			# 方格到边境线（行9）的距离
			var dist: float
			var is_black: bool
			if row_center < 9.0:
				dist = 9.0 - row_center
				is_black = true
			else:
				dist = row_center - 9.0
				is_black = false
			# 垂直波浪相位（从边境线向外扩散，距离越远相位越滞后）
			var v_phase: float = -dist * 0.9 + time_phase
			var v_wave: float = max(0.0, sin(v_phase))
			var y: float = margin + cs * gr
			for gc in 18:  # 方格列 0-17
				# 水平波浪（轻微，增加立体感）
				var col_center: float = gc + 0.5
				var h_phase: float = (col_center - 9.0) * 0.4 + time_phase * 0.6
				var h_wave: float = max(0.0, sin(h_phase)) * 0.35
				var total_wave: float = clamp(v_wave + h_wave, 0.0, 1.0) * intensity
				if total_wave < 0.05:
					continue
				var x: float = margin + cs * gc
				# 高亮色：黑境偏冷蓝，白境偏暖金
				var wave_color: Color
				if is_black:
					wave_color = Color(0.35, 0.55, 0.85, 0.55 * total_wave)
				else:
					wave_color = Color(0.95, 0.78, 0.32, 0.55 * total_wave)
				draw_rect(Rect2(x, y, cs, cs), wave_color, true)
	else:
		# 普通显示
		draw_rect(Rect2(margin, margin, cs * 18, top_h), _theme.black_zone_hint, true)
		draw_rect(Rect2(margin, bot_y, cs * 18, bot_h), _theme.white_zone_hint, true)

func _draw_border_zone_highlight(total_size: int) -> void:
	# 边境线（第10行=行号9）的横带高亮
	var margin: int = _theme.board_margin
	var cs: int = _theme.cell_size
	var y: float = margin + cs * 9 - cs * 0.5
	var color: Color = _theme.border_zone_color
	if _opening_anim_time > 0:
		# 开局期间多层辉光脉冲
		var progress: float = 1.0 - _opening_anim_time / OPENING_ANIM_DURATION
		var intensity: float = sin(progress * PI)  # 0→1→0
		# 外层柔光（宽）
		var glow_outer: Color = Color(color.r, color.g, color.b, 0.20 * intensity)
		draw_rect(Rect2(margin, y - cs * 0.5, cs * 18, cs * 2.0), glow_outer, true)
		# 内层亮光（窄）
		var glow_inner: Color = Color(color.r, color.g, color.b, 0.40 * intensity)
		draw_rect(Rect2(margin, y - cs * 0.2, cs * 18, cs * 1.4), glow_inner, true)
		# 主线
		color.a = 0.30 + 0.50 * intensity
	elif _theme.border_zone_pulse:
		# 呼吸效果（基于时间）
		var t: float = fmod(Time.get_ticks_msec() / 1000.0, 2.0) / 2.0
		var pulse: float = 0.5 + 0.5 * sin(t * TAU)
		color.a = 0.10 + 0.10 * pulse
	else:
		pass  # 使用默认 color.a
	draw_rect(Rect2(margin, y, cs * 18, cs), color, true)

# 布局阶段氛围：己方领土呼吸辉光 + 未开放的前线封条（暗色横带 + 金色虚线）
func _draw_deploy_ambience(total_size: int) -> void:
	if _theme == null:
		return
	var margin: int = _theme.board_margin
	var cs: int = _theme.cell_size
	# 呼吸节奏（1.6s 周期，领土辉光脉动）
	var t: float = fmod(Time.get_ticks_msec() / 1000.0, 1.6) / 1.6
	var pulse: float = 0.5 + 0.5 * sin(t * TAU)
	# 1. 领土呼吸辉光：黑境冷蓝 / 白境暖金（两块领土紧邻行9线，不留空白带）
	var top_h: int = cs * 9  # 黑境方格带 y=[margin, margin+cs*9]
	var bot_y: int = margin + cs * 9  # 白境从行9线起，紧接黑境
	var bot_h: int = cs * 9  # 白境方格带 y=[margin+cs*9, margin+cs*18]
	var black_glow := Color(0.35, 0.55, 0.85, 0.10 + 0.08 * pulse)
	draw_rect(Rect2(margin, margin, cs * 18, top_h), black_glow, true)
	var white_glow := Color(0.95, 0.78, 0.32, 0.10 + 0.08 * pulse)
	draw_rect(Rect2(margin, bot_y, cs * 18, bot_h), white_glow, true)
	# 2. 未开放的前线（边境线行9）：暗色封条 + 中央金色虚线（正式开局时消散）
	var band_y: float = margin + cs * 9 - cs * 0.5
	draw_rect(Rect2(margin, band_y, cs * 18, cs), Color(0.05, 0.03, 0.09, 0.55), true)
	var y: float = margin + cs * 9
	var i: float = margin
	var seg_len: float = cs * 0.5
	var gap: float = cs * 0.35
	var dash_c := Color(1.0, 0.85, 0.4, 0.50 + 0.30 * pulse)
	while i < margin + cs * 18:
		draw_line(Vector2(i, y), Vector2(min(i + seg_len, margin + cs * 18), y), dash_c, 2.0)
		i += seg_len + gap

func _draw_grid(_total_size: int) -> void:
	var margin: int = _theme.board_margin
	var cs: int = _theme.cell_size
	var n: int = Const.BOARD_SIZE
	var line_color: Color = _theme.grid_line_color
	var lw: float = _theme.grid_line_width
	# 霓虹光晕：先画一层粗半透明线模拟发光
	if _theme.grid_neon:
		var glow: Color = _theme.grid_neon_color
		glow.a = 0.18
		for i in n:
			var y: float = margin + cs * i
			draw_line(Vector2(margin, y), Vector2(margin + cs * (n - 1), y), glow, lw + 3.0)
		for i in n:
			var x: float = margin + cs * i
			draw_line(Vector2(x, margin), Vector2(x, margin + cs * (n - 1)), glow, lw + 3.0)
	# 横线
	for i in n:
		var y: float = margin + cs * i
		draw_line(Vector2(margin, y), Vector2(margin + cs * (n - 1), y), line_color, lw)
	# 竖线
	for i in n:
		var x: float = margin + cs * i
		draw_line(Vector2(x, margin), Vector2(x, margin + cs * (n - 1)), line_color, lw)
	# 星位（19路标准：4-4, 4-10, 4-16, 10-4, 10-10, 10-16, 16-4, 16-10, 16-16，0基）
	var stars: Array = [[3, 3], [3, 9], [3, 15], [9, 3], [9, 9], [9, 15], [15, 3], [15, 9], [15, 15]]
	for s in stars:
		var pos: Vector2 = _cell_to_pixel(s[0], s[1])
		if _theme.star_point_cross:
			# 锐利十字像素
			var r: float = _theme.star_point_radius
			draw_line(pos + Vector2(-r, 0), pos + Vector2(r, 0), _theme.star_point_color, 2.0)
			draw_line(pos + Vector2(0, -r), pos + Vector2(0, r), _theme.star_point_color, 2.0)
		else:
			draw_circle(pos, _theme.star_point_radius, _theme.star_point_color)

func _draw_coordinates(_total_size: int) -> void:
	var margin: int = _theme.board_margin
	var cs: int = _theme.cell_size
	var n: int = Const.BOARD_SIZE
	var font: Font = get_theme_default_font()
	var color: Color = _theme.font_color
	var fs: int = _theme.coord_font_size
	# 列标签 A-T（跳过 I）
	var cols: String = "ABCDEFGHJKLMNOPQRST"
	for i in n:
		var x: float = margin + cs * i
		var label: String = cols[i]
		_draw_centered_text(font, Vector2(x, margin * 0.45), label, fs, color)
		_draw_centered_text(font, Vector2(x, margin + cs * (n - 1) + margin * 0.55), label, fs, color)
	# 行标签 1-19（从上往下，1=顶部row0）
	for i in n:
		var y: float = margin + cs * i
		var label: String = str(i + 1)
		_draw_centered_text(font, Vector2(margin * 0.45, y), label, fs, color)
		_draw_centered_text(font, Vector2(margin + cs * (n - 1) + margin * 0.55, y), label, fs, color)

func _draw_centered_text(font: Font, pos: Vector2, text: String, fs: int, color: Color) -> void:
	var size: Vector2 = font.get_string_size(text, HORIZONTAL_ALIGNMENT_CENTER, -1, fs)
	font.draw_string(get_canvas_item(), pos - size * 0.5, text, HORIZONTAL_ALIGNMENT_CENTER, -1, fs, color)

# 围空填充
func _draw_territory_fills() -> void:
	var encs: Array = session.cached_enclosures()
	# 无效包围圈（由围困棋子形成，规则3.4/4.2）不计围空分 → 不填充
	var sieged_set: Dictionary = _collect_sieged_set()
	for e in encs:
		if ScoreCalculator.is_enclosure_formed_by_sieged(session.board, e, sieged_set):
			continue
		var color: int = e.color
		var fill: Color = _theme.black_territory_color if color == Const.BLACK else _theme.white_territory_color
		fill.a = _theme.territory_fill_alpha
		for p in e.points:
			var pos: Vector2 = _cell_to_pixel(p.y, p.x)
			# 填充一格大小
			var s: float = _theme.cell_size * 0.5
			draw_rect(Rect2(pos.x - s, pos.y - s, s * 2, s * 2), fill, true)

# 当前被围困棋子索引集合 {idx -> true}
func _collect_sieged_set() -> Dictionary:
	var out: Dictionary = {}
	if session == null:
		return out
	for g in session.cached_sieged_groups():
		for st in g.stones:
			out[st.y * Const.BOARD_SIZE + st.x] = true
	return out

# 棋子
func _draw_stones() -> void:
	var board: BoardModel = session.board
	var n: int = Const.BOARD_SIZE
	for r in n:
		for c in n:
			var v: int = board.get_at(r, c)
			if v == Const.EMPTY:
				continue
			# 隐子对对手不可见（规则：隐子对对手不可见）
			# observer_view=-1=观战全可见；否则仅 observer_view 方可看见己方隐子
			var piece_pos := Vector2i(c, r)
			var sp: Dictionary = session.special.get_special_at(piece_pos)
			if not sp.is_empty() and sp.get("hidden", false):
				# 是隐子且未现形
				if observer_view != -1 and sp.color != observer_view:
					# 对该视角不可见 → 跳过绘制（视为空点）
					continue
			var pos: Vector2 = _cell_to_pixel(r, c)
			var radius: float = _theme.stone_radius()
			# 发光（赛博朋克）
			if _theme.stone_glow:
				var glow: Color = _theme.stone_glow_color
				if v == Const.BLACK:
					glow = Color(_theme.black_stone_color.r, _theme.black_stone_color.g, _theme.black_stone_color.b, 0.35)
				else:
					glow = Color(_theme.white_stone_color.r, _theme.white_stone_color.g, _theme.white_stone_color.b, 0.35)
				draw_circle(pos, radius * _theme.stone_glow_radius_ratio, glow)
			# 阴影
			if _theme.stone_shadow:
				draw_circle(pos + _theme.stone_shadow_offset, radius, _theme.stone_shadow_color)
			# 主体
			var body: Color = _theme.black_stone_color if v == Const.BLACK else _theme.white_stone_color
			draw_circle(pos, radius, body)
			# 像素颗粒纹理（像素古典）
			if _theme.pixel_grain:
				_draw_pixel_grain(pos, radius, v)
			# 描边
			var rim: Color = _theme.black_stone_rim if v == Const.BLACK else _theme.white_stone_rim
			draw_arc(pos, radius, 0, TAU, 32, rim, 1.5)
			# 特种部队标记
			if session.special.is_special_at(Vector2i(c, r)):
				_draw_special_marker(pos, radius, v)

# 像素颗粒纹理：在棋子上画小方块模拟颗粒感
func _draw_pixel_grain(pos: Vector2, radius: float, color: int) -> void:
	var grain: Color = _theme.pixel_grain_color
	# 黑子：加深灰像素点高光；白子：暖白到浅黄渐变色块
	if color == Const.BLACK:
		grain = Color(0.5, 0.5, 0.55, 0.25)  # 深灰高光
	else:
		grain = Color(1.0, 0.92, 0.70, 0.20)  # 浅黄渐变
	var px: float = 2.0  # 像素块大小
	# 在棋子上半区域撒几个像素点（模拟高光）
	var offsets: Array = [Vector2(-3, -4), Vector2(2, -3), Vector2(-1, -5), Vector2(4, -2), Vector2(-4, 1)]
	for off in offsets:
		var p: Vector2 = pos + off
		if p.distance_to(pos) < radius * 0.8:
			draw_rect(Rect2(p.x - px * 0.5, p.y - px * 0.5, px, px), grain, true)

func _draw_special_marker(pos: Vector2, radius: float, color: int) -> void:
	# 简易：金色五角星（用十字代替，避免复杂路径）
	var star_color: Color = _theme.special_marker_color
	var s: float = radius * 0.4
	draw_line(pos + Vector2(-s, 0), pos + Vector2(s, 0), star_color, 2.0)
	draw_line(pos + Vector2(0, -s), pos + Vector2(0, s), star_color, 2.0)
	draw_circle(pos, s * 0.4, star_color)

func _draw_siege_markers() -> void:
	# 规则6.7：处于围困状态的棋子始终显示围困标记
	# 标记：棋子中心的红色 ×
	# 隐子位置保密：对方视角下不画围困标记（避免泄露特种部队位置）
	for g in session.cached_sieged_groups():
		for s in g.stones:
			var s_pos := Vector2i(s.x, s.y)
			if _is_hidden_from_observer(s_pos):
				continue
			var pos: Vector2 = _cell_to_pixel(s.y, s.x)
			_draw_siege_cross_icon(pos, _theme.stone_radius())

# 围困标记：棋子中心的红色 ×
func _draw_siege_cross_icon(center: Vector2, radius: float) -> void:
	var cross_color: Color = Color(1.0, 0.15, 0.15, 0.95)  # 红色
	var arm: float = radius * 0.225  # × 半臂长（缩小一半）
	var lw: float = max(1.5, radius * 0.09)  # 线宽随棋子尺寸缩放
	# 两条对角线交叉
	draw_line(center - Vector2(arm, arm), center + Vector2(arm, arm), cross_color, lw)
	draw_line(center - Vector2(arm, -arm), center + Vector2(arm, -arm), cross_color, lw)

# 最后一手棋行列线高亮
func _draw_last_move_lines() -> void:
	if last_move.x < 0:
		return
	# 隐子位置保密：对方视角下不画 last_move 标记（避免泄露特种部队位置）
	if _is_hidden_from_observer(last_move):
		return
	var margin: int = _theme.board_margin
	var cs: int = _theme.cell_size
	var n: int = Const.BOARD_SIZE
	var line_color: Color = _theme.last_move_marker_color
	line_color.a = 0.25
	var lw: float = _theme.grid_line_width + 1.0
	# 横线（行）
	var y: float = margin + cs * last_move.y
	draw_line(Vector2(margin, y), Vector2(margin + cs * (n - 1), y), line_color, lw)
	# 竖线（列）
	var x: float = margin + cs * last_move.x
	draw_line(Vector2(x, margin), Vector2(x, margin + cs * (n - 1)), line_color, lw)

func _draw_last_move_marker() -> void:
	if last_move.x < 0:
		return
	# 隐子位置保密：对方视角下不画 last_move 标记（避免泄露特种部队位置）
	if _is_hidden_from_observer(last_move):
		return
	var pos: Vector2 = _cell_to_pixel(last_move.y, last_move.x)
	var v: int = session.board.get_at(last_move.y, last_move.x)
	if v == Const.EMPTY:
		return
	# 全息聚焦环（赛博朋克）：棋子外圈呼吸光环
	if _theme.holographic_ring:
		var t: float = fmod(Time.get_ticks_msec() / 800.0, 1.0)
		var pulse: float = 0.5 + 0.5 * sin(t * TAU)
		var ring_color: Color = _theme.last_move_marker_color
		ring_color.a = 0.4 + 0.4 * pulse
		var ring_r: float = _theme.stone_radius() * (1.2 + pulse * 0.15)
		draw_arc(pos, ring_r, 0, TAU, 32, ring_color, 2.0)
	# 最后一手棋标记：直接显示手数数字（取代小圆点，信息更丰富）
	if session != null and session.ply > 0:
		var num_str: String = str(session.ply)
		var font: Font = get_theme_default_font()
		# 字号与棋子半径成比例
		var num_fs: int = max(11, int(_theme.stone_radius() * 0.6))
		# 反色：黑棋上白字，白棋上黑字
		var num_color: Color = Color(1, 1, 1, 0.95) if v == Const.BLACK else Color(0, 0, 0, 0.95)
		var num_size: Vector2 = font.get_string_size(num_str, HORIZONTAL_ALIGNMENT_CENTER, -1, num_fs)
		# 垂直居中于棋子中心（draw_string 基线在底部，需上移约字号的 0.35）
		font.draw_string(get_canvas_item(), pos - num_size * 0.5 + Vector2(0, num_fs * 0.35), num_str, HORIZONTAL_ALIGNMENT_CENTER, -1, num_fs, num_color)

func _draw_hover_preview() -> void:
	if hover_pos.x < 0:
		return
	if not session or session.game_over:
		return
	if session.board.get_at(hover_pos.y, hover_pos.x) != Const.EMPTY:
		return
	var pos: Vector2 = _cell_to_pixel(hover_pos.y, hover_pos.x)
	var radius: float = _theme.stone_radius()
	var body: Color = _theme.black_stone_color if session.to_move == Const.BLACK else _theme.white_stone_color
	body.a = 0.45
	draw_circle(pos, radius, body)

func _draw_effect_overlays() -> void:
	var now: int = Time.get_ticks_msec()
	for ov in effect_overlays:
		var elapsed: float = (now - ov.start_time) / 1000.0
		var duration: float = ov.get("duration", 0.5)
		var t: float = clamp(elapsed / duration, 0.0, 1.0)
		var type: String = ov.get("type", "")
		match type:
			"capture":
				_draw_capture_burst(ov, t)
			"capture_wave":
				_draw_capture_wave(ov, t)
			"bounce":
				_draw_bounce_flash(ov, t)
			"move":
				_draw_move_pulse(ov, t)
			"deploy_place":
				_draw_deploy_place_pulse(ov, t)
			"special_deploy":
				_draw_deploy_burst(ov, t)
			"reveal":
				_draw_reveal_flash(ov, t)
			"territory_formed":
				_draw_territory_formed(ov, t)
			"territory_lost":
				_draw_territory_lost(ov, t)
			"siege":
				_draw_siege_effect(ov, t)
			"siege_broken":
				_draw_siege_broken(ov, t)
			"game_end":
				_draw_game_end_effect(ov, t)

# 提子多层爆裂：3 层扩散环 + 中心闪光 + 碎片粒子
func _draw_capture_burst(ov: Dictionary, t: float) -> void:
	var positions: Array = ov.get("positions", [])
	var alpha: float = 1.0 - t
	for p in positions:
		var pos: Vector2 = _cell_to_pixel(p.y, p.x)
		var base_r: float = _theme.stone_radius()
		# 第 1 层：快速扩散环（橙色）
		var r1: float = base_r * (1.0 + t * 1.8)
		draw_arc(pos, r1, 0, TAU, 32, Color(1.0, 0.6, 0.2, alpha * 0.9), 2.5)
		# 第 2 层：中速扩散环（黄色，延迟 0.15）
		var t2: float = clamp((t - 0.15) / 0.85, 0.0, 1.0)
		if t2 > 0:
			var r2: float = base_r * (1.0 + t2 * 1.3)
			draw_arc(pos, r2, 0, TAU, 32, Color(1.0, 0.85, 0.3, (1.0 - t2) * 0.7), 2.0)
		# 第 3 层：慢速扩散环（白色，延迟 0.3）
		var t3: float = clamp((t - 0.3) / 0.7, 0.0, 1.0)
		if t3 > 0:
			var r3: float = base_r * (0.8 + t3 * 2.2)
			draw_arc(pos, r3, 0, TAU, 32, Color(1.0, 1.0, 1.0, (1.0 - t3) * 0.5), 1.5)
		# 中心闪光（前 30% 时间）
		if t < 0.3:
			var flash_alpha: float = (1.0 - t / 0.3) * 0.8
			draw_circle(pos, base_r * 0.6, Color(1.0, 0.9, 0.5, flash_alpha))
		# 碎片粒子：8 个方向飞散的小方块（像素风）
		if t < 0.8:
			var frag_alpha: float = (1.0 - t / 0.8) * 0.8
			var frag_dist: float = base_r * (1.0 + t * 3.5)
			for i in 8:
				var ang: float = i * (TAU / 8.0) + t * 0.5  # 略带旋转
				var fx: float = pos.x + cos(ang) * frag_dist
				var fy: float = pos.y + sin(ang) * frag_dist
				var fs: float = 3.0 * (1.0 - t * 0.5)  # 碎片逐渐缩小
				draw_rect(Rect2(fx - fs * 0.5, fy - fs * 0.5, fs, fs), Color(1.0, 0.7, 0.2, frag_alpha), true)

# 提子波浪特效：在提子点所在行的方格向左右两个方向扩展，持续1秒
# 设计：从提子点开始，沿其所在行的方格向左右两侧扩散，每格随波浪到达
# 呈现橙红色脉冲（sin 0→π：0→1→0），整体1秒淡出
func _draw_capture_wave(ov: Dictionary, t: float) -> void:
	var positions: Array = ov.get("positions", [])
	if positions.is_empty():
		return
	var margin: int = _theme.board_margin
	var cs: int = _theme.cell_size
	var pulse_duration: float = 0.3  # 每格脉冲持续时长
	var alpha: float = 1.0 - t  # 整体淡出
	for p in positions:
		var center_col: int = p.x
		var row: int = p.y
		# 该位置到两端的最大距离（基于cell center），用于自适应波浪速度
		var max_dist: float = max(float(center_col) - 0.5, 17.5 - float(center_col))
		if max_dist < 0.1:
			max_dist = 0.1  # 避免除零
		# 波浪速度：在0.7秒内覆盖最大距离（剩余0.3秒让脉冲淡出）
		var wave_speed: float = max_dist / 0.7
		var y: float = margin + cs * row - cs * 0.5  # 行居中（覆盖交叉点上下半格）
		for gc in 18:
			var cell_center: float = gc + 0.5
			var dist: float = abs(cell_center - float(center_col))
			# 波浪到达该格的时间
			var arrive_time: float = dist / wave_speed
			if arrive_time > 1.0:
				continue
			# 该格的局部脉冲进度
			var local_t: float = (t - arrive_time) / pulse_duration
			if local_t < 0 or local_t > 1:
				continue
			# 脉冲强度：sin(0→π) 即 0→1→0
			var pulse: float = sin(local_t * PI)
			if pulse < 0.05:
				continue
			var x: float = margin + cs * gc
			# 提子波浪色：橙红→金黄渐变（呼应提子爆裂色）
			var c := Color(1.0, 0.55 + 0.3 * pulse, 0.15, 0.55 * pulse * alpha)
			draw_rect(Rect2(x, y, cs, cs), c, true)

# 弹子特效：橙色扩散环 + 起点终点连接线（撞隐子后弹至八格之一）
func _draw_bounce_flash(ov: Dictionary, t: float) -> void:
	var from_v: Vector2i = ov.get("overlap_pos", Vector2i(-1, -1))
	var to_v: Vector2i = ov.get("position", Vector2i(-1, -1))
	if from_v.x < 0 or to_v.x < 0:
		return
	var from_pos: Vector2 = _cell_to_pixel(from_v.y, from_v.x)
	var to_pos: Vector2 = _cell_to_pixel(to_v.y, to_v.x)
	var alpha: float = 1.0 - t
	var base_r: float = _theme.stone_radius()
	# 起点：橙色扩散环（撞隐子位置）
	draw_arc(from_pos, base_r * (1.0 + t * 2.0), 0, TAU, 32, Color(1.0, 0.55, 0.15, alpha * 0.9), 2.5)
	# 终点：金色脉冲环（弹子落点）
	draw_arc(to_pos, base_r * (1.2 + t * 1.0), 0, TAU, 32, Color(1.0, 0.85, 0.3, alpha * 0.8), 2.0)
	# 连接虚线（弹道）
	var segments: int = 6
	for i in segments:
		if i % 2 == 0:
			var t1: float = float(i) / segments
			var t2: float = float(i + 1) / segments
			var p1: Vector2 = from_pos.lerp(to_pos, t1)
			var p2: Vector2 = from_pos.lerp(to_pos, t2)
			draw_line(p1, p2, Color(1.0, 0.7, 0.2, alpha * 0.7), 1.5)

# 落子脉冲：单层扩散环
func _draw_move_pulse(ov: Dictionary, t: float) -> void:
	var pos_v: Vector2i = ov.get("position", Vector2i(-1, -1))
	if pos_v.x < 0:
		return
	var pos: Vector2 = _cell_to_pixel(pos_v.y, pos_v.x)
	var alpha: float = (1.0 - t) * 0.5
	var color: Color = Color(1.0, 0.95, 0.4, alpha)
	draw_arc(pos, _theme.stone_radius() * (1.0 + t * 0.5), 0, TAU, 24, color, 1.5)

# 布局落子脉冲：青绿色双层扩散环（与正式落子金色区分，突出布局阶段）
func _draw_deploy_place_pulse(ov: Dictionary, t: float) -> void:
	var pos_v: Vector2i = ov.get("position", Vector2i(-1, -1))
	if pos_v.x < 0:
		return
	var pos: Vector2 = _cell_to_pixel(pos_v.y, pos_v.x)
	var alpha: float = (1.0 - t) * 0.6
	var base_r: float = _theme.stone_radius()
	# 内层亮环
	draw_arc(pos, base_r * (1.0 + t * 0.6), 0, TAU, 24, Color(0.35, 0.9, 0.65, alpha), 2.0)
	# 外层扩散环
	draw_arc(pos, base_r * (1.2 + t * 1.6), 0, TAU, 24, Color(0.2, 0.7, 0.5, alpha * 0.6), 1.5)

# 部署特种部队：金色爆裂 + 十字光
# 隐子位置保密：仅己方视角（或观战）下在落子位置画特效；对方视角下画在棋盘中心避免泄露
func _draw_deploy_burst(ov: Dictionary, t: float) -> void:
	var color_val: int = ov.get("color", Const.BLACK)
	var pos_v: Vector2i = ov.get("position", Vector2i(-1, -1))
	# 仅己方视角/观战下在位置画特效；对方视角下画在棋盘中心
	var pos: Vector2
	if pos_v.x >= 0 and (observer_view == -1 or observer_view == color_val):
		pos = _cell_to_pixel(pos_v.y, pos_v.x)
	else:
		pos = Vector2(_theme.board_pixel_size() * 0.5, _theme.board_pixel_size() * 0.5)
	var alpha: float = 1.0 - t
	var base_r: float = _theme.stone_radius()
	# 金色扩散环
	draw_arc(pos, base_r * (1.0 + t * 2.0), 0, TAU, 32, Color(1.0, 0.85, 0.2, alpha * 0.8), 2.5)
	# 十字光
	var cross_r: float = base_r * (1.5 + t * 1.5)
	draw_line(pos + Vector2(-cross_r, 0), pos + Vector2(cross_r, 0), Color(1.0, 0.9, 0.3, alpha * 0.6), 1.5)
	draw_line(pos + Vector2(0, -cross_r), pos + Vector2(0, cross_r), Color(1.0, 0.9, 0.3, alpha * 0.6), 1.5)

# 隐子暴露：标记闪烁
func _draw_reveal_flash(ov: Dictionary, t: float) -> void:
	var pos_v: Vector2i = ov.get("position", Vector2i(-1, -1))
	if pos_v.x < 0:
		return
	var pos: Vector2 = _cell_to_pixel(pos_v.y, pos_v.x)
	var alpha: float = 1.0 - t
	# 闪烁效果（基于 sin 波）
	var blink: float = abs(sin(t * PI * 4))
	var r: float = _theme.stone_radius() * 1.2
	draw_arc(pos, r, 0, TAU, 24, Color(1.0, 0.8, 0.2, alpha * blink * 0.8), 2.0)

# 围空形成特效：圈内光晕扩散 + 边界高亮闪烁
func _draw_territory_formed(ov: Dictionary, t: float) -> void:
	var points: Array = ov.get("points", [])
	var color: int = ov.get("color", Const.BLACK)
	if points.is_empty():
		return
	var alpha: float = 1.0 - t
	# 围空填充色（主题领地色）
	var fill: Color = _theme.black_territory_color if color == Const.BLACK else _theme.white_territory_color
	# 1. 圈内逐点光晕扩散（波纹效果）
	for i in points.size():
		var p = points[i]
		var pos: Vector2 = _cell_to_pixel(p.y, p.x)
		# 每个点延迟不同时间出现（波纹扩散）
		var delay: float = float(i) / points.size() * 0.3
		var pt: float = clamp((t - delay) / (1.0 - delay), 0.0, 1.0)
		if pt <= 0:
			continue
		var pt_alpha: float = (1.0 - pt) * 0.6
		var s: float = _theme.cell_size * 0.5 * (0.5 + pt * 0.8)
		var c := fill
		c.a = pt_alpha
		draw_rect(Rect2(pos.x - s, pos.y - s, s * 2, s * 2), c, true)
	# 2. 中心扩散环（整体效果）
	if points.size() > 0:
		var cx: float = 0.0
		var cy: float = 0.0
		for p in points:
			var pos: Vector2 = _cell_to_pixel(p.y, p.x)
			cx += pos.x
			cy += pos.y
		cx /= points.size()
		cy /= points.size()
		var ring_c := _theme.active_side_color if _theme != null else Color(1, 0.85, 0.3)
		ring_c.a = alpha * 0.5
		var ring_r: float = _theme.stone_radius() * (1.0 + t * 4.0)
		draw_arc(Vector2(cx, cy), ring_r, 0, TAU, 32, ring_c, 2.0)

# 围困形成特效：被围困棋子周围红色脉冲环
func _draw_siege_effect(ov: Dictionary, t: float) -> void:
	var stones: Array = ov.get("stones", [])
	var alpha: float = 1.0 - t
	for s in stones:
		# 隐子位置保密：对方视角下不画围困特效
		if _is_hidden_from_observer(Vector2i(s.x, s.y)):
			continue
		var pos: Vector2 = _cell_to_pixel(s.y, s.x)
		var base_r: float = _theme.stone_radius()
		# 红色脉冲环（2 层）
		draw_arc(pos, base_r * (1.2 + t * 0.8), 0, TAU, 24, Color(0.9, 0.2, 0.1, alpha * 0.7), 2.0)
		var t2: float = clamp((t - 0.2) / 0.8, 0.0, 1.0)
		if t2 > 0:
			draw_arc(pos, base_r * (1.0 + t2 * 1.5), 0, TAU, 24, Color(0.8, 0.15, 0.1, (1.0 - t2) * 0.5), 1.5)

# 围困解除特效：棋子周围绿色光环扩散（表示做活/突围）
func _draw_siege_broken(ov: Dictionary, t: float) -> void:
	var stones: Array = ov.get("stones", [])
	var alpha: float = 1.0 - t
	for s in stones:
		# 隐子位置保密：对方视角下不画围困解除特效
		if _is_hidden_from_observer(Vector2i(s.x, s.y)):
			continue
		var pos: Vector2 = _cell_to_pixel(s.y, s.x)
		var base_r: float = _theme.stone_radius()
		# 绿色光环（2 层扩散，象征解放）
		draw_arc(pos, base_r * (1.2 + t * 1.2), 0, TAU, 24, Color(0.2, 0.9, 0.4, alpha * 0.7), 2.0)
		var t2: float = clamp((t - 0.2) / 0.8, 0.0, 1.0)
		if t2 > 0:
			draw_arc(pos, base_r * (1.0 + t2 * 1.8), 0, TAU, 24, Color(0.3, 0.8, 0.3, (1.0 - t2) * 0.5), 1.5)

# 围空失守特效：圈内灰色消散 + 边界红色闪烁（表示被突破）
func _draw_territory_lost(ov: Dictionary, t: float) -> void:
	var points: Array = ov.get("points", [])
	var color: int = ov.get("color", Const.BLACK)
	if points.is_empty():
		return
	var alpha: float = 1.0 - t
	# 1. 圈内逐点灰色消散（表示领地丧失）
	for i in points.size():
		var p = points[i]
		var pos: Vector2 = _cell_to_pixel(p.y, p.x)
		var delay: float = float(i) / points.size() * 0.3
		var pt: float = clamp((t - delay) / (1.0 - delay), 0.0, 1.0)
		if pt <= 0:
			continue
		var pt_alpha: float = (1.0 - pt) * 0.5
		var s: float = _theme.cell_size * 0.5 * (0.5 + pt * 0.8)
		draw_rect(Rect2(pos.x - s, pos.y - s, s * 2, s * 2), Color(0.5, 0.5, 0.5, pt_alpha), true)
	# 2. 边界红色闪烁环（表示被突破）
	if points.size() > 0:
		var cx: float = 0.0
		var cy: float = 0.0
		for p in points:
			var pos: Vector2 = _cell_to_pixel(p.y, p.x)
			cx += pos.x
			cy += pos.y
		cx /= points.size()
		cy /= points.size()
		var ring_r: float = _theme.stone_radius() * (1.0 + t * 4.0)
		draw_arc(Vector2(cx, cy), ring_r, 0, TAU, 32, Color(0.9, 0.2, 0.1, alpha * 0.5), 2.0)

# 终局特效：全屏渐暗 + 中心光晕
func _draw_game_end_effect(ov: Dictionary, t: float) -> void:
	var size: int = _theme.board_pixel_size()
	var center: Vector2 = Vector2(size * 0.5, size * 0.5)
	# 渐暗遮罩
	var dark_alpha: float = t * 0.4
	draw_rect(Rect2(0, 0, size, size), Color(0, 0, 0, dark_alpha), true)
	# 中心扩散光晕
	var alpha: float = (1.0 - t) * 0.6
	var r: float = _theme.stone_radius() * (1.0 + t * 8.0)
	draw_circle(center, r, Color(1.0, 0.9, 0.5, alpha * 0.3))

# 正式开局圆形扩散波浪：从棋盘中央开始，每个棋盘方格按到中心的距离呈现
# 波纹起伏（半径随时间增大 → 波纹向外扩散），整体强度 0→1→0 淡入淡出
func _draw_circular_wave() -> void:
	if _theme == null or _circular_wave_time <= 0.0:
		return
	var margin: int = _theme.board_margin
	var cs: int = _theme.cell_size
	var progress: float = 1.0 - _circular_wave_time / CIRCULAR_WAVE_DURATION  # 0→1
	var intensity: float = sin(progress * PI)  # 整体强度 0→1→0
	var t: float = Time.get_ticks_msec() / 1000.0
	# 棋盘中央（18 格区域中心）
	var center_x: float = margin + cs * 9.0
	var center_y: float = margin + cs * 9.0
	# 波纹参数：波长（格/周期）与扩散速度（格/秒，慢速从容扩散）
	var wavelength: float = 2.4
	var wave_speed: float = 3.8
	var phase_base: float = -t * wave_speed * TAU / wavelength
	for gr in 18:
		var row_center: float = gr + 0.5
		var y: float = margin + cs * gr
		for gc in 18:
			var col_center: float = gc + 0.5
			var dx: float = col_center - 9.0
			var dy: float = row_center - 9.0
			var dist: float = sqrt(dx * dx + dy * dy)
			# 波纹相位：距离越远相位越滞后（圆环），随时间向外扩散
			var phase: float = dist * TAU / wavelength + phase_base
			# 多环叠加：2 个波纹层
			var wave: float = (sin(phase) + 0.5 * sin(phase * 2.0 + 0.6)) * 0.5
			wave = max(0.0, wave) * intensity
			if wave < 0.05:
				continue
			var x: float = margin + cs * gc
			# 颜色：随波纹强度 + 距中心距离微调（中心暖白 → 边缘冷金）
			var warm: float = clamp(1.0 - dist / 13.0, 0.2, 1.0)
			var c := Color(1.0, 0.85 + 0.1 * warm, 0.45, 0.42 * wave)
			draw_rect(Rect2(x, y, cs, cs), c, true)
	# 中心光晕（波纹源点，随动画呼吸）
	var center_glow_a: float = 0.35 * intensity
	draw_circle(Vector2(center_x, center_y), cs * (1.2 + 0.6 * intensity), Color(1.0, 0.95, 0.6, center_glow_a))
	# 扩散前沿光环（随波纹半径移动）
	var ring_r: float = fmod(t * wave_speed * cs, cs * 13.0)
	var ring_a: float = 0.30 * intensity
	draw_arc(Vector2(center_x, center_y), ring_r, 0, TAU, 64, Color(1.0, 0.9, 0.5, ring_a), 2.0)

# ===== 坐标转换 =====
func _cell_to_pixel(row: int, col: int) -> Vector2:
	var margin: int = _theme.board_margin
	var cs: int = _theme.cell_size
	return Vector2(margin + cs * col, margin + cs * row)

func _pixel_to_cell(p: Vector2) -> Vector2i:
	if not _theme:
		return Vector2i(-1, -1)
	var margin: int = _theme.board_margin
	var cs: int = _theme.cell_size
	var col: int = int(round((p.x - margin) / cs))
	var row: int = int(round((p.y - margin) / cs))
	if row < 0 or row >= Const.BOARD_SIZE or col < 0 or col >= Const.BOARD_SIZE:
		return Vector2i(-1, -1)
	return Vector2i(col, row)

# ===== 输入处理 =====
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var cell: Vector2i = _pixel_to_cell(event.position)
		if cell.x >= 0:
			cell_clicked.emit(cell.y, cell.x)
	elif event is InputEventMouseMotion:
		var cell: Vector2i = _pixel_to_cell(event.position)
		if cell != hover_pos:
			hover_pos = cell
			hover_changed.emit(cell.y, cell.x)
			queue_redraw()

func _process(_delta: float) -> void:
	# 错误闪烁衰减
	if _error_flash > 0:
		_error_flash = max(0.0, _error_flash - _delta * 2.0)
		queue_redraw()
	# 开局波浪动画倒计时
	if _opening_anim_time > 0:
		_opening_anim_time = max(0.0, _opening_anim_time - _delta)
		queue_redraw()
	# 正式开局圆形扩散波浪倒计时
	if _circular_wave_time > 0:
		_circular_wave_time = max(0.0, _circular_wave_time - _delta)
		queue_redraw()
	if not effect_overlays.is_empty():
		_cleanup_overlays()
	# 是否需要持续重绘（呼吸动画/全息环/特效叠加/部署模式指示/开局波浪/圆形波浪/布局阶段）
	var need_anim: bool = _theme != null and (_theme.border_zone_pulse or _theme.holographic_ring or _deploy_mode or not effect_overlays.is_empty() or _opening_anim_time > 0 or _circular_wave_time > 0 or deploy_phase)
	if not need_anim:
		return
	# 限频 30fps（呼吸/全息环不需要 60fps，降低 GPU 负载）
	var now: int = Time.get_ticks_msec()
	if now - _last_redraw_time < 33:
		return
	_last_redraw_time = now
	queue_redraw()

# 触发非法操作红色边框闪烁
func flash_error() -> void:
	_error_flash = 1.0
	queue_redraw()

# 设置部署特种部队模式：开启时棋盘边框呼吸变色 + 顶部小横条提示
func set_deploy_mode(m: bool) -> void:
	_deploy_mode = m
	queue_redraw()

# 部署模式视觉指示：
#   - 棋盘边框呼吸变色（金色，双层：外粗内细）
#   - 顶部居中小横条 "部署模式"（低饱和金色背景 + 描边 + 文字）
# 设计原则：朴素低调、像素风硬边、契合主题色，不抢棋子焦点
func _draw_deploy_indicator(total_size: int) -> void:
	if _theme == null:
		return
	var t: float = fmod(Time.get_ticks_msec() / 1000.0, 1.6) / 1.6
	var pulse: float = 0.5 + 0.5 * sin(t * TAU)
	var base: Color = _theme.special_marker_color
	# 1. 呼吸边框（外层 3px + 内层 1px 柔光）
	var c_outer := Color(base.r, base.g, base.b, 0.35 + 0.35 * pulse)
	draw_rect(Rect2(1, 1, total_size - 2, total_size - 2), c_outer, false, 3.0)
	var c_inner := Color(base.r, base.g, base.b, 0.12 + 0.18 * pulse)
	draw_rect(Rect2(4, 4, total_size - 8, total_size - 8), c_inner, false, 1.0)
	# 2. 顶部居中小横条
	var bar_w: float = 128.0
	var bar_h: float = 18.0
	var bar_x: float = (total_size - bar_w) * 0.5
	var bar_y: float = 4.0
	# 背景（低饱和填充）
	var bar_bg := Color(base.r, base.g, base.b, 0.16 + 0.10 * pulse)
	draw_rect(Rect2(bar_x, bar_y, bar_w, bar_h), bar_bg, true)
	# 像素风硬边描边
	var bar_edge := Color(base.r, base.g, base.b, 0.85)
	draw_rect(Rect2(bar_x, bar_y, bar_w, bar_h), bar_edge, false, 1.0)
	# 文字（垂直水平居中于横条）
	var font: Font = get_theme_default_font()
	var fs: int = max(10, _theme.coord_font_size - 2)
	var label: String = LocaleManager.L("board.deploy_mode")
	var lbl_size: Vector2 = font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	var lbl_color := Color(base.r, base.g, base.b, 0.95)
	var lbl_x: float = bar_x + (bar_w - lbl_size.x) * 0.5
	var lbl_y: float = bar_y + (bar_h + fs) * 0.5 - 1
	font.draw_string(get_canvas_item(), Vector2(lbl_x, lbl_y), label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, lbl_color)
