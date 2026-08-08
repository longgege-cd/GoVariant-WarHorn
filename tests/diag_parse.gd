extends Node

func _ready() -> void:
	var targets: Array = [
		"res://scripts/ui/ScorePanel.gd",
		"res://scripts/ui/GameScreen.gd",
	]
	for path in targets:
		print("--- 检查: ", path)
		var s = load(path)
		if s == null:
			print("  [FAIL] 加载失败: ", path)
		else:
			print("  [ OK ] 加载成功: ", path)
	get_tree().quit(0)
