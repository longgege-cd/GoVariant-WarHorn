# 战争号角 · 统一视觉主题与动画工具库
#
# 设计哲学：
#   - 摒弃黑白配色，采用"战火夜幕"色系：深褐底 + 暖金主调 + 暗红战争点缀 + 暗紫氛围
#   - 所有界面共享同一套配色、动画曲线、入场动效，视觉统一
#   - 动画风格：克制的仪式感（缓慢淡入、呼吸光效、粒子飘散）
#
# 色板（战火夜幕）：
#   背景层：深褐黑 C_BG_BOT → 暗紫 C_BG_TOP（垂直渐变）
#   主色调：暖金 C_GOLD / 亮金 C_GOLD_BRIGHT / 暗金 C_GOLD_DIM
#   点缀色：战争红 C_RED_WAR（仅用于关键操作如认输/退出）
#   中性色：褐石 C_STONE / 深底 C_DARK
#   文字色：暖白 C_TEXT / 暗灰 C_TEXT_DIM
class_name UITheme
extends RefCounted

# === 配色 ===
const C_BG_TOP := Color(0.12, 0.06, 0.16, 1.0)       # 顶部暗紫（夜幕）
const C_BG_MID := Color(0.07, 0.04, 0.10, 1.0)       # 中部暗紫褐
const C_BG_BOT := Color(0.04, 0.03, 0.05, 1.0)       # 底部深褐黑

const C_GOLD := Color(0.95, 0.78, 0.32, 1.0)         # 暖金主色
const C_GOLD_BRIGHT := Color(1.0, 0.90, 0.50, 1.0)   # 亮金（悬停/激活）
const C_GOLD_DIM := Color(0.62, 0.50, 0.20, 1.0)     # 暗金（次要）
const C_GOLD_GLOW := Color(1.0, 0.82, 0.35, 0.25)    # 金色光晕

const C_RED_WAR := Color(0.78, 0.22, 0.16, 1.0)      # 战争红（危险操作）
const C_RED_DIM := Color(0.50, 0.16, 0.12, 1.0)      # 暗红

const C_STONE := Color(0.20, 0.15, 0.10, 1.0)        # 褐石
const C_DARK := Color(0.05, 0.035, 0.06, 1.0)        # 深底
const C_PANEL_BG := Color(0.08, 0.05, 0.10, 0.92)    # 面板背景

const C_TEXT := Color(0.94, 0.88, 0.72, 1.0)         # 暖白文字
const C_TEXT_DIM := Color(0.62, 0.56, 0.46, 1.0)     # 暗灰文字
const C_TEXT_FAINT := Color(0.42, 0.38, 0.32, 1.0)   # 更暗文字

# === 动画曲线 ===
const ANIM_FADE_IN := 0.4                             # 淡入时长（秒）
const ANIM_SLIDE_IN := 0.5                            # 滑入时长
const ANIM_BUTTON_HOVER := 0.12                       # 按钮悬停过渡
const ANIM_DIALOG_SCALE := 0.25                       # 对话框缩放进场

# === 缓动函数 ===
static func ease_out_cubic(t: float) -> float:
	return 1.0 - pow(1.0 - t, 3.0)

static func ease_in_out_cubic(t: float) -> float:
	return 4.0 * t * t * t if t < 0.5 else 1.0 - pow(-2.0 * t + 2.0, 3.0) * 0.5

static func ease_out_back(t: float) -> float:
	var c1: float = 1.70158
	var c3: float = c1 + 1.0
	return 1.0 + c3 * pow(t - 1.0, 3.0) + c1 * pow(t - 1.0, 2.0)

# === 渐变纹理生成（缓存友好，调用方应缓存返回值）===
static func make_bg_gradient() -> GradientTexture2D:
	var grad := Gradient.new()
	grad.add_point(0.0, C_BG_TOP)
	grad.add_point(0.5, C_BG_MID)
	grad.add_point(1.0, C_BG_BOT)
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.width = 4
	tex.height = 512
	tex.fill = GradientTexture2D.FILL_LINEAR
	tex.fill_from = Vector2(0.0, 0.0)
	tex.fill_to = Vector2(0.0, 1.0)
	return tex

static func make_vignette_texture() -> GradientTexture2D:
	var grad := Gradient.new()
	grad.add_point(0.0, Color(0, 0, 0, 0.0))
	grad.add_point(0.55, Color(0, 0, 0, 0.0))
	grad.add_point(1.0, Color(0, 0, 0, 0.70))
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.width = 512
	tex.height = 512
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	return tex

# === 像素风四层边框 ===
static func draw_pixel_border(canvas: CanvasItem, x: float, y: float, w: float, h: float, active: bool = false, accent: Color = C_GOLD_BRIGHT) -> void:
	# 深色底框
	canvas.draw_rect(Rect2(x, y, w, h), Color(0.02, 0.02, 0.04, 1.0), false, 2.0)
	# 外描边（主题色 / 激活时更亮）
	var outer := accent if active else C_GOLD_DIM
	outer.a = 0.95 if active else 0.85
	canvas.draw_rect(Rect2(x + 2, y + 2, w - 4, h - 4), outer, false, 1.0)
	# 内描边（暗色）
	canvas.draw_rect(Rect2(x + 4, y + 4, w - 8, h - 8), Color(0.15, 0.12, 0.08, 0.8), false, 1.0)
	# 顶部高光（1px 亮线，跟随主题色）
	var hl := accent
	hl.a = 0.5
	canvas.draw_line(Vector2(x + 4, y + 5), Vector2(x + w - 4, y + 5), hl, 1.0)

# === 像素风按钮 StyleBox ===
static func make_button_style(active: bool, hover: bool, danger: bool = false) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.corner_detail = 1
	sb.border_width_left = 2
	sb.border_width_right = 2
	sb.border_width_top = 2
	sb.border_width_bottom = 2
	if danger:
		# 危险按钮（认输/退出）
		sb.bg_color = C_RED_DIM if not hover else C_RED_WAR
		sb.border_color = C_RED_WAR if not hover else Color(1.0, 0.45, 0.30, 1.0)
	elif active:
		# 选中态
		sb.bg_color = C_DARK.lightened(0.10)
		sb.border_color = C_GOLD_BRIGHT if hover else C_GOLD
	else:
		# 普通态
		sb.bg_color = C_DARK if not hover else C_DARK.lightened(0.08)
		sb.border_color = C_GOLD if hover else Color(0.30, 0.24, 0.16, 1.0)
	return sb

# === 按钮悬停动画（Tween）===
static func animate_button_hover(btn: Button, hover: bool) -> void:
	var target_color := C_GOLD_BRIGHT if hover else C_GOLD
	var tween := btn.create_tween()
	tween.tween_property(btn, "theme_override_colors/font_color", target_color, ANIM_BUTTON_HOVER)
	tween.set_ease(Tween.EASE_OUT)
	tween.set_trans(Tween.TRANS_CUBIC)
	# 轻微缩放
	var target_scale := Vector2(1.04, 1.04) if hover else Vector2(1.0, 1.0)
	var st := btn.create_tween()
	st.tween_property(btn, "scale", target_scale, ANIM_BUTTON_HOVER)
	st.set_ease(Tween.EASE_OUT)
	st.set_trans(Tween.TRANS_CUBIC)

# === 对话框/面板缩放进场动画 ===
static func animate_dialog_entrance(node: Control) -> void:
	node.scale = Vector2(0.85, 0.85)
	node.modulate.a = 0.0
	var t := node.create_tween()
	t.set_ease(Tween.EASE_OUT)
	t.set_trans(Tween.TRANS_BACK)
	t.tween_property(node, "scale", Vector2(1.0, 1.0), ANIM_DIALOG_SCALE)
	t.parallel().tween_property(node, "modulate:a", 1.0, ANIM_DIALOG_SCALE)

# === 子节点逐个淡入动画 ===
static func animate_children_stagger(container: Container, base_delay: float = 0.05) -> void:
	var delay: float = 0.0
	for child in container.get_children():
		if child is Control:
			child.modulate.a = 0.0
			child.offset_top += 20
			var t := child.create_tween()
			t.set_ease(Tween.EASE_OUT)
			t.set_trans(Tween.TRANS_CUBIC)
			t.tween_interval(delay)
			t.tween_property(child, "modulate:a", 1.0, ANIM_FADE_IN)
			t.parallel().tween_property(child, "offset_top", child.offset_top - 20, ANIM_SLIDE_IN)
			delay += base_delay

# === 背景粒子数据结构 ===
class Particle:
	var x: float
	var y: float
	var speed: float
	var size: float
	var alpha: float
	var warm: bool       # 暖色（火星）还是冷色（星尘）
	var phase: float     # 闪烁相位
	func _init() -> void:
		x = randf()
		y = randf()
		speed = 0.015 + randf() * 0.035
		size = 1.0 + randf() * 2.5
		alpha = 0.15 + randf() * 0.40
		warm = randf() > 0.55
		phase = randf() * TAU

# 生成粒子数组
static func make_particles(count: int) -> Array:
	var arr: Array = []
	for i in count:
		arr.append(Particle.new())
	return arr

# 绘制粒子（飘散 + 闪烁）
static func draw_particles(canvas: CanvasItem, particles: Array, w: float, h: float, time: float) -> void:
	for p in particles:
		var px: float = p.x * w
		var py: float = p.y * h
		var c: Color = C_GOLD_BRIGHT if p.warm else Color(0.80, 0.78, 0.92, 1.0)
		c.a = p.alpha * (0.55 + 0.45 * sin(time * 1.8 + p.phase))
		canvas.draw_rect(Rect2(px, py, p.size, p.size), c, true)

# 更新粒子位置（向上飘散）
static func update_particles(particles: Array, delta: float) -> void:
	for p in particles:
		p.y -= p.speed * delta * 0.6
		if p.y < -0.05:
			p.y = 1.05
			p.x = randf()

# ============================================================
# 火焰粒子系统（像素风 · 战争号角主题）
#
# 设计（应用 stark 视觉质量原则）：
#   - 视觉层次：火焰为氛围底层，从底部升起，不抢标题焦点
#   - 色温衰减：白热核心 → 暖金 → 战争红 → 暗烟（模拟真实燃烧）
#   - 物理：浮力加速上升 + 水平湍流闪烁 + 尺寸先涨后缩
#   - 像素风：用 draw_rect 渲染方块，匹配整体像素美学
# ============================================================

class FireParticle:
	var x: float          # 归一化横坐标 [0,1]
	var y: float          # 归一化纵坐标 [0,1]（0=顶 1=底）
	var vx: float         # 水平速度
	var vy: float         # 垂直速度（向上为正）
	var life: float       # 生命进度 [0,1]（0=诞生 1=消亡）
	var max_life: float   # 最大寿命（秒）
	var size: float       # 当前像素尺寸
	var max_size: float   # 最大像素尺寸
	var seed_x: float     # 初始 x（用于湍流计算）
	var phase: float      # 闪烁相位
	var kind: int         # 0=火焰团(大) 1=火星(小快) 2=烟雾(慢暗)
	func _init(kind_idx: int = 0) -> void:
		kind = kind_idx
		reset()

	func reset() -> void:
		x = randf()
		y = 1.0 + randf() * 0.05  # 从底部边缘稍下方诞生
		seed_x = x
		phase = randf() * TAU
		if kind == 0:
			# 火焰团：中大，中速，寿命中等
			max_life = 1.2 + randf() * 1.0
			max_size = 3.0 + randf() * 4.0
			vy = 0.08 + randf() * 0.06
			vx = (randf() - 0.5) * 0.02
		elif kind == 1:
			# 火星：小，快，寿命长，闪烁
			max_life = 2.0 + randf() * 1.5
			max_size = 1.0 + randf() * 1.5
			vy = 0.12 + randf() * 0.10
			vx = (randf() - 0.5) * 0.04
		else:
			# 烟雾：大，慢，暗，寿命长
			max_life = 2.5 + randf() * 1.5
			max_size = 4.0 + randf() * 5.0
			vy = 0.04 + randf() * 0.03
			vx = (randf() - 0.5) * 0.015
		life = 0.0
		size = max_size * 0.3

# 生成火焰粒子数组（混合三种类型）
static func make_fire_particles(count: int) -> Array:
	var arr: Array = []
	for i in count:
		var kind: int = 0
		var r: float = randf()
		if r < 0.6:
			kind = 0  # 60% 火焰团
		elif r < 0.9:
			kind = 1  # 30% 火星
		else:
			kind = 2  # 10% 烟雾
		arr.append(FireParticle.new(kind))
	return arr

# 根据生命进度计算火焰色温（白热→金→红→烟）
static func _fire_color(p: FireParticle) -> Color:
	var t: float = p.life
	if p.kind == 1:
		# 火星：亮金闪烁
		var c: Color = C_GOLD_BRIGHT
		c.a = (1.0 - t) * (0.7 + 0.3 * sin(p.phase * 3.0))
		return c
	elif p.kind == 2:
		# 烟雾：暗灰褐，渐淡
		var c: Color = Color(0.12, 0.09, 0.07, 1.0)
		c.a = (1.0 - t) * 0.25
		return c
	# 火焰团：色温衰减
	if t < 0.15:
		# 白热核心
		var c := Color(1.0, 0.96, 0.75, 1.0)
		c.a = (t / 0.15) * 0.85
		return c
	elif t < 0.4:
		# 暖金
		var k: float = (t - 0.15) / 0.25
		var c := C_GOLD_BRIGHT.lerp(C_GOLD, k)
		c.a = 0.85 - k * 0.15
		return c
	elif t < 0.7:
		# 战争红
		var k: float = (t - 0.4) / 0.3
		var c := C_GOLD.lerp(C_RED_WAR, k)
		c.a = 0.70 - k * 0.30
		return c
	else:
		# 暗烟消散
		var k: float = (t - 0.7) / 0.3
		var c := C_RED_WAR.lerp(Color(0.10, 0.07, 0.05, 1.0), k)
		c.a = 0.40 * (1.0 - k)
		return c

# 更新火焰粒子物理
static func update_fire_particles(particles: Array, delta: float, time: float) -> void:
	for p in particles:
		var dt: float = delta
		p.life += dt / p.max_life
		if p.life >= 1.0 or p.y < -0.05:
			p.reset()
			continue
		# 浮力加速（越往上越快，模拟热气上升）
		var buoyancy: float = 1.0 + (1.0 - p.y) * 1.5
		p.y -= p.vy * buoyancy * dt
		# 水平湍流（正弦扰动 + 随机漂移）
		var turbulence: float = sin(time * 3.0 + p.phase) * 0.003
		p.x += (p.vx + turbulence) * dt
		# 尺寸：先涨后缩（火焰膨胀再消散）
		if p.life < 0.3:
			p.size = p.max_size * (0.3 + p.life / 0.3 * 0.7)
		else:
			p.size = p.max_size * (1.0 - (p.life - 0.3) / 0.7 * 0.6)

# 绘制火焰粒子（像素风方块）
static func draw_fire_particles(canvas: CanvasItem, particles: Array, w: float, h: float, time: float) -> void:
	for p in particles:
		var px: float = p.x * w
		var py: float = p.y * h
		var c: Color = _fire_color(p)
		if c.a <= 0.01:
			continue
		var s: float = max(1.0, p.size)
		# 火焰团：绘制中心 + 外晕两层，增强体积感
		if p.kind == 0 and s > 2.0:
			var halo: Color = c
			halo.a *= 0.4
			canvas.draw_rect(Rect2(px - s * 0.5, py - s * 0.5, s * 1.8, s * 1.8), halo, true)
		canvas.draw_rect(Rect2(px - s * 0.5, py - s * 0.5, s, s), c, true)

# === 四角像素装饰（战旗角标）===
static func draw_corner_ornaments(canvas: CanvasItem, w: float, h: float) -> void:
	var sz: float = 28.0
	var off: float = 18.0
	var color := C_GOLD_DIM
	color.a = 0.75
	var corners: Array = [
		Vector2(off, off),
		Vector2(w - off - sz, off),
		Vector2(off, h - off - sz),
		Vector2(w - off - sz, h - off - sz),
	]
	for cp in corners:
		# L 形像素边框
		canvas.draw_rect(Rect2(cp.x, cp.y, sz, 4), color, true)
		canvas.draw_rect(Rect2(cp.x, cp.y, 4, sz), color, true)
		# 内侧金色小方块
		canvas.draw_rect(Rect2(cp.x + 7, cp.y + 7, 7, 7), C_GOLD, true)

# === 顶部装饰横条 ===
static func draw_top_banner(canvas: CanvasItem, w: float, y: float = 28.0) -> void:
	# 外框
	canvas.draw_rect(Rect2(0, y - 6, w, 12), Color(0.06, 0.04, 0.03, 1.0), true)
	canvas.draw_rect(Rect2(0, y - 6, w, 12), C_GOLD_DIM, false, 1.0)
	# 中间高光线
	canvas.draw_line(Vector2(w * 0.2, y - 2), Vector2(w * 0.8, y - 2), C_GOLD, 2.0)
	# 两侧像素块
	var block_w: float = 44.0
	canvas.draw_rect(Rect2(w * 0.15, y - 5, block_w, 10), C_DARK, true)
	canvas.draw_rect(Rect2(w * 0.15, y - 5, block_w, 10), C_GOLD_DIM, false, 1.0)
	canvas.draw_rect(Rect2(w * 0.85 - block_w, y - 5, block_w, 10), C_DARK, true)
	canvas.draw_rect(Rect2(w * 0.85 - block_w, y - 5, block_w, 10), C_GOLD_DIM, false, 1.0)

# === 标题呼吸光晕 ===
static func draw_title_glow(canvas: CanvasItem, w: float, h: float, time: float, y_ratio: float = 0.26) -> void:
	var pulse: float = 0.5 + 0.5 * sin(time * 0.8)
	var center_y: float = h * y_ratio
	var glow: Color = C_GOLD
	glow.a = 0.05 + 0.05 * pulse
	var gw: float = w * 0.5
	var gh: float = 80.0 + 20.0 * pulse
	canvas.draw_rect(Rect2((w - gw) * 0.5, center_y - gh * 0.5, gw, gh), glow, true)

# === 底部火光辉光（模拟火源光照，呼吸闪烁）===
static func draw_bottom_fire_glow(canvas: CanvasItem, w: float, h: float, time: float, glow_h_ratio: float = 0.35) -> void:
	# 双层渐变光晕：底层大红光 + 上层金光
	var pulse: float = 0.5 + 0.5 * sin(time * 2.4)
	var pulse2: float = 0.5 + 0.5 * sin(time * 3.7 + 1.0)
	var gh: float = h * glow_h_ratio
	# 底层：战争红大光晕（最宽最暗）
	var c1: Color = C_RED_WAR
	c1.a = 0.10 + 0.06 * pulse
	canvas.draw_rect(Rect2(0, h - gh, w, gh), c1, true)
	# 中层：暖金光晕（中等宽度）
	var gw2: float = w * (0.7 + 0.05 * pulse2)
	var c2: Color = C_GOLD
	c2.a = 0.08 + 0.06 * pulse
	canvas.draw_rect(Rect2((w - gw2) * 0.5, h - gh * 0.75, gw2, gh * 0.75), c2, true)
	# 顶层：亮金核心（最窄最亮，模拟火心）
	var gw3: float = w * (0.4 + 0.04 * pulse2)
	var c3: Color = C_GOLD_BRIGHT
	c3.a = 0.06 + 0.05 * pulse
	canvas.draw_rect(Rect2((w - gw3) * 0.5, h - gh * 0.45, gw3, gh * 0.45), c3, true)
