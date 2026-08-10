# 临时运行器：仅运行围空/围困边界测试
extends SceneTree

const TestFramework = preload("res://tests/test_framework.gd")

func _init() -> void:
	print("########## 围空/围困 边界测试 ##########")
	var t := TestFramework.new()
	var edge_tests := preload("res://tests/test_territory_siege_edge.gd").new()
	edge_tests.run(t)
	print("")
	print("========== 测试结果 ==========")
	print("通过: %d   失败: %d" % [t.passed, t.failed])
	if t.failures.size() > 0:
		print("--- 失败明细 ---")
		for f in t.failures:
			print(f)
	print("==============================")
	var code: int = 0 if t.failed == 0 else 1
	quit(code)
