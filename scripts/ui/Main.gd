# 工程入口：主菜单 ↔ 对局场景切换
#
# 状态机：
#   - 主菜单（StartMenu）→ 用户选模式并点"开始" → 进入对局（GameScreen）
#   - 对局中按 ESC → 暂停菜单 → "返回主菜单" → 回到主菜单
extends Control

var _start_menu: Control = null
var _game_screen: Control = null
var _replay_screen: Control = null

func _ready() -> void:
	_show_start_menu()

func _show_start_menu() -> void:
	# 清理对局/棋谱回放
	if _game_screen != null:
		_game_screen.queue_free()
		_game_screen = null
	if _replay_screen != null:
		_replay_screen.queue_free()
		_replay_screen = null
	# 创建主菜单
	_start_menu = preload("res://scripts/ui/StartMenu.gd").new()
	_start_menu.set_anchors_preset(PRESET_FULL_RECT)
	add_child(_start_menu)
	_start_menu.start_requested.connect(_on_start_requested)
	_start_menu.replay_requested.connect(_on_replay_requested)
	_start_menu.tutorial_requested.connect(_show_tutorial_screen)
	_start_menu.theme_cycle_requested.connect(_on_theme_cycle)
	_start_menu.quit_requested.connect(_on_quit)

func _show_tutorial_screen() -> void:
	# 清理主菜单
	if _start_menu != null:
		_start_menu.queue_free()
		_start_menu = null
	# 创建规则教程界面
	var tutorial_screen = preload("res://scripts/tutorial/TutorialScreen.gd").new()
	tutorial_screen.set_anchors_preset(PRESET_FULL_RECT)
	add_child(tutorial_screen)
	tutorial_screen.back_to_main_menu_requested.connect(_show_start_menu)

func _show_replay_screen() -> void:
	# 清理主菜单
	if _start_menu != null:
		_start_menu.queue_free()
		_start_menu = null
	# 创建棋谱回放场景
	_replay_screen = preload("res://scripts/ui/ReplayScreen.gd").new()
	_replay_screen.set_anchors_preset(PRESET_FULL_RECT)
	add_child(_replay_screen)
	_replay_screen.back_to_main_menu_requested.connect(_show_start_menu)

func _show_game_screen(mode: String, difficulty: int, time_setting: Dictionary, options: Dictionary) -> void:
	# 清理主菜单
	if _start_menu != null:
		_start_menu.queue_free()
		_start_menu = null
	# 创建对局
	_game_screen = preload("res://scripts/ui/GameScreen.gd").new()
	_game_screen.set_anchors_preset(PRESET_FULL_RECT)
	add_child(_game_screen)
	_game_screen.back_to_main_menu_requested.connect(_show_start_menu)
	# 配置模式 + 思考时间 + 对局选项（贴目、兵力上限）
	_game_screen.setup_game(mode, difficulty, time_setting, options)

func _on_start_requested(mode: String, difficulty: int, time_setting: Dictionary, options: Dictionary) -> void:
	_show_game_screen(mode, difficulty, time_setting, options)

func _on_replay_requested() -> void:
	_show_replay_screen()

func _on_theme_cycle() -> void:
	ThemeManager.cycle_next()

func _on_quit() -> void:
	get_tree().quit()
