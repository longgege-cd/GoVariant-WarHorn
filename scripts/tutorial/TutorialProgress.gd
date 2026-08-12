# 教程进度存储：关卡解锁/完成状态持久化
#
# 结构：{"unlocked": [0], "completed": [0,1,...]}
#   - unlocked: 已解锁关卡索引
#   - completed: 已完成关卡索引
# 解锁规则：完成前一关解锁下一关（关卡0始终解锁）
class_name TutorialProgress
extends RefCounted

const SAVE_PATH: String = "user://tutorial_progress.json"
const TOTAL_LESSONS: int = 14

# 读取进度（不存在则返回初始状态）
static func load_progress() -> Dictionary:
	var p: Dictionary = {"unlocked": [0], "completed": []}
	if FileAccess.file_exists(SAVE_PATH):
		var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
		if f:
			var data = JSON.parse_string(f.get_as_text())
			if data is Dictionary:
				p = data
	return p

# 保存进度
static func save_progress(p: Dictionary) -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(p))

# 关卡是否已解锁（完成前一关即解锁）
static func is_unlocked(p: Dictionary, idx: int) -> bool:
	if idx <= 0:
		return true
	return int(p.get("completed", []).find(idx - 1)) >= 0

# 关卡是否已完成
static func is_completed(p: Dictionary, idx: int) -> bool:
	return int(p.get("completed", []).find(idx)) >= 0

# 记录关卡完成（更新 completed；unlocked 按序补充）
static func mark_completed(p: Dictionary, idx: int) -> void:
	var completed: Array = p.get("completed", [])
	if completed.find(idx) < 0:
		completed.append(idx)
		completed.sort()
	p["completed"] = completed
	var unlocked: Array = p.get("unlocked", [])
	# 解锁下一关（以及跳过的可选关）
	if idx + 1 < TOTAL_LESSONS and unlocked.find(idx + 1) < 0:
		unlocked.append(idx + 1)
		unlocked.sort()
	p["unlocked"] = unlocked
	save_progress(p)

# 重置进度
static func reset_progress() -> void:
	if FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))
