# 计分板：显示单方分数明细 + 兵力 + 行棋方
#
# 设计（基于 UITheme 战火夜幕色系）：
#   - 纯显示组件，由 GameScreen 注入 session 并触发刷新
#   - 主题感知（颜色、字号从主题读取）
#   - 行棋方高亮（亮金呼吸边框）
#   - 分数变化动画：防御分金色闪烁、战损分红色闪烁、占领分暖金放大
#   - 数字滚动动画：总分变化时从旧值滚动到新值
#   - 入场动画：面板淡入 + 轻微缩放
#   支持单方竖向显示（set_side 指定黑/白方）
extends Panel

var session: GameSession = null
var side: int = Const.BLACK  # 本面板显示哪一方
var timer: TimerSystem = null  # 计时器引用（用于环形计时条）
var _role_name: String = ""  # 动态角色名（你/AI·难度/对手）；空则用默认"黑方/白方"
var _score_history: Array = []  # 总分历史快照 [{my: int, opp: int}, ...]（曲线图用）
var _theme: BaseTheme = null
var _total: int = 0
var _display_total: float = 0.0  # 用于数字滚动动画的当前显示值
var _opp_total: int = 0  # 对方总分（用于领先/落后判定）
var _flash: float = 0.0  # 总分变化闪烁强度
var _flash_color: Color = UITheme.C_GOLD
var _flash_scale: float = 1.0  # 总分放大倍数
# 上次明细（用于判断哪个分量变化）
var _prev_breakdown: Dictionary = {}
var _time: float = 0.0
var _thinking: bool = false  # AI 思考中状态
# 主题派生色（随主题切换更新）
var _c_text: Color = UITheme.C_TEXT
var _c_dim: Color = UITheme.C_TEXT_DIM
var _c_highlight: Color = UITheme.C_GOLD_BRIGHT
var _c_accent: Color = UITheme.C_GOLD
# 头像（从 user://avatars/{black|white}.png 加载，圆形裁剪；缺失则绘制占位符）
var _avatar_tex: ImageTexture = null
var _avatar_radius: float = 30.0  # 头像绘制半径

func _ready() -> void:
	_theme = ThemeManager.current
	_refresh_theme_colors()
	ThemeManager.theme_changed.connect(_on_theme_changed)
	reload_avatar()
	# 入场动画
	modulate.a = 0.0
	scale = Vector2(0.92, 0.92)
	var t := create_tween()
	t.set_ease(Tween.EASE_OUT)
	t.set_trans(Tween.TRANS_CUBIC)
	t.tween_interval(0.3)
	t.tween_property(self, "modulate:a", 1.0, 0.5)
	t.parallel().tween_property(self, "scale", Vector2(1.0, 1.0), 0.5)
	set_process(true)

func _on_theme_changed(t: BaseTheme) -> void:
	_theme = t
	_refresh_theme_colors()
	queue_redraw()

# 从当前主题派生文字/高亮色
func _refresh_theme_colors() -> void:
	if _theme == null:
		_c_text = UITheme.C_TEXT
		_c_dim = UITheme.C_TEXT_DIM
		_c_highlight = UITheme.C_GOLD_BRIGHT
		_c_accent = UITheme.C_GOLD
		return
	_c_text = _theme.font_color
	_c_dim = _theme.font_color.darkened(0.45)
	_c_highlight = _theme.active_side_color
	_c_accent = _theme.active_side_color

# 设置 AI 思考状态（在兵力行下方显示"思考中…"脉冲）
func set_thinking(t: bool) -> void:
	_thinking = t
	queue_redraw()

func set_side(s: int) -> void:
	side = s
	_total = 0
	_display_total = 0.0
	_opp_total = 0
	_prev_breakdown = {}
	queue_redraw()

# 设置角色名（PvE/联机模式下用）；传空串恢复默认"黑方/白方"
func set_role_name(name: String) -> void:
	_role_name = name
	queue_redraw()

# 从 user://avatars/ 加载头像（支持 png/jpg/webp）；缺失则 _avatar_tex 置空，绘制占位符
# 玩家可自定义头像：把图片放到 user://avatars/black.png 或 white.png 即可
func reload_avatar() -> void:
	_avatar_tex = null
	var side_str: String = "black" if side == Const.BLACK else "white"
	var exts: Array = [".png", ".jpg", ".jpeg", ".webp"]
	for ext in exts:
		var path: String = "user://avatars/%s%s" % [side_str, ext]
		if not FileAccess.file_exists(path):
			continue
		var img := Image.new()
		var err: int = img.load(path)
		if err != OK:
			Log.w("头像加载失败: %s (err=%d)" % [path, err])
			continue
		# 裁剪为正方形（取中心区域）后缩放到 64x64，再转圆形 alpha
		_square_crop(img)
		img.resize(64, 64)
		_apply_circle_alpha(img)
		_avatar_tex = ImageTexture.create_from_image(img)
		Log.i("头像已加载: %s" % path)
		break
	queue_redraw()

# 取中心正方形区域（避免非方形图片拉伸变形）
func _square_crop(img: Image) -> void:
	var w: int = img.get_width()
	var h: int = img.get_height()
	if w <= 0 or h <= 0:
		return
	var s: int = min(w, h)
	var x: int = (w - s) / 2
	var y: int = (h - s) / 2
	img.crop_rect(Rect2i(x, y, s, s))

# 圆形 alpha 蒙版：圆外像素透明，圆内保留，边缘 1px 抗锯齿
func _apply_circle_alpha(img: Image) -> void:
	var w: int = img.get_width()
	var h: int = img.get_height()
	var cx: float = w * 0.5
	var cy: float = h * 0.5
	var r: float = min(w, h) * 0.5
	img.convert(Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			var dx: float = x + 0.5 - cx
			var dy: float = y + 0.5 - cy
			var dist: float = sqrt(dx * dx + dy * dy)
			var c: Color = img.get_pixel(x, y)
			if dist > r + 0.5:
				c.a = 0.0
			elif dist > r - 0.5:
				c.a = c.a * (r + 0.5 - dist)
			img.set_pixel(x, y, c)

func set_session(s: GameSession) -> void:
	session = s
	_total = 0
	_display_total = 0.0
	_opp_total = 0
	_prev_breakdown = {}
	_score_history.clear()  # 清空总分历史（曲线图）
	queue_redraw()

func set_timer(t: TimerSystem) -> void:
	timer = t
	queue_redraw()

# 接收分数更新（双方分数都传入）
func on_scores_changed(scores: Dictionary) -> void:
	var my_bk = scores.black if side == Const.BLACK else scores.white
	var opp_bk = scores.white if side == Const.BLACK else scores.black
	var new_total: int = my_bk.total()
	var new_opp: int = opp_bk.total()
	# 判断各分量变化，设置闪烁颜色
	_flash = 1.0
	_flash_color = _determine_flash_color(my_bk, _prev_breakdown, new_total - _total)
	# 大变动（>=3分）→ 更强放大
	var delta: int = abs(new_total - _total)
	_flash_scale = 1.0 + (min(delta, 6) * 0.05) if delta >= 3 else 1.0
	# 保存明细
	_prev_breakdown = {
		"occupation_live": my_bk.occupation_live,
		"occupation_territory": my_bk.occupation_territory,
		"defense_annihilate": my_bk.defense_annihilate,
		"defense_siege": my_bk.defense_siege,
		"casualty": my_bk.casualty(),
	}
	_total = new_total
	_opp_total = new_opp
	# 追加总分历史（曲线图）
	_score_history.append({"my": new_total, "opp": new_opp})
	queue_redraw()

# 根据分量变化确定闪烁颜色
func _determine_flash_color(bk, prev: Dictionary, delta: int) -> Color:
	if delta > 0:
		var occ_delta: int = (bk.occupation_live + bk.occupation_territory) - int(prev.get("occupation_live", 0) + prev.get("occupation_territory", 0))
		var def_delta: int = (bk.defense_annihilate + bk.defense_siege) - int(prev.get("defense_annihilate", 0) + prev.get("defense_siege", 0))
		if def_delta > 0:
			return UITheme.C_GOLD_BRIGHT  # 防御分 → 亮金
		elif occ_delta > 0:
			return Color(1.0, 0.75, 0.3)  # 阶梯得分 → 暖金
		else:
			return Color(0.3, 1.0, 0.4)   # 其他增加 → 绿色
	elif delta < 0:
		return UITheme.C_RED_WAR  # 战损/减少 → 红
	return UITheme.C_GOLD

func _process(delta: float) -> void:
	_time += delta
	# 数字滚动：显示值向真实值逼近
	if abs(_display_total - _total) > 0.5:
		_display_total = lerp(_display_total, float(_total), delta * 8.0)
		queue_redraw()
	else:
		_display_total = float(_total)
	# 闪烁衰减
	if _flash > 0:
		_flash = max(0.0, _flash - delta * 2.5)
		_flash_scale = lerp(_flash_scale, 1.0, delta * 5.0)
		queue_redraw()
	# 呼吸边框持续重绘
	if session and not session.game_over and session.to_move == side:
		queue_redraw()

func _draw() -> void:
	if not _theme or not session:
		return
	var sc: Dictionary = session.scores()
	var my_bk = sc.black if side == Const.BLACK else sc.white
	var w: float = size.x
	var h: float = size.y
	var is_active: bool = (session.to_move == side) and not session.game_over
	# 背景填充（深褐紫 + 主题色调染色；行棋方叠加金色染色提亮）
	var bg := UITheme.C_PANEL_BG
	if side == Const.BLACK:
		bg = bg.lerp(Color(0.10, 0.12, 0.20, 0.88), 0.4)  # 黑方略带冷色
	else:
		bg = bg.lerp(Color(0.18, 0.12, 0.06, 0.88), 0.4)  # 白方略带暖色
	if is_active:
		# 行棋方：叠加主题色调，让整板"亮"起来
		bg = bg.lerp(_c_accent, 0.12)
		# 呼吸光晕（顶部内测高光带）
		var pulse: float = 0.5 + 0.5 * sin(_time * 2.5)
		var glow: Color = _c_highlight
		glow.a = 0.08 + 0.10 * pulse
		draw_rect(Rect2(0, 0, w, h), glow, true)
	draw_rect(Rect2(0, 0, w, h), bg, true)
	# 像素风四层边框（行棋方激活时边框高亮 + 更粗）
	UITheme.draw_pixel_border(self, 0, 0, w, h, is_active, _c_accent)
	# 行棋方：外圈呼吸亮金描边（双层强化）
	if is_active:
		var pulse: float = 0.5 + 0.5 * sin(_time * 2.5)
		var c: Color = _c_highlight
		c.a = 0.55 + 0.40 * pulse
		draw_rect(Rect2(2, 2, w - 4, h - 4), c, false, 2.0)
	# 内容
	_draw_content(0, 0, w, h, my_bk)

# 内容绘制 —— 三段式名片布局
# 模块1：身份名片（头像+名称+兵力，横向） → 分隔线
# 模块2：总分焦点（大字居中）            → 分隔线
# 模块3：明细列表（5行整齐排列）
func _draw_content(x: float, y: float, w: float, h: float, bk) -> void:
	var is_active: bool = (session.to_move == side) and not session.game_over
	# 内容总高度（三段式）
	var content_h: float = 540.0  # 含曲线图区域
	var oy: float = max(0.0, (h - content_h) * 0.5)  # 垂直居中偏移

	var name_str: String = _role_name if _role_name != "" else ("黑 方" if side == Const.BLACK else "白 方")
	# 领先/落后配色
	var is_leading: bool = bk.total() > _opp_total
	var lead_color: Color = _c_text
	if not session.game_over and bk.total() != _opp_total:
		lead_color = Color(0.4, 1.0, 0.5) if is_leading else Color(1.0, 0.5, 0.4)
	# 行棋方名称用主题高亮色突出
	if is_active:
		lead_color = _c_highlight

	var font: Font = get_theme_default_font()
	var cx: float = x + w * 0.5  # 水平中心
	var pad: float = 22.0        # 左右内边距

	# ===== 模块0：水平计时条（头像上方，面板顶部）=====
	# 行棋方动态流光、低时间闪烁
	_draw_timer_bar(x + pad, y + oy + 6, w - pad * 2, 12.0, is_active)

	# ===== 模块1：身份名片（y+oy+22 ~ y+oy+100）=====
	# 头像在左，名称+兵力在右，横向名片式
	var av_cx: float = x + pad + 26  # 头像中心 x（左侧）
	var av_cy: float = y + oy + 50   # 头像中心 y（下移避让计时条）
	# 头像
	_draw_avatar(av_cx, av_cy, 26.0)
	# 行棋方：头像下方小三角形指示器（保留视觉焦点指示）
	if is_active:
		_draw_active_indicator(av_cx, av_cy + 26 + 10, _c_highlight)
	# 名称 + 兵力（头像右侧，左对齐）
	var text_x: float = av_cx + 26 + 14  # 文字起始 x = 头像右边缘 + 间距
	var name_fs: int = _theme.score_font_size + 6
	font.draw_string(get_canvas_item(), Vector2(text_x, y + oy + 44), name_str, HORIZONTAL_ALIGNMENT_LEFT, -1, name_fs, lead_color)
	var pieces_left: int = session.pieces_left(side)
	var pieces_str: String = "兵力 %d / %d" % [pieces_left, Const.PIECE_LIMIT]
	font.draw_string(get_canvas_item(), Vector2(text_x, y + oy + 68), pieces_str, HORIZONTAL_ALIGNMENT_LEFT, -1, _theme.coord_font_size + 2, _c_dim)

	# 分隔线1
	var sep1_y: float = y + oy + 102
	_draw_section_sep(x + pad, sep1_y, w - pad * 2)

	# ===== 模块2：总分焦点（y+oy+102 ~ y+oy+228）=====
	# "总 分" 标签
	font.draw_string(get_canvas_item(), Vector2(cx, y + oy + 134), "总  分", HORIZONTAL_ALIGNMENT_CENTER, -1, _theme.coord_font_size + 3, _c_dim)
	# 总分大字（闪烁+放大+数字滚动）
	var total_str: String = str(int(round(_display_total)))
	var total_size: int = int((_theme.score_total_font_size + 10) * _flash_scale)
	if _flash > 0:
		total_size = int(total_size * (1.0 + _flash * 0.15))
	var total_color: Color = lead_color
	if _flash > 0:
		total_color = total_color.lerp(_flash_color, _flash)
	font.draw_string(get_canvas_item(), Vector2(cx, y + oy + 184), total_str, HORIZONTAL_ALIGNMENT_CENTER, -1, total_size, total_color)
	# AI 思考中提示（总分下方，脉冲透明度）
	if _thinking:
		var pulse: float = 0.5 + 0.5 * sin(_time * 4.0)
		var think_color: Color = _c_highlight
		think_color.a = 0.5 + 0.45 * pulse
		font.draw_string(get_canvas_item(), Vector2(cx, y + oy + 210), "思 考 中 …", HORIZONTAL_ALIGNMENT_CENTER, -1, _theme.coord_font_size + 3, think_color)

	# 分隔线2
	var sep2_y: float = y + oy + 228
	_draw_section_sep(x + pad, sep2_y, w - pad * 2)

	# ===== 模块3：得分构成分数条（y+oy+228 ~ y+oy+420）=====
	# 合并：占领分=活子+围空，防御分=歼灭+围困，战损分=战损
	_draw_score_bars(x + pad, y + oy + 240, w - pad * 2, 150.0, bk)

	# 分隔线3
	var sep3_y: float = y + oy + 400
	_draw_section_sep(x + pad, sep3_y, w - pad * 2)

	# ===== 模块4：总分变化曲线图 =====
	_draw_score_chart(x + pad, sep3_y + 8, w - pad * 2, 90.0)

# 得分构成分数条：合并显示占领分、防御分、战损分
#   x: 左上角 x, y: 顶部 y, w: 宽度, h: 高度, bk: Breakdown
# 布局：标题 + 3 条水平分数条（每条：左侧名称 + 右侧分数 + 中间进度条）
# 颜色协调：占领=暖金、防御=青绿（稳定感）、战损=暗红（危险感）
func _draw_score_bars(x: float, y: float, w: float, h: float, bk) -> void:
	var font: Font = get_theme_default_font()
	var label_fs: int = max(10, _theme.coord_font_size - 1)
	# 标题
	font.draw_string(get_canvas_item(), Vector2(x + w * 0.5, y + label_fs), "得 分 构 成", HORIZONTAL_ALIGNMENT_CENTER, -1, label_fs + 1, _c_dim)
	# 合并分数
	var occ: int = bk.occupation()      # 活子 + 围空
	var def: int = bk.defense()         # 歼灭 + 围困
	var cas: int = abs(bk.casualty())   # 战损（取绝对值显示量）
	# 颜色（与主题协调：暖金/青绿/暗红）
	var c_occ := Color(1.0, 0.72, 0.28, 0.92)   # 占领 - 暖金
	var c_def := Color(0.40, 0.78, 0.55, 0.92)  # 防御 - 青绿
	var c_cas := Color(0.72, 0.28, 0.22, 0.92)  # 战损 - 暗红
	# 三条分数条参数
	var items: Array = [
		{"name": "占领分", "value": occ, "color": c_occ, "sign": 1},
		{"name": "防御分", "value": def, "color": c_def, "sign": 1},
		{"name": "战损分", "value": cas, "color": c_cas, "sign": -1},  # 战损为扣分
	]
	# 条形区域布局
	var bar_area_y: float = y + label_fs + 14
	var bar_area_h: float = h - label_fs - 14
	var bar_h: float = 14.0                          # 每条进度条高度
	var row_h: float = bar_area_h / 3.0              # 每行高度（含名称+条+分数）
	var name_w: float = 56.0                         # 名称列宽度
	var val_w: float = 40.0                          # 分数列宽度
	var bar_x: float = x + name_w                     # 进度条起始 x
	var bar_w: float = w - name_w - val_w            # 进度条宽度
	# 比例基准：取三数最大值（保证至少 1，且条形不会过长）
	var max_val: int = max(max(occ, def), cas)
	max_val = max(max_val, 1)
	# 背景/边框色
	var bg_c := Color(0, 0, 0, 0.35)
	var border_c := _c_dim
	border_c.a = 0.45
	for i in items.size():
		var item: Dictionary = items[i]
		var row_y: float = bar_area_y + i * row_h
		# 名称（左对齐）
		font.draw_string(get_canvas_item(), Vector2(x, row_y + bar_h * 0.5 + label_fs * 0.35), item.name, HORIZONTAL_ALIGNMENT_LEFT, -1, label_fs, _c_text)
		# 进度条背景槽
		draw_rect(Rect2(bar_x, row_y, bar_w, bar_h), bg_c, true)
		# 进度条填充（按比例）
		var ratio: float = float(item.value) / float(max_val)
		ratio = clamp(ratio, 0.0, 1.0)
		var fill_w: float = bar_w * ratio
		if fill_w > 0:
			# 主体填充
			draw_rect(Rect2(bar_x, row_y, fill_w, bar_h), item.color, true)
			# 顶部高光（像素风硬边，亮度+20%）
			var hl_c: Color = item.color.lightened(0.25)
			hl_c.a = 0.6
			draw_rect(Rect2(bar_x, row_y, fill_w, 2.0), hl_c, true)
		# 进度条描边
		draw_rect(Rect2(bar_x, row_y, bar_w, bar_h), border_c, false, 1.0)
		# 分数（右对齐，战损显示负数）
		var val_str: String = str(item.value)
		if item.sign < 0 and item.value > 0:
			val_str = "-" + val_str
		var val_c: Color = _c_text
		if item.value == 0:
			val_c = _c_dim
		font.draw_string(get_canvas_item(), Vector2(x + w, row_y + bar_h * 0.5 + label_fs * 0.35), val_str, HORIZONTAL_ALIGNMENT_RIGHT, -1, label_fs + 1, val_c)

# 总分变化曲线图：绘制本方与对方总分随手数变化的折线图
#   x: 图表左上角 x, y: 图表左上角 y, w: 宽度, h: 高度
func _draw_score_chart(x: float, y: float, w: float, h: float) -> void:
	var font: Font = get_theme_default_font()
	var label_fs: int = max(10, _theme.coord_font_size - 1)
	# 标题
	font.draw_string(get_canvas_item(), Vector2(x, y + label_fs), "总分变化", HORIZONTAL_ALIGNMENT_LEFT, -1, label_fs, _c_dim)
	# 图表区域（留出标题和底部图例空间）
	var chart_x: float = x
	var chart_y: float = y + label_fs + 4
	var chart_w: float = w
	var chart_h: float = h - label_fs - 4 - 14  # 底部14px图例
	if chart_h < 20:
		return
	# 背景
	var bg_c := Color(0, 0, 0, 0.3)
	draw_rect(Rect2(chart_x, chart_y, chart_w, chart_h), bg_c, true)
	# 边框
	var border_c := _c_dim
	border_c.a = 0.4
	draw_rect(Rect2(chart_x, chart_y, chart_w, chart_h), border_c, false, 1.0)
	# 无历史数据时显示提示
	if _score_history.size() < 2:
		font.draw_string(get_canvas_item(), Vector2(chart_x + chart_w * 0.5, chart_y + chart_h * 0.5 + label_fs * 0.5), "等待对局...", HORIZONTAL_ALIGNMENT_CENTER, -1, label_fs, _c_dim)
		return
	# 计算Y轴范围
	var max_score: int = 1
	for entry in _score_history:
		max_score = max(max_score, abs(entry.my), abs(entry.opp))
	max_score = max(max_score, 10)  # 最小范围
	var y_scale: float = chart_h * 0.45 / float(max_score)  # 上下各留余量
	var mid_y: float = chart_y + chart_h * 0.5  # 0分线（中线）
	# 0分线（暗色）
	var zero_c := _c_dim
	zero_c.a = 0.2
	draw_line(Vector2(chart_x, mid_y), Vector2(chart_x + chart_w, mid_y), zero_c, 1.0)
	# X轴缩放
	var n: int = _score_history.size()
	var x_step: float = chart_w / max(1, n - 1)
	# 绘制对方曲线（暗色）
	var opp_color := _c_dim
	opp_color.a = 0.7
	var opp_pts: PackedVector2Array = PackedVector2Array()
	for i in n:
		var px: float = chart_x + i * x_step
		var py: float = mid_y - _score_history[i].opp * y_scale
		py = clamp(py, chart_y, chart_y + chart_h)
		opp_pts.append(Vector2(px, py))
	if opp_pts.size() >= 2:
		for i in opp_pts.size() - 1:
			draw_line(opp_pts[i], opp_pts[i + 1], opp_color, 1.5)
	# 绘制本方曲线（主题高亮色）
	var my_color := _c_highlight
	my_color.a = 0.9
	var my_pts: PackedVector2Array = PackedVector2Array()
	for i in n:
		var px: float = chart_x + i * x_step
		var py: float = mid_y - _score_history[i].my * y_scale
		py = clamp(py, chart_y, chart_y + chart_h)
		my_pts.append(Vector2(px, py))
	if my_pts.size() >= 2:
		for i in my_pts.size() - 1:
			draw_line(my_pts[i], my_pts[i + 1], my_color, 2.0)
	# 最新点高亮
	if my_pts.size() > 0:
		draw_circle(my_pts[my_pts.size() - 1], 3.0, my_color)
	# 底部图例
	var legend_y: float = chart_y + chart_h + 10
	var legend_x: float = chart_x
	# 本方图例
	draw_line(Vector2(legend_x, legend_y), Vector2(legend_x + 12, legend_y), my_color, 2.0)
	font.draw_string(get_canvas_item(), Vector2(legend_x + 16, legend_y + label_fs * 0.4), "本方", HORIZONTAL_ALIGNMENT_LEFT, -1, label_fs, _c_text)
	# 对方图例
	var opp_legend_x: float = legend_x + 50
	draw_line(Vector2(opp_legend_x, legend_y), Vector2(opp_legend_x + 12, legend_y), opp_color, 1.5)
	font.draw_string(get_canvas_item(), Vector2(opp_legend_x + 16, legend_y + label_fs * 0.4), "对方", HORIZONTAL_ALIGNMENT_LEFT, -1, label_fs, _c_dim)

# 分区分隔线（带主题色调，比旧版更精致：中部稍亮，两端渐暗）
func _draw_section_sep(x: float, y: float, w: float) -> void:
	var c: Color = _c_dim
	c.a = 0.55
	draw_line(Vector2(x, y), Vector2(x + w, y), c, 1.0)
	# 中部高光（主题色，营造光带感）
	var hc: Color = _c_accent
	hc.a = 0.35
	var mw: float = w * 0.3
	draw_line(Vector2(x + (w - mw) * 0.5, y), Vector2(x + (w + mw) * 0.5, y), hc, 1.0)

# 行棋方指示器：头像下方的小三角形（向上指），带呼吸脉冲
func _draw_active_indicator(cx: float, cy: float, color: Color) -> void:
	var pulse: float = 0.5 + 0.5 * sin(_time * 2.5)
	var s: float = 6.0 + pulse * 1.5  # 三角形大小随呼吸变化
	var c := color
	c.a = 0.7 + 0.3 * pulse
	# 像素风三角形（向上指）
	var pts: PackedVector2Array = PackedVector2Array([
		Vector2(cx, cy - s),         # 顶部尖端（向上指）
		Vector2(cx - s * 0.7, cy + s * 0.5),  # 左下
		Vector2(cx + s * 0.7, cy + s * 0.5),  # 右下
	])
	draw_colored_polygon(pts, c)

# 水平计时条：放置在头像上方，行棋方动态流光 + 剩10秒呼吸灯
#   x, y, w, h: 计时条矩形（h 通常为 12）
#   is_active: 是否行棋方
# 动态效果：
#   1. 行棋方：进度条内部有亮带从左到右流动（流光）
#   2. 行棋方：进度条右端光晕呼吸
#   3. 剩余<=10秒：整条呼吸灯（红色脉冲，时间越少呼吸越快）
#   4. 时间数字倒数（每帧更新）
#   5. 读秒状态：左侧显示剩余读秒次数小圆点
func _draw_timer_bar(x: float, y: float, w: float, h: float, is_active: bool) -> void:
	if timer == null:
		return
	var font: Font = get_theme_default_font()
	var label_fs: int = max(10, _theme.coord_font_size - 2)
	var progress: float = timer.get_progress(side)
	# 无限时间 → 居中显示 "∞ 无限"
	if progress < 0:
		var inf_c := _c_dim
		inf_c.a = 0.6 if is_active else 0.4
		font.draw_string(get_canvas_item(), Vector2(x + w * 0.5, y + label_fs + 1), "∞   无 限", HORIZONTAL_ALIGNMENT_CENTER, -1, label_fs, inf_c)
		return
	var tinfo: Dictionary = timer.get_time(side)
	var in_byoyomi: bool = bool(tinfo.in_byoyomi)
	var byo_left: int = int(tinfo.byoyomi_left)
	# 计算剩余秒数（用于呼吸灯触发判定）
	var remain_sec: float = 0.0
	if in_byoyomi:
		remain_sec = float(tinfo.byoyomi_time)
	else:
		remain_sec = float(tinfo.main)
	# 凹槽背景（深色像素风）
	var bg_c := Color(0, 0, 0, 0.55)
	draw_rect(Rect2(x, y, w, h), bg_c, true)
	# 像素风描边（硬边，主题色暗化）
	var border_c := _c_dim
	border_c.a = 0.55
	draw_rect(Rect2(x, y, w, h), border_c, false, 1.0)
	# 进度填充宽度
	var fill_w: float = w * clamp(progress, 0.0, 1.0)
	# 填充色：低时间红呼吸 / 中等暖金 / 充足主题色
	var fill_c: Color
	var low_time: bool = is_active and remain_sec <= 10.0 and remain_sec > 0.0
	var breath_pulse: float = 0.0  # 呼吸灯脉冲值（0~1），低时间时 > 0
	if low_time:
		# 呼吸频率：10秒→2Hz，1秒→8Hz（时间越少呼吸越快）
		var breath_freq: float = lerp(2.0, 8.0, 1.0 - clamp(remain_sec / 10.0, 0.0, 1.0))
		breath_pulse = 0.5 + 0.5 * sin(_time * breath_freq * TAU * 0.5)
		# 红色基调，亮度随呼吸变化
		fill_c = Color(0.95, 0.2, 0.15).lerp(Color(1.0, 0.55, 0.3), breath_pulse)
	elif progress < 0.5:
		fill_c = Color(1.0, 0.75, 0.3)
	else:
		fill_c = _c_accent if is_active else _c_dim.lerp(_c_accent, 0.55)
	# 实心填充（行棋方稍亮）
	if fill_w > 1.0:
		var fc := fill_c
		fc.a = 0.95 if is_active else 0.7
		draw_rect(Rect2(x + 1, y + 1, fill_w - 2, h - 2), fc, true)
	# 动态效果1：行棋方流光（亮带从左到右流动）
	if is_active and fill_w > 8.0 and not low_time:
		var flow_w: float = min(fill_w * 0.35, 26.0)
		var cycle: float = fill_w + flow_w
		var phase: float = fmod(_time * 50.0, cycle)
		var flow_x: float = x + 1 + phase - flow_w
		# 流光带：正弦透明度（中心最亮，两端淡出）
		var steps: int = int(flow_w)
		for i in steps:
			var fx: float = flow_x + i
			if fx <= x + 1 or fx >= x + fill_w - 1:
				continue
			var a: float = sin(float(i) / float(max(1, steps)) * PI) * 0.55
			draw_line(Vector2(fx, y + 1), Vector2(fx, y + h - 1), Color(1, 1, 1, a), 1.0)
	# 动态效果2：行棋方右端光晕呼吸（进度条前沿发光）
	if is_active and fill_w > 2.0 and not low_time:
		var pulse: float = 0.5 + 0.5 * sin(_time * 4.0)
		var glow_c := fill_c
		glow_c.a = 0.55 + 0.40 * pulse
		draw_line(Vector2(x + fill_w, y), Vector2(x + fill_w, y + h), glow_c, 2.0)
		# 外延柔光（2px 横向扩散）
		var outer_c := fill_c
		outer_c.a = 0.25 * pulse
		draw_line(Vector2(x + fill_w + 1, y + 1), Vector2(x + fill_w + 1, y + h - 1), outer_c, 1.0)
	# 动态效果3：低时间呼吸灯（整条外发光，随呼吸强弱扩散）
	if low_time:
		# 外发光层（向外扩散2~4px，亮度随呼吸）
		var glow_alpha: float = 0.35 + 0.45 * breath_pulse
		var glow_w: float = 2.0 + 2.0 * breath_pulse  # 扩散宽度2~4px
		# 上下左右四方向外发光
		var g_c := Color(1.0, 0.3, 0.2, glow_alpha * 0.5)
		draw_rect(Rect2(x - glow_w, y - glow_w, w + glow_w * 2, glow_w), g_c, true)  # 上
		draw_rect(Rect2(x - glow_w, y + h, w + glow_w * 2, glow_w), g_c, true)  # 下
		draw_rect(Rect2(x - glow_w, y, glow_w, h), g_c, true)  # 左
		draw_rect(Rect2(x + w, y, glow_w, h), g_c, true)  # 右
		# 内部高亮线（呼吸时整条提亮）
		var inner_c := Color(1.0, 0.7, 0.5, breath_pulse * 0.6)
		draw_line(Vector2(x + 1, y + h * 0.5), Vector2(x + fill_w - 1, y + h * 0.5), inner_c, 1.0)
	# 读秒次数指示（进度条左侧上方小圆点 ●●●）
	if byo_left > 0:
		var dot_r: float = 2.5
		var dot_gap: float = 7.0
		for i in byo_left:
			var dot_x: float = x + 2 + i * dot_gap
			var dot_c := _c_accent
			dot_c.a = 0.9 if is_active else 0.55
			draw_circle(Vector2(dot_x, y - 6), dot_r, dot_c)
	# 时间数字（进度条右上方，与填充色同色突出倒数感）
	var time_str: String
	if in_byoyomi:
		var bt: float = float(tinfo.byoyomi_time)
		time_str = "读秒 %ds" % int(ceil(max(0.0, bt)))
	else:
		var mt: float = float(tinfo.main)
		var mm: int = int(mt) / 60
		var ss: int = int(mt) % 60
		if mm > 0:
			time_str = "%d:%02d" % [mm, ss]
		else:
			time_str = "%ds" % ss
	var num_c: Color = fill_c if is_active else _c_dim
	num_c.a = 0.95 if is_active else 0.65
	font.draw_string(get_canvas_item(), Vector2(x + w, y - 2), time_str, HORIZONTAL_ALIGNMENT_RIGHT, -1, label_fs, num_c)

# 绘制头像：有纹理画纹理，无纹理画像素风占位符（棋子色圆 + 人头剪影）
func _draw_avatar(cx: float, cy: float, radius: float) -> void:
	var r: float = radius
	# 行棋方头像轻微呼吸放大
	var is_active: bool = session != null and not session.game_over and session.to_move == side
	if is_active:
		r *= 1.0 + 0.04 * sin(_time * 2.5)
	if _avatar_tex != null:
		# 像素描边（主题色，行棋方更亮）
		var rim: Color = _c_accent if is_active else _c_dim
		draw_arc(Vector2(cx, cy), r + 2.0, 0, TAU, 32, rim, 2.0)
		# 头像纹理（64x64 圆形 alpha，缩放到 2r x 2r 居中绘制）
		var tex_size: float = r * 2.0
		draw_texture_rect(_avatar_tex, Rect2(cx - r, cy - r, tex_size, tex_size), false)
	else:
		# 占位符：棋子色背景圆 + 主题色描边 + 像素风人头剪影
		var bg_c: Color = _theme.black_stone_color if side == Const.BLACK else _theme.white_stone_color
		draw_circle(Vector2(cx, cy), r, bg_c)
		var rim: Color = _c_accent if is_active else _c_dim
		draw_arc(Vector2(cx, cy), r, 0, TAU, 32, rim, 2.0)
		# 人头剪影（与棋子反色，像素风硬边）
		var sil_c: Color = _theme.white_stone_color if side == Const.BLACK else _theme.black_stone_color
		sil_c.a = 0.85
		# 头部（小圆）
		draw_circle(Vector2(cx, cy - r * 0.25), r * 0.28, sil_c)
		# 肩膀（矩形近似梯形）
		var sw: float = r * 0.7
		var sh: float = r * 0.35
		var sy: float = cy + r * 0.15
		draw_rect(Rect2(cx - sw * 0.5, sy, sw, sh), sil_c, true)
