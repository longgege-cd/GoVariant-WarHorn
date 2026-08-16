# 特效播放器（autoload）
#
# 职责：
#   - 接收 GameSession 事件（通过 GameScreen 转发）并播放视觉/音效
#   - 提供主题无关的特效接口（具体绘制由 BoardView/特效层实现）
#
# 设计：
#   - 不直接监听 GameSession（GameSession 是 per-game 的，且测试时不依赖 Node）
#   - GameScreen 作为编排者，监听 GameSession 信号并调用 EffectsPlayer
#   - 当前 Phase 2 仅打日志，Phase 3 实现具体特效
extends Node

signal effect_started(effect_id: String, payload: Dictionary)
signal effect_finished(effect_id: String)

var enabled: bool = true
var sound_enabled: bool = true

# 提子特效：被提走的棋子位置列表
func play_capture(captured_positions: Array, capturer_color: int) -> void:
	if not enabled:
		return
	Log.d("[特效] 提子 count=%d capturer=%d" % [captured_positions.size(), capturer_color])
	_play_sound("capture")
	effect_started.emit("capture", {
		"positions": captured_positions,
		"capturer_color": capturer_color,
	})
	# 提子波浪特效：在提子点所在行的方格向左右扩散，持续1秒
	effect_started.emit("capture_wave", {
		"positions": captured_positions,
		"capturer_color": capturer_color,
	})

# 弹子特效：撞隐子后弹至周围八格（重叠位置 → 弹子落点）
func play_bounce(overlap_pos: Vector2i, placed_pos: Vector2i, mover_color: int) -> void:
	if not enabled:
		return
	Log.d("[特效] 弹子 from=%s to=%s mover=%d" % [str(overlap_pos), str(placed_pos), mover_color])
	_play_sound("capture")  # 弹子复用提子音
	effect_started.emit("bounce", {
		"overlap_pos": overlap_pos,
		"position": placed_pos,
		"color": mover_color,
	})

# 落子特效（轻量提示）
func play_move(position: Vector2i, color: int) -> void:
	if not enabled:
		return
	_play_sound("place")
	effect_started.emit("move", {
		"position": position,
		"color": color,
	})

# 部署特种部队特效
# position: 部署位置（-1,-1 表示不指定）；仅己方视角/观战下在位置画特效，对方视角下画在棋盘中心避免泄露
func play_special_deploy(color: int, position: Vector2i = Vector2i(-1, -1)) -> void:
	if not enabled:
		return
	Log.d("[特效] 部署特种部队 color=%d pos=%s" % [color, str(position)])
	_play_sound("deploy")
	effect_started.emit("special_deploy", {"color": color, "position": position})

# 隐子暴露特效
func play_reveal(position: Vector2i, reason: String) -> void:
	if not enabled:
		return
	Log.d("[特效] 隐子暴露 pos=%s reason=%s" % [str(position), reason])
	effect_started.emit("reveal", {"position": position, "reason": reason})

# 围困形成特效
func play_siege(stones: Array) -> void:
	if not enabled:
		return
	_play_sound("siege")
	effect_started.emit("siege", {"stones": stones})

# 围困解除特效（做出两眼或突破围困）
func play_siege_broken(stones: Array) -> void:
	if not enabled:
		return
	_play_sound("siege")
	effect_started.emit("siege_broken", {"stones": stones})

# 围空形成特效
func play_territory_formed(points: Array, color: int) -> void:
	if not enabled:
		return
	_play_sound("territory")
	effect_started.emit("territory_formed", {"points": points, "color": color})

# 围空失守特效（被突破或做出两眼）
func play_territory_lost(points: Array, color: int) -> void:
	if not enabled:
		return
	_play_sound("territory")
	effect_started.emit("territory_lost", {"points": points, "color": color})

# 得分浮动文字特效（围空/歼灭/围困 + 扣减）
# text: 显示文字，如 "围空 +4" / "围空 -4"
# position: 棋盘格坐标 Vector2i(col, row)
# color: 显示方颜色 Const.BLACK / Const.WHITE
# popup_type: "territory" | "annihilate" | "siege" | "territory_lost" | "siege_broken"
func play_score_popup(text: String, position: Vector2i, color: int, popup_type: String) -> void:
	if not enabled:
		return
	Log.d("[特效] 得分文字 %s pos=%s color=%d type=%s" % [text, str(position), color, popup_type])
	effect_started.emit("score_popup", {
		"text": text,
		"position": position,
		"color": color,
		"type": popup_type,
	})

# 终局特效
func play_game_end(result: Dictionary) -> void:
	if not enabled:
		return
	Log.d("[特效] 终局 winner=%s" % str(result.get("winner", "")))
	_play_sound("game_end")
	effect_started.emit("game_end", {"result": result})

# 正式开局音效（3.2.1 倒计时结束后由 GameScreen 播放上扬号角；不再发射棋盘动画）
func play_game_open() -> void:
	if not enabled:
		return
	Log.d("[特效] 正式开局号角")
	_play_sound("game_open")

# 布局阶段落子特效（布局落子专属，与正式落子区分）
func play_deploy_place(position: Vector2i, color: int) -> void:
	if not enabled:
		return
	Log.d("[特效] 布局落子 pos=%s color=%d" % [str(position), color])
	_play_sound("deploy_place")
	effect_started.emit("deploy_place", {
		"position": position,
		"color": color,
	})

# 音效播放（委托给 AudioManager）
func play_sound(name: String) -> void:
	_play_sound(name)

# 内部：播放音效（检查开关）
func _play_sound(name: String) -> void:
	if not sound_enabled:
		return
	if AudioManager != null:
		AudioManager.play(name)
