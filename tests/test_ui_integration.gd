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

	# ===== 14. 状态提示条：_show_error 自动隐藏 + 颜色重置 =====
	# 修复：_show_error 无自动隐藏导致"非您的回合"永久残留；_show_status 不重置红色
	t.expect(screen._status_label != null, "状态条已创建")
	screen._show_error("非您的回合")
	t.expect(screen._status_label.visible, "错误提示显示")
	t.expect_eq(screen._status_label.text, "非您的回合", "错误文本正确")
	await get_tree().create_timer(4.2).timeout
	t.expect(not screen._status_label.visible, "错误提示 4 秒后自动隐藏（不一直显示）")
	# _show_error 后再 _show_status：状态文本覆盖错误文本
	screen._show_error("测试错误")
	screen._show_status("对局开始 · 您执黑方")
	t.expect(screen._status_label.visible, "状态提示显示")
	t.expect_eq(screen._status_label.text, "对局开始 · 您执黑方", "状态文本覆盖错误文本")
	await get_tree().create_timer(10.2).timeout
	t.expect(not screen._status_label.visible, "状态提示 10 秒后自动隐藏")

	# 清理
	screen.queue_free()
	await get_tree().process_frame

	# ===== 15. 主菜单：人机对战合并 + 二级难度选择页 =====
	var menu = preload("res://scripts/ui/StartMenu.gd").new()
	add_child(menu)
	await get_tree().process_frame
	t.expect(menu._main_root != null, "主菜单根容器已构建")
	t.expect(menu._difficulty_view != null, "二级难度视图已构建")
	# 人机对战已合并为一个入口（MODE_ENTRIES 中 pve 仅 1 项）
	var pve_count: int = 0
	for e in menu.MODE_ENTRIES:
		if e.mode == "pve":
			pve_count += 1
	t.expect_eq(pve_count, 1, "人机对战已合并为一个入口")
	# 选中人机对战（索引1）并点开始 → 进入二级难度页
	menu._selected_idx = 1
	menu._on_start()
	t.expect(menu._difficulty_view.visible, "二级难度选择页显示")
	t.expect(not menu._main_root.visible, "二级页时主菜单隐藏")
	# 返回
	menu._hide_difficulty_view()
	t.expect(menu._main_root.visible, "返回后主菜单恢复")
	t.expect(not menu._difficulty_view.visible, "返回后二级页隐藏")
	# 选难度 → 发出 start_requested
	var emitted: Dictionary = {"mode": "", "diff": -1}
	menu.start_requested.connect(func(mode: String, diff: int, _ts: Dictionary, _o: Dictionary):
		emitted["mode"] = mode
		emitted["diff"] = diff
	)
	menu._on_difficulty_chosen(AIDifficulty.Difficulty.HARD)
	t.expect_eq(emitted.get("mode", ""), "pve", "发出 pve 模式")
	t.expect_eq(emitted.get("diff", -1), AIDifficulty.Difficulty.HARD, "难度=困难")
	menu.queue_free()
	await get_tree().process_frame

	# ===== 16. 教程模块：StartMenu 教程按钮 + TutorialScreen + TutorialLesson =====
	menu = preload("res://scripts/ui/StartMenu.gd").new()
	add_child(menu)
	await get_tree().process_frame
	t.expect(menu.tutorial_requested != null, "教程信号已声明")
	var tut_emitted: Dictionary = {"v": false}
	menu.tutorial_requested.connect(func(): tut_emitted["v"] = true)
	var tut_btn: Button = null
	for child in menu._bottom_row.get_children():
		if child is Button and str(child.text).contains("教 程"):
			tut_btn = child
			break
	t.expect(tut_btn != null, "主菜单含教程按钮")
	if tut_btn != null:
		tut_btn.pressed.emit()
	t.expect(tut_emitted["v"], "点击教程按钮发出 tutorial_requested")
	menu.queue_free()
	await get_tree().process_frame

	# TutorialScreen：构建关卡列表 + 打开关卡
	# 注意：教程完成会写 user:// 进度文件，先备份、重置保证测试环境干净、结束后恢复
	var prog_file: String = TutorialProgress.SAVE_PATH
	var prog_backup: String = "user://tutorial_progress_ui.bak"
	if FileAccess.file_exists(prog_file):
		var pf := FileAccess.open(prog_file, FileAccess.READ)
		if pf:
			var pb := FileAccess.open(prog_backup, FileAccess.WRITE)
			if pb:
				pb.store_string(pf.get_as_text())
				pb.close()
			pf.close()
	TutorialProgress.reset_progress()

	var tscreen = preload("res://scripts/tutorial/TutorialScreen.gd").new()
	add_child(tscreen)
	await get_tree().process_frame
	t.expect(tscreen._progress != null, "教程进度已加载")
	t.expect(tscreen._lesson_btns.size() >= 14, "关卡列表覆盖 14 关")
	t.expect(tscreen._lesson_btns[1].disabled, "第 2 关默认锁定")
	t.expect(not tscreen._lesson_btns[0].disabled, "第 1 关默认解锁")
	# 打开第 1 关 → 内部实例化 TutorialLesson
	tscreen._open_lesson(0)
	await get_tree().process_frame
	tscreen.queue_free()
	await get_tree().process_frame

	# TutorialLesson 直接实例化（关卡0）且不报错
	var lv = preload("res://scripts/tutorial/TutorialLesson.gd").new()
	lv.configure(0, TutorialProgress.load_progress())
	add_child(lv)
	await get_tree().process_frame
	t.expect(lv.session != null, "TutorialLesson session 已创建")
	t.expect_eq(lv.lesson.get("id", ""), "1-1", "关卡 0 数据为 1-1")
	# 1-1 区域点击：点黑土区域 → 步骤推进
	lv._handle_zone_click(0, 0)
	t.expect_eq(lv._zone_step, 1, "1-1 黑土区域点击推进")
	lv.queue_free()
	await get_tree().process_frame

	# 自由落子：关卡1(1-2 place) 在提示点落子 → 完成关卡
	lv = preload("res://scripts/tutorial/TutorialLesson.gd").new()
	lv.configure(1, TutorialProgress.load_progress())
	add_child(lv)
	await get_tree().process_frame
	t.expect_eq(lv.lesson.get("id", ""), "1-2", "关卡 1 数据为 1-2")
	lv._on_board_clicked(9, 8)
	t.expect(lv.session.ply > 0, "教程棋盘自由落子生效")
	t.expect(lv._completed, "1-2 落一手完成关卡")
	t.expect(str(lv._stones_left_label.text).contains("111"), "落子后剩余棋子数更新（黑 111）")
	# 完成后点「下一关」→ 进入 1-3
	t.expect_eq(lv._complete_btn.text, "下一关", "完成后按钮文本为「下一关」")
	lv._on_complete_btn_pressed()
	t.expect_eq(lv.lesson_idx, 2, "点击下一关切至关卡 2")
	t.expect_eq(lv.lesson.get("id", ""), "1-3", "关卡 2 数据为 1-3")
	t.expect(not lv._completed, "新关卡状态重置")
	lv.queue_free()
	await get_tree().process_frame

	# ===== 解锁链：完成关卡 → 返回列表 → 下一关解锁 =====
	TutorialProgress.reset_progress()
	tscreen = preload("res://scripts/tutorial/TutorialScreen.gd").new()
	add_child(tscreen)
	await get_tree().process_frame
	t.expect(tscreen._lesson_btns[1].disabled, "重置后 1-2 锁定")
	t.expect(not tscreen._lesson_btns[0].disabled, "重置后 1-1 解锁")
	tscreen._open_lesson(0)
	await get_tree().process_frame
	var lv0: Node = tscreen._lesson_view
	lv0._handle_zone_click(0, 0)
	lv0._handle_zone_click(9, 9)
	lv0._handle_zone_click(10, 10)
	t.expect(lv0._completed, "1-1 三区点击完成")
	t.expect(TutorialProgress.is_unlocked(lv0.progress, 1), "1-1 完成后 1-2 逻辑解锁")
	# 返回列表 → 重建 → 1-2 按钮应可用
	lv0.back_requested.emit()
	await get_tree().process_frame
	await get_tree().process_frame
	t.expect(not tscreen._lesson_btns[1].disabled, "完成 1-1 返回列表后 1-2 解锁")
	t.expect(str(tscreen._lesson_btns[0].text).contains("已完成"), "1-1 显示已完成")
	tscreen.queue_free()
	await get_tree().process_frame

	# 恢复真实进度
	TutorialProgress.reset_progress()
	if FileAccess.file_exists(prog_backup):
		var pf2 := FileAccess.open(prog_backup, FileAccess.READ)
		if pf2:
			var pb2 := FileAccess.open(prog_file, FileAccess.WRITE)
			if pb2:
				pb2.store_string(pf2.get_as_text())
				pb2.close()
			pf2.close()
		DirAccess.remove_absolute(ProjectSettings.globalize_path(prog_backup))

	# ===== 17. 得分扣减动画：围困形成同时触发「围困 +N」与「活子 -N」 =====
	screen = preload("res://scripts/ui/GameScreen.gd").new()
	add_child(screen)
	await get_tree().process_frame
	var popup_texts: Array = []
	var eff_hook = func(id: String, payload: Dictionary):
		if id == "score_popup":
			popup_texts.append(payload.get("text", ""))
	EffectsPlayer.effect_started.connect(eff_hook)
	# 构造围困场景（2-3 教程 setup + 压缩点 (11,10)，空点 4→3 触发围困）
	var sess: GameSession = screen.session
	for st in [[10,10,1],[10,11,1],[14,10,1],[14,11,1],[11,9,1],[12,9,1],[13,9,1],[11,12,1],[12,12,1],[13,12,1],[12,10,2],[12,11,2]]:
		sess.board.set_at(st[0], st[1], st[2])
	sess.board.set_at(11, 10, Const.BLACK)
	# set_at 不失效缓存，需手动失效后检测围困（真实对局走 play_move 会自动失效）
	screen.session._invalidate_cache()
	screen._detect_and_trigger_territory_siege()
	var has_siege_plus: bool = false
	var has_victim_minus: bool = false
	for txt in popup_texts:
		if str(txt).begins_with("围困 +"):
			has_siege_plus = true
		if str(txt).begins_with("活子 -"):
			has_victim_minus = true
	t.expect(has_siege_plus, "围困形成显示「围困 +N」")
	t.expect(has_victim_minus, "围困形成同时显示被围方「活子 -N」扣分动画")
	EffectsPlayer.effect_started.disconnect(eff_hook)
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
