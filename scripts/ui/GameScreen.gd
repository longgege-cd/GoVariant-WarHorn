# 对局场景：编排 GameSession + BoardView + ScorePanel + ControlPanel + HistoryPanel
#
# 职责：
#   - 创建/重置 GameSession
#   - 监听 session 信号，分发给子组件
#   - 处理玩家输入（点击棋盘 → play_move；按钮 → 对应操作）
#   - 管理部署特种模式（点击棋盘 → deploy_special）
#   - 转发事件给 EffectsPlayer
#   - PvE 模式：AI 自动行棋（玩家=黑，AI=白）
#   - ESC 暂停菜单（PauseMenu）
extends Control

const AIManager = preload("res://scripts/ai/AIManager.gd")

signal back_to_main_menu_requested  # 返回主菜单

var session: GameSession
var board_view: Control
var black_score_panel: Panel  # 左侧黑方得分板
var white_score_panel: Panel  # 右侧白方得分板
var control_panel: HBoxContainer
var history_panel: ScrollContainer
var _pause_menu: Control = null  # ESC 暂停菜单实例
var _deploy_mode: bool = false
var _special_enabled: bool = true  # 默认开启特种部队（可在菜单切换）
# PvE 模式
var _pve_mode: bool = false
var _ai_difficulty: int = 0  # AIManager.Difficulty.EASY
var _ai: Variant = null  # AI 实例
var _ai_color: int = Const.WHITE  # AI 执白
var _ai_thinking: bool = false  # AI 正在思考（防止重入）
var _ai_task: Variant = null  # AIManager.AITask 异步任务（思考中）
# 联机模式
var _online_mode: bool = false  # 是否联机对战
# 对局日志（按 L 键查看）：每条记录 {ply, color, passed, deployed, ambush, placed, captures, score_before, score_after}
var _log_entries: Array = []
var _prev_scores: Dictionary = {}  # 上一手之前的分数 {black: int, white: int}，用于计算得分变化
var _log_overlay: Control = null  # 当前的日志覆盖弹窗实例
# 围空/围困变化检测（用于触发特效）
var _prev_enclosures: Array = []  # 上次围空列表
var _prev_sieged_stones: Dictionary = {}  # 上次被围困棋子索引集合 {idx -> true}
# 计时器系统
var _timer: TimerSystem = null
var _time_setting: Dictionary = {}  # 思考时间配置（从 StartMenu 传入）

func _ready() -> void:
	_ensure_avatar_dir()
	_layout()
	_new_game()
	# 联机信号
	NetworkManager.peer_connected.connect(_on_net_peer_connected)
	NetworkManager.peer_disconnected.connect(_on_net_peer_disconnected)
	NetworkManager.connection_failed.connect(_on_net_failed)
	NetworkManager.closed.connect(_on_net_closed)
	NetSync.new_game_requested.connect(_on_net_new_game_requested)
	NetSync.sync_mismatch.connect(_on_net_sync_mismatch)

# 创建玩家头像目录 user://avatars/，玩家可放 black.png / white.png 自定义头像
func _ensure_avatar_dir() -> void:
	var dir := DirAccess.open("user://")
	if dir == null:
		Log.w("无法打开 user:// 目录，头像功能不可用")
		return
	var user_dir: String = OS.get_user_data_dir()
	if not dir.dir_exists("avatars"):
		var err: int = dir.make_dir("avatars")
		if err == OK:
			Log.i("已创建头像目录: %s/avatars/" % user_dir)
		else:
			Log.w("创建 avatars 目录失败 (err=%d)" % err)
	else:
		Log.i("头像目录: %s/avatars/  (放 black.png 或 white.png 自定义头像)" % user_dir)

func _process(_delta: float) -> void:
	# 纯黑背景无需每帧重绘，但需推进计时器
	if _timer != null and session != null and not session.game_over:
		_timer.tick(_delta)

func _exit_tree() -> void:
	# 节点销毁时回收 AI 线程，避免线程泄漏
	if _ai_task != null:
		_ai_task.finish()
		_ai_task = null
	_ai = null
	_ai_thinking = false

func _layout() -> void:
	# 主布局：水平三栏贴边 = [黑方得分板(贴左) | 中间棋盘区(撑满) | 白方得分板(贴右)]
	var root := HBoxContainer.new()
	root.set_anchors_preset(PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)  # 完全贴边无间隙
	add_child(root)

	# 左侧：黑方得分板（固定宽度贴左，垂直撑满）
	black_score_panel = preload("res://scripts/ui/ScorePanel.gd").new()
	black_score_panel.set_side(Const.BLACK)
	black_score_panel.custom_minimum_size = Vector2(260, 0)
	black_score_panel.size_flags_horizontal = SIZE_FILL
	black_score_panel.size_flags_vertical = SIZE_FILL
	root.add_child(black_score_panel)

	# 中间：棋盘 + 状态 + 控制撑满剩余空间，内容紧凑居中
	var center := VBoxContainer.new()
	center.size_flags_horizontal = SIZE_EXPAND_FILL
	center.size_flags_vertical = SIZE_FILL
	center.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_theme_constant_override("separation", 4)
	# 左右内边距让棋盘与得分板有视觉呼吸
	center.offset_left = 12
	center.offset_right = -12
	root.add_child(center)

	# 棋盘（尺寸由 BoardView 根据主题自动设置）
	board_view = preload("res://scripts/ui/BoardView.gd").new()
	board_view.size_flags_horizontal = SIZE_SHRINK_CENTER
	board_view.size_flags_vertical = SIZE_SHRINK_CENTER
	center.add_child(board_view)

	# 底部控制面板（精简：悔棋/虚手/设置）
	control_panel = preload("res://scripts/ui/ControlPanel.gd").new()
	control_panel.size_flags_horizontal = SIZE_SHRINK_CENTER
	center.add_child(control_panel)

	# 右侧：白方得分板（固定宽度贴右，垂直撑满，与黑方对称）
	white_score_panel = preload("res://scripts/ui/ScorePanel.gd").new()
	white_score_panel.set_side(Const.WHITE)
	white_score_panel.custom_minimum_size = Vector2(260, 0)
	white_score_panel.size_flags_horizontal = SIZE_FILL
	white_score_panel.size_flags_vertical = SIZE_FILL
	root.add_child(white_score_panel)

	# 历史面板（加入场景树但隐藏，避免游离节点泄漏；测试会检查非 null）
	history_panel = preload("res://scripts/ui/HistoryPanel.gd").new()
	history_panel.size_flags_vertical = SIZE_EXPAND_FILL
	history_panel.custom_minimum_size = Vector2(220, 200)
	history_panel.visible = false
	add_child(history_panel)

	# 信号连接
	control_panel.pass_pressed.connect(_on_pass)
	control_panel.resign_pressed.connect(_on_resign)
	control_panel.new_game_pressed.connect(_on_new_game)
	control_panel.deploy_special_pressed.connect(_on_deploy_button)
	control_panel.undo_pressed.connect(_on_undo)
	control_panel.cycle_theme_pressed.connect(_on_cycle_theme)
	control_panel.mode_selected.connect(_on_mode_selected)
	control_panel.online_pressed.connect(_on_online_pressed)
	control_panel.online_quit_pressed.connect(_on_online_quit)
	control_panel.menu_pressed.connect(_on_pause_menu)
	board_view.cell_clicked.connect(_on_cell_clicked)
	# 特效连接：EffectsPlayer 信号 → BoardView 叠加层
	EffectsPlayer.effect_started.connect(_on_effect_started)

# ===== ESC 暂停菜单 =====
func _on_pause_menu() -> void:
	if _pause_menu != null:
		return  # 已打开
	# 暂停计时器
	if _timer != null:
		_timer.pause()
	_pause_menu = preload("res://scripts/ui/PauseMenu.gd").new()
	add_child(_pause_menu)
	_pause_menu.set_online_active(_online_mode)
	_pause_menu.resume_requested.connect(_on_pause_resume)
	_pause_menu.new_game_requested.connect(_on_pause_new_game)
	_pause_menu.resign_requested.connect(_on_pause_resign)
	_pause_menu.deploy_special_requested.connect(_on_pause_deploy)
	_pause_menu.mode_selected.connect(_on_pause_mode_selected)
	_pause_menu.online_pressed.connect(_on_pause_online)
	_pause_menu.online_quit_pressed.connect(_on_pause_online_quit)
	_pause_menu.theme_cycle_requested.connect(_on_cycle_theme)
	_pause_menu.back_to_main_menu_requested.connect(_on_pause_back_to_main)
	_pause_menu.quit_requested.connect(_on_pause_quit)

func _on_pause_resign() -> void:
	_on_pause_resume()
	_on_resign()

func _on_pause_deploy() -> void:
	_on_pause_resume()
	_on_deploy_button()

func _on_pause_mode_selected(mode: String, difficulty: int) -> void:
	_on_pause_resume()
	_on_mode_selected(mode, difficulty)

func _on_pause_online() -> void:
	_on_pause_resume()
	_on_online_pressed()

func _on_pause_online_quit() -> void:
	_on_pause_resume()
	_on_online_quit()

func _on_pause_resume() -> void:
	if _pause_menu:
		_pause_menu.queue_free()
		_pause_menu = null
	# 恢复计时器
	if _timer != null:
		_timer.resume()

func _on_pause_new_game() -> void:
	_on_pause_resume()
	_on_new_game()

func _on_pause_back_to_main() -> void:
	_on_pause_resume()
	# 清理联机/PvE 状态
	if _online_mode:
		stop_online()
	if _pve_mode:
		stop_pve()
	back_to_main_menu_requested.emit()

func _on_pause_quit() -> void:
	get_tree().quit()

# 联机按钮处理
func _on_online_pressed() -> void:
	var menu := preload("res://scripts/ui/NetworkMenu.gd").new()
	add_child(menu)
	menu.host_requested.connect(_on_online_host)
	menu.join_requested.connect(_on_online_join)
	menu.popup_centered()

func _on_online_quit() -> void:
	stop_online()
	control_panel.update_online_state(false)

func _on_online_host(port: int) -> void:
	if start_online_host(port):
		control_panel.update_online_state(true)

func _on_online_join(ip: String, port: int) -> void:
	if start_online_client(ip, port):
		control_panel.update_online_state(true)

# 模式选择处理
func _on_mode_selected(mode: String, difficulty: int) -> void:
	if mode == "pve":
		start_pve(difficulty)
	else:
		stop_pve()

func _new_game() -> void:
	session = GameSession.new(Const.KOMI_DEFAULT, _special_enabled)
	board_view.set_session(session)
	black_score_panel.set_session(session)
	white_score_panel.set_session(session)
	session.move_committed.connect(_on_move_committed)
	session.scores_changed.connect(_on_scores_changed)
	session.game_ended.connect(_on_game_ended)
	# 同步 session 引用到 NetSync（联机用）
	NetSync.session = session
	NetSync.active = _online_mode
	_update_status()
	_update_controls()
	_update_role_names()
	# 重置对局日志 + 分数快照
	_log_entries.clear()
	var init_sc: Dictionary = session.scores()
	_prev_scores = {
		"black": init_sc.black.total(),
		"white": init_sc.white.total(),
	}
	# 重置围空/围困状态
	_prev_enclosures = session.cached_enclosures().duplicate(true)
	_prev_sieged_stones = _collect_sieged_stones()
	# 初始化计时器（若配置了思考时间）
	if _time_setting.is_empty():
		_time_setting = {"main": -1.0, "byoyomi": 0, "byoyomi_duration": 0.0}
	_timer = TimerSystem.new()
	var timer_cfg: Dictionary = {
		Const.BLACK: _time_setting,
		Const.WHITE: _time_setting,
	}
	_timer.reset(timer_cfg)
	_timer.time_out.connect(_on_time_out)
	_timer.switch_to(session.to_move)
	# 给得分板注入计时器引用（环形计时条）
	if black_score_panel != null:
		black_score_panel.set_timer(_timer)
	if white_score_panel != null:
		white_score_panel.set_timer(_timer)
	# 刷新头像（玩家可能在新对局前替换了头像文件）
	if black_score_panel != null and black_score_panel.has_method("reload_avatar"):
		black_score_panel.reload_avatar()
	if white_score_panel != null and white_score_panel.has_method("reload_avatar"):
		white_score_panel.reload_avatar()

# 根据当前模式（PvP/PvE/联机）更新得分板角色名
#   PvP     → 黑方 / 白方
#   PvE     → 你 / AI·难度
#   联机    → 你 / 对手（按本地颜色分配）
func _update_role_names() -> void:
	if black_score_panel == null or white_score_panel == null:
		return
	if _pve_mode:
		# PvE: 玩家执黑=你，AI执白=AI·难度
		black_score_panel.set_role_name("你")
		white_score_panel.set_role_name("AI·" + AIManager.difficulty_name(_ai_difficulty))
	elif _online_mode:
		# 联机: 本地颜色方=你，对端=对手
		var local_c: int = NetworkManager.local_color
		if local_c == Const.BLACK:
			black_score_panel.set_role_name("你")
			white_score_panel.set_role_name("对手")
		else:
			black_score_panel.set_role_name("对手")
			white_score_panel.set_role_name("你")
	else:
		# PvP: 默认黑方/白方
		black_score_panel.set_role_name("")
		white_score_panel.set_role_name("")

func _on_new_game() -> void:
	_deploy_mode = false
	if board_view != null:
		board_view.set_deploy_mode(false)
	if _online_mode and NetworkManager.is_host():
		# 联机主机：本地新建 + 广播配置给客户端
		_new_game()
		NetSync.host_broadcast_new_game(Const.KOMI_DEFAULT, _special_enabled)
	elif _online_mode and not NetworkManager.is_host():
		# 联机客户端：新对局由主机发起，客户端等待广播
		_show_status("等待主机开始新对局…")
	else:
		_new_game()

func _on_pass() -> void:
	if _online_mode:
		# 联机：仅本地玩家轮次可操作，通过 NetSync 路由
		if session.to_move != NetworkManager.local_color:
			_show_error("非您的回合")
			return
		var out: Dictionary = NetSync.local_do_pass()
		if not out.ok:
			_show_error(out.reason)
		return
	var out: Dictionary = session.do_pass(session.to_move)
	if not out.ok:
		_show_error(out.reason)

func _on_resign() -> void:
	if _online_mode:
		# 联机认输：通知对端
		NetSync.local_resign()
	# 本地认输处理（联机与非联机统一）
	var loser: int = NetworkManager.local_color if _online_mode else session.to_move
	var winner_str: String = "白方胜" if loser == Const.BLACK else "黑方胜"
	session.game_over = true
	var result: Dictionary = session.final_result("认输")
	result["winner"] = winner_str
	result["reason"] = "%s认输" % ("黑方" if loser == Const.BLACK else "白方")
	session.game_ended.emit(result)
	_update_status()
	_update_controls()

func _on_deploy_button() -> void:
	if _online_mode and session.to_move != NetworkManager.local_color:
		_show_error("非您的回合")
		return
	_deploy_mode = not _deploy_mode
	if board_view != null:
		board_view.set_deploy_mode(_deploy_mode)
	_update_controls()
	if _deploy_mode:
		_show_status("选择部署特种部队的位置（点击棋盘）")
	else:
		_show_status("已取消部署")

func _on_undo() -> void:
	# 联机模式禁用悔棋（防止状态不一致）
	if _online_mode:
		_show_status("联机模式不支持悔棋")
		return
	_show_status("悔棋功能待实现")

func _on_cycle_theme() -> void:
	ThemeManager.cycle_next()

func _on_cell_clicked(row: int, col: int) -> void:
	if session.game_over:
		return
	# PvE 模式：AI 思考中或非玩家回合时禁止操作
	if _pve_mode and (_ai_thinking or session.to_move != Const.BLACK):
		return
	# 联机模式：仅本地玩家轮次可操作
	if _online_mode and session.to_move != NetworkManager.local_color:
		_show_error("非您的回合")
		return
	if _deploy_mode:
		if _online_mode:
			# 联机部署：通过 NetSync 路由
			var out: Dictionary = NetSync.local_deploy_special(row, col)
			if out.ok:
				_deploy_mode = false
				if board_view != null:
					board_view.set_deploy_mode(false)
			else:
				_show_error(out.reason)
			_update_controls()
			return
		var out: Dictionary = session.deploy_special(session.to_move, row, col)
		if out.ok:
			_deploy_mode = false
			if board_view != null:
				board_view.set_deploy_mode(false)
		else:
			_show_error(out.reason)
		_update_controls()
		return
	if _online_mode:
		# 联机落子：通过 NetSync 路由（本地执行 + RPC 同步）
		var out: Dictionary = NetSync.local_play_move(row, col)
		if not out.ok:
			_show_error(out.reason)
		return
	var out: Dictionary = session.play_move(session.to_move, row, col)
	if not out.ok:
		_show_error(out.reason)

func _on_move_committed(outcome: Dictionary) -> void:
	board_view.on_move_committed(outcome)
	# 记录对局日志（在分数已更新后取 after）
	_record_log_entry(outcome)
	# 特效触发（mover_color 已存入 outcome，避免依赖 session.to_move 已切换）
	var mover_color: int = outcome.get("mover_color", session.to_move)
	if outcome.get("ambush", false):
		EffectsPlayer.play_ambush(outcome.placed, mover_color)
	if outcome.captures.size() > 0:
		EffectsPlayer.play_capture(outcome.captures, outcome.captured_color)
	if outcome.get("deployed", false):
		EffectsPlayer.play_special_deploy(mover_color)
	if outcome.placed is Vector2i and outcome.placed.x >= 0 and not outcome.ambush:
		EffectsPlayer.play_move(outcome.placed, mover_color)
	for r in outcome.get("revealed", []):
		EffectsPlayer.play_reveal(r.pos, r.get("revealed_reason", ""))
	# 围空/围困变化检测 → 触发特效
	_detect_and_trigger_territory_siege()
	_update_status()
	_update_controls()
	# 计时器切换到新行棋方；行棋成功重置该方连续超时计数
	if _timer != null and not session.game_over:
		_timer.reset_timeout_count(mover_color)
		_timer.switch_to(session.to_move)
	# PvE：轮到 AI 时自动行棋
	_maybe_trigger_ai()

# 单次超时：执行 pass（不直接判负）
# 联机模式：本地超时也需通过 NetSync 同步 pass
func _on_timeout_pass(color: int) -> void:
	if session == null or session.game_over:
		return
	_show_status("%s超时（自动虚手 %d/3）" % [("黑方" if color == Const.BLACK else "白方"), _timer.get_timeout_count(color)])
	if _online_mode:
		# 联机：仅本地玩家超时可执行 pass
		if color != NetworkManager.local_color:
			return
		var out: Dictionary = NetSync.local_do_pass()
		if not out.ok:
			Log.w("超时 pass 失败: %s" % out.get("reason", ""))
		return
	var out: Dictionary = session.do_pass(color)
	if not out.ok:
		Log.w("超时 pass 失败: %s" % out.get("reason", ""))

# 计时器连续3次超时：判超时方负
func _on_time_out(color: int) -> void:
	if session == null or session.game_over:
		return
	var winner_str: String = "白方胜" if color == Const.BLACK else "黑方胜"
	var loser_str: String = "黑方" if color == Const.BLACK else "白方"
	session.game_over = true
	var result: Dictionary = session.final_result("连续超时")
	result["winner"] = winner_str
	result["reason"] = "%s连续3次超时" % loser_str
	session.game_ended.emit(result)
	_update_status()
	_update_controls()

# 追加一条对局日志：组合 outcome 动作信息 + 前后总分差
func _record_log_entry(outcome: Dictionary) -> void:
	if session == null:
		return
	var mover_color: int = outcome.get("mover_color", session.to_move)
	var key: String = "black" if mover_color == Const.BLACK else "white"
	var before: int = int(_prev_scores.get(key, 0))
	var sc: Dictionary = session.scores()
	var after_bk = sc.black if mover_color == Const.BLACK else sc.white
	var after: int = after_bk.total()
	var cap_count: int = 0
	if outcome.has("captures") and outcome.captures is Array:
		cap_count = outcome.captures.size()
	_log_entries.append({
		"ply": outcome.get("ply", session.ply),
		"color": mover_color,
		"passed": outcome.get("passed", false),
		"deployed": outcome.get("deployed", false),
		"ambush": outcome.get("ambush", false),
		"placed": outcome.get("placed", Vector2i(-1, -1)),
		"captures": cap_count,
		"score_before": before,
		"score_after": after,
	})
	_prev_scores[key] = after

# 获取当前角色名映射 {Const.BLACK: name, Const.WHITE: name}，供日志弹窗显示
func _get_role_names() -> Dictionary:
	if _pve_mode:
		return {Const.BLACK: "你", Const.WHITE: "AI·" + AIManager.difficulty_name(_ai_difficulty)}
	elif _online_mode:
		var local_c: int = NetworkManager.local_color
		if local_c == Const.BLACK:
			return {Const.BLACK: "你", Const.WHITE: "对手"}
		else:
			return {Const.BLACK: "对手", Const.WHITE: "你"}
	return {Const.BLACK: "黑方", Const.WHITE: "白方"}

# 切换对局日志覆盖弹窗（L 键）
func _toggle_log_overlay() -> void:
	if _log_overlay != null and is_instance_valid(_log_overlay):
		_log_overlay.queue_free()
		_log_overlay = null
		return
	_log_overlay = preload("res://scripts/ui/GameLogOverlay.gd").create(_log_entries.duplicate(true), _get_role_names())
	add_child(_log_overlay)
	_log_overlay.dismissed.connect(func(): _log_overlay = null)

# ===== 围空/围困变化检测 =====

# 收集当前所有被围困棋子的索引集合 {idx -> true}
func _collect_sieged_stones() -> Dictionary:
	if session == null:
		return {}
	var out: Dictionary = {}
	for g in session.cached_sieged_groups():
		for s in g.stones:
			out[s.y * Const.BOARD_SIZE + s.x] = true
	return out

# 检测围空/围困变化并触发特效
#   围空：新增 → play_territory_formed（新点）；扩展 → play_territory_formed（增量点）；
#         失守 → play_territory_lost（消失点）；收缩 → play_territory_lost（失去点）
#   围困：新增 → play_siege；解除 → play_siege_broken
func _detect_and_trigger_territory_siege() -> void:
	if session == null:
		return
	var BS: int = Const.BOARD_SIZE
	# 1. 围空变化检测（按 color 匹配前后围空，对比点集差异）
	var curr_encs: Array = session.cached_enclosures()
	# 建立 prev 按 color 分组的点集索引
	var prev_by_color: Dictionary = {}  # color -> Array[Dictionary{points_set, points}]
	for prev in _prev_enclosures:
		var c: int = prev.color
		if not prev_by_color.has(c):
			prev_by_color[c] = []
		var pset: Dictionary = {}
		for p in prev.get("points", []):
			pset[p.y * BS + p.x] = true
		prev_by_color[c].append({"set": pset, "points": prev.get("points", [])})
	# 当前每个围空：找 prev 中同色且重叠最大的，计算新增点
	var matched_prev_idx: Dictionary = {}  # color -> {prev_index -> true} 已匹配
	for curr in curr_encs:
		var c: int = curr.color
		var curr_pts: Array = curr.get("points", [])
		var curr_set: Dictionary = {}
		for p in curr_pts:
			curr_set[p.y * BS + p.x] = true
		# 找同色 prev 中重叠最多的
		var best_idx: int = -1
		var best_overlap: int = 0
		var prev_list: Array = prev_by_color.get(c, [])
		for i in prev_list.size():
			if matched_prev_idx.has(c) and matched_prev_idx[c].has(i):
				continue
			var ov: int = 0
			for p in curr_pts:
				if prev_list[i].set.has(p.y * BS + p.x):
					ov += 1
			if ov > best_overlap:
				best_overlap = ov
				best_idx = i
		if best_idx >= 0:
			# 匹配到 prev：计算新增点（扩展）
			var new_pts: Array = []
			for p in curr_pts:
				if not prev_list[best_idx].set.has(p.y * BS + p.x):
					new_pts.append(p)
			if not new_pts.is_empty():
				EffectsPlayer.play_territory_formed(new_pts, c)
			if matched_prev_idx.has(c):
				matched_prev_idx[c][best_idx] = true
			else:
				matched_prev_idx[c] = {best_idx: true}
		else:
			# 全新围空：所有点都触发特效
			if not curr_pts.is_empty():
				EffectsPlayer.play_territory_formed(curr_pts, c)
	# 未匹配的 prev 围空 → 失守（消失或部分失去）
	for c in prev_by_color.keys():
		var prev_list: Array = prev_by_color[c]
		var matched: Dictionary = matched_prev_idx.get(c, {})
		for i in prev_list.size():
			if matched.has(i):
				continue
			# 整个围空失守
			var lost_pts: Array = prev_list[i].points
			if not lost_pts.is_empty():
				EffectsPlayer.play_territory_lost(lost_pts, c)
	_prev_enclosures = curr_encs.duplicate(true)
	# 2. 围困变化检测
	var curr_sieged: Dictionary = _collect_sieged_stones()
	var new_sieged: Array = []
	var broken_sieged: Array = []
	for idx in curr_sieged:
		if not _prev_sieged_stones.has(idx):
			var row: int = idx / BS
			var col: int = idx % BS
			new_sieged.append(Vector2i(col, row))
	for idx in _prev_sieged_stones:
		if not curr_sieged.has(idx):
			var row: int = idx / BS
			var col: int = idx % BS
			broken_sieged.append(Vector2i(col, row))
	if not new_sieged.is_empty():
		EffectsPlayer.play_siege(new_sieged)
	if not broken_sieged.is_empty():
		EffectsPlayer.play_siege_broken(broken_sieged)
	_prev_sieged_stones = curr_sieged

# ===== PvE 模式 =====
# 启动 PvE 模式：玩家执黑，AI 执白
func start_pve(difficulty: int) -> void:
	_pve_mode = true
	_ai_difficulty = difficulty
	_ai_color = Const.WHITE
	_ai = AIManager.create(difficulty, _ai_color)
	_ai_thinking = false
	_new_game()
	Log.i("PvE 模式启动：难度=%s" % AIManager.difficulty_name(difficulty))

# 退出 PvE 模式（切回 PvP）
func stop_pve() -> void:
	_pve_mode = false
	_ai = null
	_ai_thinking = false
	_set_ai_thinking(false)
	# 回收可能仍在运行的 AI 线程，避免泄漏
	if _ai_task != null:
		_ai_task.finish()
		_ai_task = null
	_new_game()

func _maybe_trigger_ai() -> void:
	if not _pve_mode or _ai == null or _ai_thinking:
		return
	if session.game_over:
		return
	if session.to_move != _ai_color:
		return
	_ai_thinking = true
	# AI 思考状态显示在对应得分板
	_set_ai_thinking(true)
	# 异步触发，让 UI 先刷新一帧并显示"思考中"
	call_deferred("_ai_play")

# 统一设置 AI 思考状态（同步更新得分板提示）
func _set_ai_thinking(t: bool) -> void:
	var panel: Panel = white_score_panel if _ai_color == Const.WHITE else black_score_panel
	if panel != null and panel.has_method("set_thinking"):
		panel.set_thinking(t)

func _ai_play() -> void:
	if _ai == null or session == null or session.game_over:
		_ai_thinking = false
		_set_ai_thinking(false)
		return
	if session.to_move != _ai_color:
		_ai_thinking = false
		_set_ai_thinking(false)
		return
	# 最小思考时间 0.3s（让玩家看到"思考中"提示与自己落子）
	await get_tree().create_timer(0.3).timeout
	# 等待期间可能已终局/退出 PvE
	if _ai == null or session == null or session.game_over:
		_ai_thinking = false
		_set_ai_thinking(false)
		return
	if session.to_move != _ai_color:
		_ai_thinking = false
		_set_ai_thinking(false)
		return
	# 异步计算：后台线程跑 choose_move，主线程 await 等待（不卡 UI）
	_ai_task = AIManager.create_task(session, _ai)
	_ai_task.start()
	# 等待线程完成（每帧 yield，UI 保持响应）
	while _ai_task.is_running():
		await get_tree().process_frame
		# 等待期间可能已终局/退出 PvE
		if _ai == null or session == null or session.game_over:
			_ai_task.finish()  # 回收线程
			_ai_task = null
			_ai_thinking = false
			_set_ai_thinking(false)
			return
	var move: Dictionary = _ai_task.finish()
	_ai_task = null
	# 等待期间状态可能变化，再次校验
	if _ai == null or session == null or session.game_over:
		_ai_thinking = false
		_set_ai_thinking(false)
		return
	if session.to_move != _ai_color:
		_ai_thinking = false
		_set_ai_thinking(false)
		return
	# 应用 AI move 到 session
	var color: int = _ai_color
	var out: Dictionary
	match move.get("type", "pass"):
		"move":
			out = session.play_move(color, move.row, move.col)
		"deploy":
			out = session.deploy_special(color, move.row, move.col)
		_:
			out = session.do_pass(color)
	_ai_thinking = false
	_set_ai_thinking(false)
	if not out.ok:
		Log.w("AI 行棋非法: %s" % out.get("reason", ""))
		_update_status()

func _on_scores_changed(scores: Dictionary) -> void:
	black_score_panel.on_scores_changed(scores)
	white_score_panel.on_scores_changed(scores)

# 特效信号处理：转发到 BoardView 叠加层
func _on_effect_started(effect_id: String, payload: Dictionary) -> void:
	var overlay: Dictionary = {"type": effect_id, "duration": _effect_duration(effect_id)}
	# 合并 payload 字段到 overlay（便于 BoardView 直接读取）
	for key in payload:
		overlay[key] = payload[key]
	board_view.add_effect_overlay(overlay)

func _effect_duration(effect_id: String) -> float:
	match effect_id:
		"capture":
			return 0.9
		"ambush":
			return 0.6
		"move":
			return 0.4
		"special_deploy":
			return 0.7
		"reveal":
			return 0.5
		"territory_formed":
			return 1.0
		"siege":
			return 0.8
		"game_end":
			return 1.5
		_:
			return 0.5

func _on_game_ended(result: Dictionary) -> void:
	EffectsPlayer.play_game_end(result)
	# 弹出终局结果浮层
	var overlay := preload("res://scripts/ui/ResultOverlay.gd").create(result)
	add_child(overlay)
	overlay.new_game_requested.connect(_on_new_game)
	overlay.back_to_main_menu_requested.connect(_on_pause_back_to_main)
	_update_controls()

func _update_status() -> void:
	# 文字状态栏已移除，行棋方由得分板高亮指示
	pass

func _show_status(_msg: String) -> void:
	pass

func _show_error(_msg: String) -> void:
	# 棋盘边框红色闪烁反馈
	if board_view != null:
		board_view.flash_error()

func _update_controls() -> void:
	control_panel.update_state(session, _deploy_mode)

# ===== 键盘快捷键 =====
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_ESCAPE:
				if _pause_menu != null:
					_on_pause_resume()
				else:
					_on_pause_menu()
				get_viewport().set_input_as_handled()
			KEY_P:
				_on_pass()
			KEY_S:
				_on_deploy_button()
			KEY_U:
				_on_undo()
			KEY_T:
				_on_cycle_theme()
			KEY_L:
				_toggle_log_overlay()
				get_viewport().set_input_as_handled()
			KEY_N:
				if event.ctrl_pressed:
					_on_new_game()

# ===== 联机模式 =====
# 作为主机启动联机对战
func start_online_host(port: int) -> bool:
	_stop_pve_and_ai()
	var ok: bool = NetworkManager.host_game(port)
	if not ok:
		_show_status("建主失败（端口 %d 可能被占用）" % port)
		return false
	_online_mode = true
	# 主机执黑，等待客户端加入
	_new_game()
	_show_status("已建主（端口 %d），等待对手加入…" % port)
	return true

# 作为客户端加入联机对战
func start_online_client(ip: String, port: int) -> bool:
	_stop_pve_and_ai()
	var ok: bool = NetworkManager.join_game(ip, port)
	if not ok:
		_show_status("加入失败，请检查 IP/端口")
		return false
	_online_mode = true
	_update_role_names()
	_show_status("正在连接 %s:%d…" % [ip, port])
	return true

# 退出联机模式
func stop_online() -> void:
	_online_mode = false
	NetSync.active = false
	NetSync.session = null
	NetworkManager.close()
	_new_game()
	_show_status("已退出联机模式")

func _stop_pve_and_ai() -> void:
	if _pve_mode:
		stop_pve()

# 联机信号处理
func _on_net_peer_connected(peer_id: int) -> void:
	# 对手已连接，开始对局
	_new_game()
	var my_str: String = "黑方(主机)" if NetworkManager.is_host() else "白方(客户端)"
	_show_status("对手已加入！您执%s · 第 1 手" % my_str)

func _on_net_peer_disconnected(_peer_id: int) -> void:
	_show_status("对手已断开连接")
	_online_mode = false
	NetSync.active = false
	control_panel.update_online_state(false)

func _on_net_failed() -> void:
	_show_status("连接失败")
	_online_mode = false
	NetSync.active = false
	control_panel.update_online_state(false)

func _on_net_closed() -> void:
	if _online_mode:
		_show_status("连接已关闭")
		_online_mode = false
		NetSync.active = false
		control_panel.update_online_state(false)

func _on_net_new_game_requested(komi: float, special_enabled: bool) -> void:
	# 客户端收到主机的新对局配置
	_special_enabled = special_enabled
	_new_game()
	_show_status("新对局开始（贴目 %.1f）· 您执白方" % komi)

func _on_net_sync_mismatch() -> void:
	_show_status("状态同步异常，请双方重新开始对局")
	Log.w("联机状态同步异常")

# ===== 启动配置（由 Main 调用）=====
# 注：_ready() 已用默认空配置初始化 timer，此处需用真实 time_setting 重置 timer
func setup_game(mode: String, difficulty: int, time_setting: Dictionary = {}) -> void:
	_time_setting = time_setting
	# 用真实配置重置计时器（覆盖 _ready 中默认的无限时间）
	_reinit_timer()
	match mode:
		"pve":
			start_pve(difficulty)
		"online":
			# 联机模式：自动打开联机菜单供玩家选择主机/加入
			call_deferred("_on_online_pressed")
		_:
			# 本地双人模式，无需额外设置
			pass

# 用当前 _time_setting 重新初始化计时器（不重新建 GameSession）
func _reinit_timer() -> void:
	if _time_setting.is_empty():
		_time_setting = {"main": -1.0, "byoyomi": 0, "byoyomi_duration": 0.0}
	# 旧 timer 断开所有信号，避免重复连接
	if _timer != null:
		if _timer.time_out.is_connected(_on_time_out):
			_timer.time_out.disconnect(_on_time_out)
		if _timer.timeout_pass.is_connected(_on_timeout_pass):
			_timer.timeout_pass.disconnect(_on_timeout_pass)
	_timer = TimerSystem.new()
	var timer_cfg: Dictionary = {
		Const.BLACK: _time_setting,
		Const.WHITE: _time_setting,
	}
	_timer.reset(timer_cfg)
	_timer.time_out.connect(_on_time_out)
	_timer.timeout_pass.connect(_on_timeout_pass)
	if session != null:
		_timer.switch_to(session.to_move)
	# 重新注入得分板
	if black_score_panel != null:
		black_score_panel.set_timer(_timer)
	if white_score_panel != null:
		white_score_panel.set_timer(_timer)

# 绘制全局背景（纯黑）
func _draw() -> void:
	var w: float = size.x
	var h: float = size.y
	if w <= 0 or h <= 0:
		return
	draw_rect(Rect2(0, 0, w, h), Color.BLACK, true)
