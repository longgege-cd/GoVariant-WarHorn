# UI 集成测试：实例化 GameScreen，模拟点击棋盘，验证 session 状态变化
# 用法: godot --headless res://tests/test_ui_integration.tscn
#
# 注意：必须用「场景方式」运行而非 --script，因为 --script 模式下
# autoload 全局标识符（ThemeManager/EffectsPlayer/Log）在编译期未注册，
# 会导致 GameScreen/BoardView/ScorePanel 等引用 autoload 的脚本编译失败。
extends Node

const TestFramework = preload("res://tests/test_framework.gd")

var t: TestFramework

func _ready() -> void:
	t = TestFramework.new()
	t.suite("UI 集成")
	await _run_tests()

func _run_tests() -> void:
	print("########## UI 集成测试 ##########")

	# 0. 前置：autoload 应已加载
	t.expect(ThemeManager != null, "ThemeManager autoload 可用")
	t.expect(EffectsPlayer != null, "EffectsPlayer autoload 可用")
	t.expect(Log != null, "Log autoload 可用")
	t.expect(ThemeManager.current != null, "ThemeManager.current 初始化非 null")

	# 1. 实例化 GameScreen
	var screen_script := preload("res://scripts/ui/GameScreen.gd")
	var screen: Control = screen_script.new()
	t.expect(screen != null, "GameScreen 实例化")
	add_child(screen)
	await get_tree().process_frame

	# 2. 验证 session 初始化
	t.expect(screen.session != null, "session 已创建")
	t.expect(screen.board_view != null, "board_view 已创建")
	t.expect(screen.black_score_panel != null, "black_score_panel 已创建")
	t.expect(screen.white_score_panel != null, "white_score_panel 已创建")
	t.expect(screen.control_panel != null, "control_panel 已创建")
	t.expect(screen.history_panel != null, "history_panel 已创建")
	t.expect_eq(screen.session.ply, 0, "初始 ply=0")
	t.expect_eq(screen.session.to_move, Const.BLACK, "黑先")

	# 3. 模拟点击棋盘 (10, 10) - 黑下白境
	screen._on_cell_clicked(10, 10)
	await get_tree().process_frame
	t.expect_eq(screen.session.ply, 1, "黑下后 ply=1")
	t.expect_eq(screen.session.to_move, Const.WHITE, "轮白")
	t.expect_eq(screen.session.board.get_at(10, 10), Const.BLACK, "黑子已落 (10,10)")

	# 4. 白下 (9, 9) - 边境
	screen._on_cell_clicked(9, 9)
	await get_tree().process_frame
	t.expect_eq(screen.session.ply, 2, "白下后 ply=2")
	t.expect_eq(screen.session.to_move, Const.BLACK, "轮黑")
	t.expect_eq(screen.session.board.get_at(9, 9), Const.WHITE, "白子已落 (9,9)")

	# 5. 测试虚手按钮 - 双方虚手终局
	screen._on_pass()
	await get_tree().process_frame
	t.expect_eq(screen.session.ply, 3, "黑虚手后 ply=3")
	t.expect_eq(screen.session.consecutive_passes, 1, "连续虚手 1")
	screen._on_pass()
	await get_tree().process_frame
	t.expect_eq(screen.session.consecutive_passes, 2, "连续虚手 2")
	t.expect(screen.session.game_over, "双方虚手 → 终局")

	# 6. 新对局
	screen._on_new_game()
	await get_tree().process_frame
	t.expect_eq(screen.session.ply, 0, "新对局 ply=0")
	t.expect(not screen.session.game_over, "新对局未结束")

	# 7. 测试主题切换（单主题时仍可调用）
	screen._on_cycle_theme()
	await get_tree().process_frame
	t.expect(ThemeManager.current != null, "主题切换后 current 非 null")

	# 8. 测试部署特种部队模式
	t.expect(screen._deploy_mode == false, "默认非部署模式")
	screen._on_deploy_button()
	t.expect(screen._deploy_mode == true, "切换到部署模式")
	screen._on_cell_clicked(5, 5)  # 黑部署特种
	await get_tree().process_frame
	t.expect_eq(screen.session.ply, 1, "部署后 ply=1")
	t.expect(screen.session.special.has_hidden_at(Vector2i(5, 5)), "隐子已部署 (5,5)")
	t.expect_eq(screen.session.board.get_at(5, 5), Const.BLACK, "隐子在盘上为黑子")
	# 部署特效应已触发
	t.expect(screen.board_view.effect_overlays.size() > 0, "部署特效叠加层已添加")
	var has_deploy_effect: bool = false
	for ov in screen.board_view.effect_overlays:
		if ov.get("type", "") == "special_deploy":
			has_deploy_effect = true
			break
	t.expect(has_deploy_effect, "部署特效类型正确")

	# 9. 提子特效测试：构造提子场景
	screen._on_new_game()
	await get_tree().process_frame
	# 目标：黑包围白(5,6) 提子。需交替落子：
	# 1.黑(5,5)左 2.白(5,6)目标 3.黑(4,6)上 4.白(18,18)别处
	# 5.黑(6,6)下 6.白(18,17)别处 7.黑(5,7)右→提白(5,6)
	screen._on_cell_clicked(5, 5)   # 黑 左
	await get_tree().process_frame
	screen._on_cell_clicked(5, 6)   # 白 目标
	await get_tree().process_frame
	screen._on_cell_clicked(4, 6)   # 黑 上
	await get_tree().process_frame
	screen._on_cell_clicked(18, 18) # 白 别处
	await get_tree().process_frame
	screen._on_cell_clicked(6, 6)   # 黑 下
	await get_tree().process_frame
	screen._on_cell_clicked(18, 17) # 白 别处
	await get_tree().process_frame
	screen._on_cell_clicked(5, 7)   # 黑 右 → 提白(5,6)
	await get_tree().process_frame
	t.expect_eq(screen.session.board.get_at(5, 6), Const.EMPTY, "白(5,6)被提走")
	# 提子特效应已触发
	var has_capture_effect: bool = false
	for ov in screen.board_view.effect_overlays:
		if ov.get("type", "") == "capture":
			has_capture_effect = true
			break
	t.expect(has_capture_effect, "提子特效叠加层已添加")

	# 10. 落子特效测试：每次落子都应有 move 脉冲
	screen._on_new_game()
	await get_tree().process_frame
	screen._on_cell_clicked(9, 9)
	await get_tree().process_frame
	var has_move_effect: bool = false
	for ov in screen.board_view.effect_overlays:
		if ov.get("type", "") == "move":
			has_move_effect = true
			break
	t.expect(has_move_effect, "落子脉冲特效已添加")

	# ===== 11. PvE 模式测试：玩家落子后 AI 自动应对 =====
	# 切换到 PvE 简单模式（会触发 _new_game）
	screen.start_pve(0)  # AIManager.Difficulty.EASY = 0
	await get_tree().process_frame
	t.expect(screen._pve_mode == true, "PvE 模式已启用")
	t.expect(screen._ai != null, "AI 实例已创建")
	t.expect_eq(screen.session.ply, 0, "PvE 新对局 ply=0")
	t.expect_eq(screen.session.to_move, Const.BLACK, "PvE 玩家执黑先手")
	# 玩家落子 (10,10)
	screen._on_cell_clicked(10, 10)
	await get_tree().process_frame
	t.expect_eq(screen.session.ply, 1, "玩家落子后 ply=1")
	t.expect_eq(screen.session.to_move, Const.WHITE, "轮到 AI(白)")
	# 等待 AI 行棋（异步：0.3s 延迟 + 后台线程计算，需足够帧）
	var waited: int = 0
	while screen._ai_thinking and waited < 120:
		await get_tree().process_frame
		waited += 1
	# 再等一帧确保 _ai_play 应用 move 完成
	await get_tree().process_frame
	t.expect(not screen._ai_thinking, "AI 思考结束")
	t.expect(screen.session.ply >= 2, "AI 已应手 ply>=2")
	t.expect_eq(screen.session.to_move, Const.BLACK, "AI 行棋后轮到玩家")

	# ===== 12. PvE 连续多手对局不卡死 =====
	var ply_before: int = screen.session.ply
	# 玩家连续下 5 手（每手后等 AI 应对）
	var pve_ok: bool = true
	for i in 5:
		if screen.session.game_over:
			break
		# 找一个合法点下
		var placed: bool = false
		for r in range(8, 13):
			if placed:
				break
			for c in range(8, 13):
				if screen.session.board.get_at(r, c) == Const.EMPTY:
					screen._on_cell_clicked(r, c)
					placed = true
					break
		# 等 AI
		var w2: int = 0
		while screen._ai_thinking and w2 < 120:
			await get_tree().process_frame
			w2 += 1
		await get_tree().process_frame
		if screen.session.ply <= ply_before + i * 2:
			pve_ok = false
			break
	t.expect(pve_ok, "PvE 多手对局正常推进")
	t.expect(screen.session.ply > ply_before, "PvE 对局 ply 增加")

	# ===== 13. 退出 PvE 切回 PvP =====
	screen.stop_pve()
	await get_tree().process_frame
	t.expect(screen._pve_mode == false, "已退出 PvE 模式")
	t.expect(screen._ai == null, "AI 实例已清空")
	t.expect_eq(screen.session.ply, 0, "切回 PvP 后新对局 ply=0")

	# 清理
	screen.queue_free()
	await get_tree().process_frame

	# 汇总
	print("\n========== UI 集成测试结果 ==========")
	print("通过: %d   失败: %d" % [t.passed, t.failed])
	if t.failures.size() > 0:
		print("--- 失败明细 ---")
		for f in t.failures:
			print(f)
	print("==============================")
	var code: int = 0 if t.failed == 0 else 1
	get_tree().quit(code)
