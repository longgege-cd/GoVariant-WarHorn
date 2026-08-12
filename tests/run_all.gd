# 测试入口：headless 运行所有测试
# 用法: godot --headless --script res://tests/run_all.gd
extends SceneTree

const TestFramework = preload("res://tests/test_framework.gd")

var _lines: PackedStringArray = PackedStringArray()

func _p(line: String) -> void:
	print(line)
	_lines.append(line)

func _init() -> void:
	_p("########## 《战争号角-边境线》规则引擎测试 ##########")
	var t := TestFramework.new()

	var capture_tests := preload("res://tests/test_capture.gd").new()
	capture_tests.run(t)

	var ko_tests := preload("res://tests/test_ko.gd").new()
	ko_tests.run(t)

	var territory_tests := preload("res://tests/test_territory.gd").new()
	territory_tests.run(t)

	var siege_tests := preload("res://tests/test_siege.gd").new()
	siege_tests.run(t)

	var territory_siege_edge_tests := preload("res://tests/test_territory_siege_edge.gd").new()
	territory_siege_edge_tests.run(t)

	var score_tests := preload("res://tests/test_score.gd").new()
	score_tests.run(t)

	var score_panel_tests := preload("res://tests/test_score_panel.gd").new()
	score_panel_tests.run(t)

	var timer_cumulative_tests := preload("res://tests/test_timer_cumulative.gd").new()
	timer_cumulative_tests.run(t)

	var special_tests := preload("res://tests/test_special.gd").new()
	special_tests.run(t)

	var signal_tests := preload("res://tests/test_signals.gd").new()
	signal_tests.run(t)

	var ai_tests := preload("res://tests/test_ai.gd").new()
	ai_tests.run(t)

	var ai_engine_tests := preload("res://tests/test_ai_engine.gd").new()
	ai_engine_tests.run(t)

	# 联机模块测试需 autoload，通过场景方式运行：res://tests/test_net.tscn
	# 此处不集成（--script 模式下 autoload 编译期不可见）

	var sim_tests := preload("res://tests/test_simulator.gd").new()
	sim_tests.run(t)

	var sgf_tests := preload("res://tests/test_sgf.gd").new()
	sgf_tests.run(t)

	var replay_tests := preload("res://tests/test_replay.gd").new()
	replay_tests.run(t)

	# 汇总
	_p("")
	_p("========== 测试结果 ==========")
	_p("通过: %d   失败: %d" % [t.passed, t.failed])
	if t.failures.size() > 0:
		_p("--- 失败明细 ---")
		for f in t.failures:
			_p(f)
	_p("==============================")

	# 写入文件确保可读（user:// 与工程根目录两处）
	var user_path: String = "user://test_result.log"
	var f := FileAccess.open(user_path, FileAccess.WRITE)
	if f:
		for line in _lines:
			f.store_line(line)
		f.close()
	_p("user 日志: %s" % ProjectSettings.globalize_path(user_path))
	# 工程根目录（绝对路径）
	var proj_root: String = ProjectSettings.globalize_path("res://")
	var f2 := FileAccess.open(proj_root + "test_result.log", FileAccess.WRITE)
	if f2:
		for line in _lines:
			f2.store_line(line)
		f2.close()
	_p("工程日志: %s" % (proj_root + "test_result.log"))

	var code: int = 0 if t.failed == 0 else 1
	_p("退出码: %d" % code)
	quit(code)
