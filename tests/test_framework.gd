# 轻量测试框架：断言 + 结果收集，不依赖 Godot 节点
extends RefCounted
class_name TestFramework

var passed: int = 0
var failed: int = 0
var failures: Array = []   # Array[String]
var current_suite: String = ""

func suite(name: String) -> void:
	current_suite = name
	print("\n=== %s ===" % name)

func expect(cond: bool, msg: String) -> void:
	if cond:
		passed += 1
	else:
		failed += 1
		var line: String = "[%s] FAIL: %s" % [current_suite, msg]
		failures.append(line)
		print(line)

func expect_eq(a, b, msg: String) -> void:
	var ok: bool = false
	if typeof(a) == TYPE_OBJECT or typeof(b) == TYPE_OBJECT:
		ok = a == b
	else:
		ok = (a == b)
	if ok:
		passed += 1
	else:
		failed += 1
		var line: String = "[%s] FAIL: %s (got %s, want %s)" % [current_suite, msg, str(a), str(b)]
		failures.append(line)
		print(line)

func summary() -> void:
	print("\n========== 测试结果 ==========")
	print("通过: %d   失败: %d" % [passed, failed])
	if failures.size() > 0:
		print("--- 失败明细 ---")
		for f in failures:
			print(f)
	print("==============================")
