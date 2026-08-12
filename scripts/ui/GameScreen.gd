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
var black_score_panel: Panel  # 左侧黑方得分板（含得分日志）
var white_score_panel: Panel  # 右侧白方得分板（含得分日志）
var control_panel: HBoxContainer
var history_panel: ScrollContainer
var _pause_menu: Control = null  # ESC 暂停菜单实例
var _deploy_mode: bool = false
var _special_enabled: bool = true  # 默认开启特种部队（可在菜单切换）
var _komi: float = Const.KOMI_DEFAULT  # 贴目（由 StartMenu 传入）
var _piece_limit: int = Const.PIECE_LIMIT  # 每方兵力上限（由 StartMenu 传入）
# PvE 模式
var _pve_mode: bool = false
var _ai_difficulty: int = 0  # AIManager.Difficulty.EASY
var _ai: Variant = null  # AI 实例
var _ai_color: int = Const.WHITE  # AI 执白
var _ai_thinking: bool = false  # AI 正在思考（防止重入）
var _ai_task: Variant = null  # AIManager.AITask 异步任务（思考中）
# 联机模式
var _online_mode: bool = false  # 是否联机对战
# 对局日志（按 L 键查看）：每条记录 {ply, color, passed, deployed, bounced, placed, captures, score_before, score_after}
var _log_entries: Array = []
var _prev_scores: Dictionary = {}  # 上一手之前的分数 {black: int, white: int}，用于计算得分变化
var _log_overlay: Control = null  # 当前的日志覆盖弹窗实例
# 围空/围困变化检测（用于触发特效）
var _prev_enclosures: Array = []  # 上次围空列表
var _prev_sieged_stones: Dictionary = {}  # 上次被围困棋子索引集合 {idx -> true}
# 计时器系统
var _timer: TimerSystem = null
var _time_setting: Dictionary = {}  # 思考时间配置（从 StartMenu 传入）
# 房间模式：对话框实例引用
var _room_host_dlg: AcceptDialog = null  # 主机房间设置对话框
var _room_list_dlg: AcceptDialog = null  # 客户端房间列表对话框
var _room_wait_dlg: AcceptDialog = null  # 主机等待对手对话框
# 联机/PvE 状态提示条（在棋盘与控制面板之间显示）
var _status_label: Label = null

func _ready() -> void:
	_ensure_avatar_dir()
	_layout()
	_new_game()
	# 联机信号（权威主机模型）
	NetworkManager.player_joined.connect(_on_net_peer_joined)
	NetworkManager.player_disconnected.connect(_on_net_peer_disconnected)
	NetworkManager.connection_failed.connect(_on_net_failed)
	NetworkManager.closed.connect(_on_net_closed)
	NetSync.new_game_requested.connect(_on_net_new_game_requested)
	NetSync.sync_mismatch.connect(_on_net_sync_mismatch)
	NetSync.game_started.connect(_on_net_game_started)
	NetworkManager.joined.connect(_on_net_joined)

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
	# 清理房间对话框
	for dlg in [_room_host_dlg, _room_list_dlg, _room_wait_dlg]:
		if dlg != null and is_instance_valid(dlg):
			dlg.queue_free()
	_room_host_dlg = null
	_room_list_dlg = null
	_room_wait_dlg = null
	# 停止房间发现
	RoomDiscovery.stop_broadcasting()
	RoomDiscovery.stop_listening()

func _layout() -> void:
	# 主布局：水平三栏贴边 = [黑方得分板(贴左) | 中间棋盘区(撑满) | 白方得分板(贴右)]
	var root := HBoxContainer.new()
	root.set_anchors_preset(PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)  # 完全贴边无间隙
	add_child(root)

	# 左侧：黑方得分板（含得分日志，撑满垂直）
	black_score_panel = preload("res://scripts/ui/ScorePanel.gd").new()
	black_score_panel.set_side(Const.BLACK)
	black_score_panel.custom_minimum_size = Vector2(260, 0)
	black_score_panel.size_flags_horizontal = SIZE_FILL
	black_score_panel.size_flags_vertical = SIZE_EXPAND_FILL
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

	# 状态提示条（联机/PvE 时显示）
	_status_label = Label.new()
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 13)
	_status_label.add_theme_color_override("font_color", preload("res://scripts/ui/UITheme.gd").C_GOLD)
	_status_label.visible = false
	center.add_child(_status_label)

	# 底部控制面板（精简：悔棋/虚手/设置）
	control_panel = preload("res://scripts/ui/ControlPanel.gd").new()
	control_panel.size_flags_horizontal = SIZE_SHRINK_CENTER
	center.add_child(control_panel)

	# 右侧：白方得分板（含得分日志，撑满垂直，与黑方对称）
	white_score_panel = preload("res://scripts/ui/ScorePanel.gd").new()
	white_score_panel.set_side(Const.WHITE)
	white_score_panel.custom_minimum_size = Vector2(260, 0)
	white_score_panel.size_flags_horizontal = SIZE_FILL
	white_score_panel.size_flags_vertical = SIZE_EXPAND_FILL
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
	# 双方得分板的部署按钮（部署特种部队的入口已迁移至得分板）
	black_score_panel.deploy_special_pressed.connect(_on_deploy_button)
	white_score_panel.deploy_special_pressed.connect(_on_deploy_button)
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
	# 清理联机状态：即使 _online_mode=false，NetworkManager 可能仍 HOSTING（如对手断开后）
	if _online_mode or not NetworkManager.is_offline():
		stop_online()
	if _pve_mode:
		stop_pve()
	back_to_main_menu_requested.emit()

func _on_pause_quit() -> void:
	get_tree().quit()

# 联机按钮处理：弹出联机入口菜单
func _on_online_pressed() -> void:
	var menu := preload("res://scripts/ui/NetworkMenu.gd").new()
	add_child(menu)
	menu.host_requested.connect(_on_online_host_entry)
	menu.join_requested.connect(_on_online_join_entry)
	menu.popup_centered()

func _on_online_quit() -> void:
	stop_online()
	control_panel.update_online_state(false)

# 玩家A选择「建立房间」→ 弹出房间设置对话框
func _on_online_host_entry() -> void:
	if _room_host_dlg != null:
		return
	# 等待 NetworkMenu 销毁，避免两个 AcceptDialog 争抢 exclusive child
	await get_tree().process_frame
	_room_host_dlg = preload("res://scripts/ui/RoomHostDialog.gd").new()
	add_child(_room_host_dlg)
	_room_host_dlg.room_created.connect(_on_room_created)
	_room_host_dlg.canceled.connect(_on_room_host_canceled)
	_room_host_dlg.popup_centered()

# 玩家A取消房间设置
func _on_room_host_canceled() -> void:
	if _room_host_dlg != null:
		_room_host_dlg.queue_free()
		_room_host_dlg = null

# 玩家A确认建立房间 → 建主 + 启动广播 + 弹出等待对话框
func _on_room_created(time_setting: Dictionary, piece_limit: int, komi: float) -> void:
	var port: int = _room_host_dlg.get_port()
	if _room_host_dlg != null:
		_room_host_dlg.queue_free()
		_room_host_dlg = null
	# 保存房间设定
	_time_setting = time_setting
	_piece_limit = piece_limit
	_komi = komi
	if not start_online_host(port):
		return
	# 启动 UDP 广播房间信息
	var room_info: Dictionary = {
		"ip": _get_local_ip(),
		"port": port,
		"time_setting": time_setting,
		"piece_limit": piece_limit,
		"komi": komi,
	}
	RoomDiscovery.start_broadcasting(room_info)
	if not RoomDiscovery.is_broadcasting():
		# 广播失败（5006 端口被占用）：房间无法被其他玩家发现
		_show_error("房间广播失败（端口 5006 可能被占用），对手可能搜索不到您的房间")
	# 等待 RoomHostDialog 销毁，避免两个 AcceptDialog 争抢 exclusive child
	await get_tree().process_frame
	# 弹出等待对手对话框
	_room_wait_dlg = preload("res://scripts/ui/RoomWaitDialog.gd").new()
	add_child(_room_wait_dlg)
	_room_wait_dlg.start_requested.connect(_on_room_start_requested)
	_room_wait_dlg.canceled.connect(_on_room_wait_canceled)
	_room_wait_dlg.popup_centered()
	# 注：不在此处提前 set_peer_joined(true)，仅依赖 peer_joined 信号驱动状态
	_show_status("已创建房间（端口 %d），等待对手加入…" % port)

# 玩家B选择「加入房间」→ 弹出房间列表对话框
func _on_online_join_entry() -> void:
	if _room_list_dlg != null:
		return
	# 等待 NetworkMenu 销毁，避免两个 AcceptDialog 争抢 exclusive child
	await get_tree().process_frame
	_room_list_dlg = preload("res://scripts/ui/RoomListDialog.gd").new()
	add_child(_room_list_dlg)
	_room_list_dlg.join_confirmed.connect(_on_room_join_confirmed)
	_room_list_dlg.canceled.connect(_on_room_list_canceled)
	_room_list_dlg.popup_centered()

# 玩家B取消房间列表
func _on_room_list_canceled() -> void:
	if _room_list_dlg != null:
		_room_list_dlg.queue_free()
		_room_list_dlg = null

# 玩家B选择房间加入 → ENet 连接主机
func _on_room_join_confirmed(ip: String, port: int) -> void:
	if _room_list_dlg != null:
		_room_list_dlg.queue_free()
		_room_list_dlg = null
	if start_online_client(ip, port):
		control_panel.update_online_state(true)
		_show_status("已连接 %s:%d，等待主机开始游戏…" % [ip, port])

# 主机点「开始游戏」→ 推送配置给客户端 + 双方开始对局
func _on_room_start_requested() -> void:
	if _room_wait_dlg != null:
		_room_wait_dlg.queue_free()
		_room_wait_dlg = null
	RoomDiscovery.stop_broadcasting()
	NetSync.host_start_game(_time_setting, _piece_limit, _komi, _special_enabled)
	_new_game()
	_reinit_timer()
	_show_status("对局开始 · 您执黑方 · 第 1 手")

# 主机取消等待 → 关闭房间
func _on_room_wait_canceled() -> void:
	if _room_wait_dlg != null:
		_room_wait_dlg.queue_free()
		_room_wait_dlg = null
	RoomDiscovery.stop_broadcasting()
	stop_online()
	_show_status("已取消房间")

# 客户端收到主机「开始游戏」RPC → 应用配置 + 开始对局
func _on_net_game_started(time_setting: Dictionary, piece_limit: int, komi: float, special_enabled: bool) -> void:
	_time_setting = time_setting
	_piece_limit = piece_limit
	_komi = komi
	_special_enabled = special_enabled
	_new_game()
	_reinit_timer()
	_show_status("对局开始 · 您执白方 · 第 1 手")

# 模式选择处理
func _on_mode_selected(mode: String, difficulty: int) -> void:
	if mode == "pve":
		start_pve(difficulty)
	else:
		stop_pve()

func _new_game() -> void:
	session = GameSession.new(_komi, _special_enabled, _piece_limit)
	board_view.set_session(session)
	black_score_panel.set_session(session)
	white_score_panel.set_session(session)
	# 隐子视角：PvE 玩家执黑只看己方隐子；联机仅看本地颜色方隐子；PvP 全可见（观战视角）
	if _pve_mode:
		board_view.observer_view = Const.BLACK
	elif _online_mode:
		board_view.observer_view = NetworkManager.local_color
	else:
		board_view.observer_view = -1
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
	if black_score_panel != null and black_score_panel.has_method("set_log_entries"):
		black_score_panel.set_log_entries(_log_entries)
	if white_score_panel != null and white_score_panel.has_method("set_log_entries"):
		white_score_panel.set_log_entries(_log_entries)
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
	_timer.time_changed.connect(_on_time_changed)
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

# 根据当前模式（PvP/PvE/联机）更新得分板角色名与可控性
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
		black_score_panel.set_controllable(true)
		white_score_panel.set_controllable(false)
	elif _online_mode:
		# 联机: 本地颜色方=你，对端=对手
		var local_c: int = NetworkManager.local_color
		if local_c == Const.BLACK:
			black_score_panel.set_role_name("你")
			white_score_panel.set_role_name("对手")
			black_score_panel.set_controllable(true)
			white_score_panel.set_controllable(false)
		else:
			black_score_panel.set_role_name("对手")
			white_score_panel.set_role_name("你")
			black_score_panel.set_controllable(false)
			white_score_panel.set_controllable(true)
	else:
		# PvP: 默认黑方/白方，双方均可操作
		black_score_panel.set_role_name("")
		white_score_panel.set_role_name("")
		black_score_panel.set_controllable(true)
		white_score_panel.set_controllable(true)

func _on_new_game() -> void:
	_deploy_mode = false
	if board_view != null:
		board_view.set_deploy_mode(false)
	if _online_mode and NetworkManager.is_host():
		# 联机主机：本地新建 + 广播配置给客户端
		_new_game()
		NetSync.host_broadcast_new_game(_komi, _special_enabled, _piece_limit)
	elif _online_mode and not NetworkManager.is_host():
		# 联机客户端：新对局由主机发起，客户端等待广播
		_show_status("等待主机开始新对局…")
	else:
		_new_game()

func _on_pass() -> void:
	if session == null:
		return
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
	if session == null:
		return
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
	if session == null:
		return
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
	# PvE 模式：AI 思考中禁用悔棋（避免与异步线程冲突）
	if _pve_mode and _ai_thinking:
		_show_status("AI 思考中，请稍候")
		return
	if session == null or not session.can_undo():
		_show_status("无可悔棋历史")
		return
	# PvE 模式：连悔两手（AI + 玩家），让玩家可重新决策
	var undo_count: int = 1
	if _pve_mode and _ai != null:
		# 需悔到玩家上一次行棋前：AI 一手 + 玩家一手 = 2 手
		# 但若玩家刚虚手/行棋后 AI 未走，只悔 1 手
		if session.to_move == Const.BLACK and session.ply >= 2:
			undo_count = 2
	# 限制：不超过栈深度
	var actual: int = 0
	for i in undo_count:
		if not session.can_undo():
			break
		var out: Dictionary = session.undo()
		if not out.ok:
			break
		actual += 1
	if actual == 0:
		_show_status("无可悔棋历史")
		return
	# 悔棋后刷新视图（move_committed 信号已自动刷新，但 last_move 需重置）
	if board_view != null:
		# 重置 last_move 标记到当前最后一手（若有日志）
		if not _log_entries.is_empty() and actual <= _log_entries.size():
			# 弹出被悔的日志条目
			for i in actual:
				if not _log_entries.is_empty():
					_log_entries.pop_back()
		# 更新 last_move 显示
		if not _log_entries.is_empty():
			var last = _log_entries[-1]
			if last.get("placed", Vector2i(-1, -1)).x >= 0:
				board_view.last_move = last.placed
			else:
				board_view.last_move = Vector2i(-1, -1)
		else:
			board_view.last_move = Vector2i(-1, -1)
		board_view.queue_redraw()
	# 更新围空/围困状态追踪（避免误触特效）
	_prev_enclosures = session.cached_enclosures().duplicate(true)
	_prev_sieged_stones = _collect_sieged_stones()
	# 重置分数快照
	var sc: Dictionary = session.scores()
	_prev_scores = {
		"black": sc.black.total(),
		"white": sc.white.total(),
	}
	# 计时器切回当前行棋方
	if _timer != null and not session.game_over:
		_timer.switch_to(session.to_move)
	_show_status("已悔棋 %d 手" % actual)
	_update_controls()
	# 同步行棋记录到两侧得分板日志（悔棋后列表更新）
	if black_score_panel != null and black_score_panel.has_method("set_log_entries"):
		black_score_panel.set_log_entries(_log_entries)
	if white_score_panel != null and white_score_panel.has_method("set_log_entries"):
		white_score_panel.set_log_entries(_log_entries)

func _on_cycle_theme() -> void:
	ThemeManager.cycle_next()

func _on_cell_clicked(row: int, col: int) -> void:
	if session == null or session.game_over:
		return
	# 联机等待期间（对端未加入）禁止操作
	if _online_mode and NetworkManager.is_online() and NetworkManager.remote_peer_id() == 0:
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
	# 悔棋：仅刷新视图，不记日志/不触发特效/不切计时器（由 _on_undo 统一处理）
	var is_undo: bool = outcome.get("type", "") == "undo"
	if is_undo:
		_update_status()
		_update_controls()
		return
	# 撞隐子退回（overlap_fail）：仅处理现形特效，不记日志、不切计时器（未成手）
	var is_overlap_fail: bool = outcome.get("type", "") == "overlap_fail"
	if not is_overlap_fail:
		# 记录对局日志（在分数已更新后取 after）
		_record_log_entry(outcome)
	# 特效触发（mover_color 已存入 outcome，避免依赖 session.to_move 已切换）
	var mover_color: int = outcome.get("mover_color", session.to_move)
	if outcome.get("bounced", false):
		EffectsPlayer.play_bounce(outcome.overlap_pos, outcome.placed, mover_color)
	if outcome.captures.size() > 0:
		EffectsPlayer.play_capture(outcome.captures, outcome.captured_color)
		# 计算歼灭分：在己方领土/边境提吃 +2/子
		var annihilate_count: int = 0
		# 计算战损分：己方棋子在己方防御区被提吃 -2/子
		var war_loss_count: int = 0
		var war_loss_pos: Vector2i = Vector2i(-1, -1)
		var captured_c: int = outcome.captured_color
		for cap_pos in outcome.captures:
			if Const.is_defense_zone(cap_pos.y, mover_color):
				annihilate_count += 1
			# 战损：被提方在自己的防御区失去棋子
			if Const.is_defense_zone(cap_pos.y, captured_c):
				war_loss_count += 1
				if war_loss_pos.x < 0:
					war_loss_pos = cap_pos
		if annihilate_count > 0:
			var gain: int = annihilate_count * 2
			var popup_pos: Vector2i = outcome.captures[0]
			EffectsPlayer.play_score_popup("歼灭 +%d" % gain, popup_pos, mover_color, "annihilate")
		# 战损扣减动画（被提方视角）
		if war_loss_count > 0:
			var loss: int = war_loss_count * 2
			EffectsPlayer.play_score_popup("战损 -%d" % loss, war_loss_pos, captured_c, "territory_lost")
	if outcome.get("deployed", false):
		# 部署特种部队：用部署特效（己方视角下在位置画，对方视角下画在棋盘中心避免泄露）
		EffectsPlayer.play_special_deploy(mover_color, outcome.placed)
	elif outcome.placed is Vector2i and outcome.placed.x >= 0 and not outcome.bounced:
		EffectsPlayer.play_move(outcome.placed, mover_color)
	for r in outcome.get("revealed", []):
		EffectsPlayer.play_reveal(r.pos, r.get("revealed_reason", ""))
	# 围空/围困变化检测 → 触发特效
	_detect_and_trigger_territory_siege()
	_update_status()
	_update_controls()
	# 计时器切换到新行棋方
	# overlap_fail 未成手（不切回合），跳过计时器切换
	if _timer != null and not session.game_over and not is_overlap_fail:
		_timer.switch_to(session.to_move)
	# PvE：轮到 AI 时自动行棋（overlap_fail 时 AI 由 _ai_play 重试循环处理）
	if not is_overlap_fail:
		_maybe_trigger_ai()

# 时间变化时刷新得分板计时条显示
func _on_time_changed(_color: int) -> void:
	if black_score_panel != null:
		black_score_panel.queue_redraw()
	if white_score_panel != null:
		white_score_panel.queue_redraw()

# 时间耗尽（含读秒）：直接判超时方负
func _on_time_out(color: int) -> void:
	if session == null or session.game_over:
		return
	var winner_str: String = "白方胜" if color == Const.BLACK else "黑方胜"
	var loser_str: String = "黑方" if color == Const.BLACK else "白方"
	session.game_over = true
	var result: Dictionary = session.final_result("超时")
	result["winner"] = winner_str
	result["reason"] = "%s超时" % loser_str
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
	# 隐子位置保密：对方未现形特种部队的部署位置不记录到日志（避免按 L 查看日志时泄露）
	var placed: Vector2i = outcome.get("placed", Vector2i(-1, -1))
	if placed.x >= 0 and outcome.get("deployed", false):
		var sp: Dictionary = session.special.get_special_at(placed)
		if not sp.is_empty() and sp.get("hidden", false):
			var observer: int = board_view.observer_view if board_view != null else -1
			if observer != -1 and sp.color != observer:
				placed = Vector2i(-1, -1)  # 对方未现形隐子 → 隐藏位置
	_log_entries.append({
		"ply": outcome.get("ply", session.ply),
		"color": mover_color,
		"passed": outcome.get("passed", false),
		"deployed": outcome.get("deployed", false),
		"bounced": outcome.get("bounced", false),
		"placed": placed,
		"captures": cap_count,
		"score_before": before,
		"score_after": after,
	})
	_prev_scores[key] = after
	# 同步行棋记录到两侧得分板日志
	if black_score_panel != null and black_score_panel.has_method("set_log_entries"):
		black_score_panel.set_log_entries(_log_entries)
	if white_score_panel != null and white_score_panel.has_method("set_log_entries"):
		white_score_panel.set_log_entries(_log_entries)

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
				# 围空得分文字：每次围空扩展都显示
				var territory_gain: int = new_pts.size() * 2
				EffectsPlayer.play_score_popup("围空 +%d" % territory_gain, new_pts[0], c, "territory")
			if matched_prev_idx.has(c):
				matched_prev_idx[c][best_idx] = true
			else:
				matched_prev_idx[c] = {best_idx: true}
		else:
			# 全新围空：所有点都触发特效
			if not curr_pts.is_empty():
				EffectsPlayer.play_territory_formed(curr_pts, c)
				var territory_gain: int = curr_pts.size() * 2
				EffectsPlayer.play_score_popup("围空 +%d" % territory_gain, curr_pts[0], c, "territory")
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
				# 围空失守扣减文字：每次失守都显示
				var territory_loss: int = lost_pts.size() * 2
				EffectsPlayer.play_score_popup("围空 -%d" % territory_loss, lost_pts[0], c, "territory_lost")
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
		# 围困得分文字：每次围困成功都显示
		var siege_gain: int = new_sieged.size()
		var first_pos: Vector2i = new_sieged[0]
		var victim_color: int = session.board.get_at(first_pos.y, first_pos.x)
		var sieger_color: int = Const.opponent(victim_color)
		EffectsPlayer.play_score_popup("围困 +%d" % siege_gain, first_pos, sieger_color, "siege")
	if not broken_sieged.is_empty():
		EffectsPlayer.play_siege_broken(broken_sieged)
		# 围困解除扣减文字：每次解除都显示（仅当脱困棋子仍存活时）
		var broken_pos: Vector2i = broken_sieged[0]
		var victim_c: int = session.board.get_at(broken_pos.y, broken_pos.x)
		if victim_c != Const.EMPTY:
			var sieger_c: int = Const.opponent(victim_c)
			var siege_loss: int = broken_sieged.size()
			EffectsPlayer.play_score_popup("围困 -%d" % siege_loss, broken_pos, sieger_c, "siege_broken")
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
	# 应用 AI move 到 session（撞隐子退回时重试，最多 5 次）
	var color: int = _ai_color
	var out: Dictionary
	var attempts: int = 0
	while attempts < 5:
		attempts += 1
		match move.get("type", "pass"):
			"move":
				out = session.play_move(color, move.row, move.col)
			"deploy":
				out = session.deploy_special(color, move.row, move.col)
			_:
				out = session.do_pass(color)
		# 撞隐子退回（overlap_fail）：AI 不知晓隐子，重新决策
		if out.ok or out.get("type", "") != "overlap_fail":
			break
		Log.d("AI 撞隐子退回，重新决策 (attempt %d)" % attempts)
		# 重新决策（基于更新后的 session）
		if session.to_move != color or session.game_over:
			break
		move = _ai.choose_move(session)
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
	# 得分浮动文字使用独立 Label + Tween 动画，不走 _draw 叠加层
	if effect_id == "score_popup":
		var pos: Vector2i = payload.get("position", Vector2i(-1, -1))
		if pos.x >= 0 and pos.y >= 0:
			board_view.spawn_score_popup(payload.get("text", ""), pos, payload.get("type", ""))
		return
	var overlay: Dictionary = {"type": effect_id, "duration": _effect_duration(effect_id)}
	# 合并 payload 字段到 overlay（便于 BoardView 直接读取）
	for key in payload:
		overlay[key] = payload[key]
	board_view.add_effect_overlay(overlay)

func _effect_duration(effect_id: String) -> float:
	match effect_id:
		"capture":
			return 0.9
		"bounce":
			return 0.7
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

func _show_status(msg: String) -> void:
	# 联机/PvE 状态提示条（正常对局隐藏，联机流程/报错时显示）
	if _status_label == null:
		return
	if msg.is_empty():
		_status_label.visible = false
		return
	_status_label.text = msg
	_status_label.visible = true
	# 重置为金色（覆盖此前 _show_error 的红色）
	_status_label.add_theme_color_override("font_color", preload("res://scripts/ui/UITheme.gd").C_GOLD)
	# 10 秒后自动隐藏
	var lbl := _status_label
	await get_tree().create_timer(10.0).timeout
	if is_instance_valid(lbl) and lbl.text == msg:
		lbl.visible = false

func _show_error(msg: String) -> void:
	# 棋盘边框红色闪烁反馈
	if board_view != null:
		board_view.flash_error()
	# 状态条红色文字提示（4 秒后自动隐藏，避免残留一直显示）
	if _status_label != null:
		_status_label.text = msg
		_status_label.visible = true
		_status_label.add_theme_color_override("font_color", Color(0.95, 0.4, 0.35))
		var lbl := _status_label
		await get_tree().create_timer(4.0).timeout
		if is_instance_valid(lbl) and lbl.text == msg:
			lbl.visible = false

func _update_controls() -> void:
	control_panel.update_state(session, _deploy_mode)
	# 同步部署模式状态到双方得分板（按钮文字/可用性随之更新）
	if black_score_panel != null:
		black_score_panel.update_deploy_state(_deploy_mode)
	if white_score_panel != null:
		white_score_panel.update_deploy_state(_deploy_mode)

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
	# 注意：不在此处 _new_game()，避免计时器启动；待主机点"开始游戏"后再开局
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
	RoomDiscovery.stop_broadcasting()
	RoomDiscovery.stop_listening()
	NetworkManager.close()
	_new_game()
	_show_status("已退出联机模式")

# 获取本机局域网 IP（用于 UDP 广播房间信息）
# 过滤回环(127.*)、IPv6、链路本地 APIPA(169.254.*，如蓝牙/虚拟网卡)，
# 优先返回可路由的 IPv4 局域网地址（如 192.168.x.x）
func _get_local_ip() -> String:
	var fallback: String = "127.0.0.1"
	for addr in IP.get_local_addresses():
		var s: String = str(addr)
		# 过滤回环、IPv6
		if s.begins_with("127.") or s.begins_with(":") or s.find(":") >= 0:
			continue
		# 过滤链路本地 APIPA 地址（DHCP 失败/蓝牙/虚拟网卡）
		if s.begins_with("169.254."):
			if fallback == "127.0.0.1":
				fallback = s  # 无其他可用 IP 时兜底用链路本地
			continue
		return s
	return fallback

func _stop_pve_and_ai() -> void:
	if _pve_mode:
		stop_pve()

# 主机收到对端加入信号（ENet peer_connected 驱动）→ 更新等待对话框
func _on_net_peer_joined(_peer_id: int) -> void:
	if NetworkManager.is_host():
		if _room_wait_dlg != null and _room_wait_dlg.has_method("set_peer_joined"):
			_room_wait_dlg.set_peer_joined(true)
		_show_status("对手已加入，点击「开始游戏」开始对局")

# 客户端连接成功 → 等待主机开始游戏
func _on_net_joined() -> void:
	if not NetworkManager.is_host():
		_show_status("已连接主机，等待主机开始游戏…")

func _on_net_peer_disconnected(_peer_id: int) -> void:
	if NetworkManager.is_host():
		# 主机：保持 _online_mode=true，NetworkManager 回到 HOSTING 等待新对手
		NetSync.active = false
		# 结束当前对局（若进行中）
		if session != null and not session.game_over:
			session.game_over = true
			var result: Dictionary = session.final_result("对手断开")
			result["winner"] = ""  # 无胜负，异常终止
			result["reason"] = "对手断开连接"
			session.game_ended.emit(result)
		# 重新弹出等待对话框（若已被销毁）
		if _room_wait_dlg == null:
			_room_wait_dlg = preload("res://scripts/ui/RoomWaitDialog.gd").new()
			add_child(_room_wait_dlg)
			_room_wait_dlg.start_requested.connect(_on_room_start_requested)
			_room_wait_dlg.canceled.connect(_on_room_wait_canceled)
			_room_wait_dlg.popup_centered()
		else:
			# 对话框仍存在，重置为"等待对手"状态
			if _room_wait_dlg.has_method("set_peer_joined"):
				_room_wait_dlg.set_peer_joined(false)
		_show_status("对手已断开，等待新对手加入…")
	else:
		# 客户端：主机断开 → 彻底退出联机
		_show_status("主机已断开连接")
		_online_mode = false
		NetSync.active = false
		control_panel.update_online_state(false)
		if session != null and not session.game_over:
			session.game_over = true
			var result: Dictionary = session.final_result("主机断开")
			result["winner"] = ""
			result["reason"] = "主机断开连接"
			session.game_ended.emit(result)

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

func _on_net_new_game_requested(komi: float, special_enabled: bool, piece_limit: int = Const.PIECE_LIMIT) -> void:
	# 客户端收到主机的新对局配置（再战场景）
	_special_enabled = special_enabled
	_komi = komi
	_piece_limit = piece_limit
	_new_game()
	_show_status("新对局开始（贴目 %.1f）· 您执白方" % komi)

func _on_net_sync_mismatch() -> void:
	_show_status("状态同步异常，请双方重新开始对局")
	Log.w("联机状态同步异常")

# ===== 启动配置（由 Main 调用）=====
# 注：_ready() 已用默认空配置初始化 timer，此处需用真实 time_setting 重置 timer
func setup_game(mode: String, difficulty: int, time_setting: Dictionary = {}, options: Dictionary = {}) -> void:
	_time_setting = time_setting
	# 应用对局选项（贴目、兵力上限）—— 必须在 _reinit_timer 之前设置，
	# 因为 _ready() 已调用 _new_game() 用默认值创建 session，
	# 这里覆盖字段后调用 _new_game() 重建以应用新配置
	if options.has("komi"):
		_komi = options.komi
	if options.has("piece_limit"):
		_piece_limit = options.piece_limit
	# 联机模式：房间设定由 NetworkMenu 选定，不沿用 StartMenu 传入的设定
	# 此处重置为默认值，待主机建主时由 _on_online_host 重新赋值
	if mode == "online":
		_time_setting = {"main": -1.0, "byoyomi": 0, "byoyomi_duration": 0.0}
	# 用真实配置重置计时器（覆盖 _ready 中默认的无限时间）
	_reinit_timer()
	# 重建 session 以应用新的 komi/piece_limit（_ready 中的 _new_game 用了默认值）
	_new_game()
	match mode:
		"pve":
			start_pve(difficulty)
		"online":
			# 联机模式：自动打开联机菜单供玩家选择创建房间/加入房间
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
		if _timer.time_changed.is_connected(_on_time_changed):
			_timer.time_changed.disconnect(_on_time_changed)
	_timer = TimerSystem.new()
	var timer_cfg: Dictionary = {
		Const.BLACK: _time_setting,
		Const.WHITE: _time_setting,
	}
	_timer.reset(timer_cfg)
	_timer.time_out.connect(_on_time_out)
	_timer.time_changed.connect(_on_time_changed)
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
