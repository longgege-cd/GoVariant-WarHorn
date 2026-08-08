# 对局计时系统：纯逻辑（RefCounted + signal），不依赖 Node
#
# 设计：
#   - 每方有 main_time（秒，-1=无限）和 byoyomi（读秒次数，0=无读秒）
#   - 行棋方消耗 main_time；main_time 耗尽进入读秒（每次用尽 +1 次读秒重置）
#   - 超时不再直接判负，改为发出 timeout_pass 信号 → GameSession 执行 do_pass
#   - 连续 MAX_TIMEOUT_PASS 次超时 → time_out 信号 → 判负
#   - 落子后重置该方连续超时计数（reset_timeout_count）
#   - 非行棋方不计时
#   - pause/resume 支持暂停菜单
class_name TimerSystem
extends RefCounted

signal time_out(color: int)  # 连续超时达上限 → 判负
signal time_changed(color: int)  # 时间变化通知（UI 刷新）
signal timeout_pass(color: int)  # 单次超时 → 执行 pass（由 GameScreen 处理）

const MAX_TIMEOUT_PASS: int = 3  # 连续超时次数上限

# 时间配置：{ color: { "main": float(-1=无限), "byoyomi": int(0=无) } }
var _config: Dictionary = {}
# 当前方剩余时间
var _main_time: Dictionary = {}  # color -> float
var _byoyomi_left: Dictionary = {}  # color -> int（剩余读秒次数）
var _byoyomi_time: Dictionary = {}  # color -> float（当前读秒倒计时）
var _in_byoyomi: Dictionary = {}  # color -> bool
var _timeout_count: Dictionary = {}  # color -> int（连续超时次数）
var _active: int = -1  # 当前行棋方（-1=未开始/暂停）
var _paused: bool = false

# 重置计时器（新对局）
# config: { color: { "main": float(-1=无限), "byoyomi": int } }
func reset(config: Dictionary) -> void:
	_config = config.duplicate(true)
	_main_time.clear()
	_byoyomi_left.clear()
	_byoyomi_time.clear()
	_in_byoyomi.clear()
	_timeout_count.clear()
	for c in [Const.BLACK, Const.WHITE]:
		var cfg: Dictionary = config.get(c, {"main": -1.0, "byoyomi": 0})
		_main_time[c] = float(cfg.get("main", -1.0))
		_byoyomi_left[c] = int(cfg.get("byoyomi", 0))
		_byoyomi_time[c] = 0.0
		_in_byoyomi[c] = false
		_timeout_count[c] = 0
	_active = -1
	_paused = false

# 切换行棋方（落子后调用）：停止旧方计时，启动新方
# 每手重置时间为初始值（per-move time 模式，不累计）
func switch_to(color: int) -> void:
	_active = color
	# 每手重置主时间为初始配置值
	var cfg: Dictionary = _config.get(color, {})
	var init_main: float = float(cfg.get("main", -1.0))
	if init_main >= 0:
		_main_time[color] = init_main
	# 重置读秒状态（每手重新开始）
	var byo: int = int(cfg.get("byoyomi", 0))
	if byo > 0:
		_byoyomi_left[color] = byo
		_in_byoyomi[color] = false
		_byoyomi_time[color] = 0.0

# 落子后重置该方连续超时计数（成功行棋后调用）
func reset_timeout_count(color: int) -> void:
	_timeout_count[color] = 0

# 获取该方连续超时次数
func get_timeout_count(color: int) -> int:
	return int(_timeout_count.get(color, 0))

# 推进时间（GameScreen._process 调用）
func tick(delta: float) -> void:
	if _paused or _active < 0:
		return
	var c: int = _active
	# 无限时间不计时
	if _main_time.get(c, -1.0) < 0 and not _in_byoyomi.get(c, false):
		return
	if _in_byoyomi.get(c, false):
		# 读秒倒计时
		_byoyomi_time[c] = _byoyomi_time.get(c, 0.0) - delta
		if _byoyomi_time[c] <= 0.0:
			_byoyomi_left[c] = _byoyomi_left.get(c, 0) - 1
			if _byoyomi_left.get(c, 0) <= 0:
				# 读秒用尽 → 触发单次超时 pass
				_trigger_timeout(c)
				return
			# 重置读秒
			var cfg: Dictionary = _config.get(c, {})
			var byo_dur: float = float(cfg.get("byoyomi_duration", 30.0))
			_byoyomi_time[c] = byo_dur
			time_changed.emit(c)
	else:
		# 主时间倒计时
		_main_time[c] = _main_time.get(c, 0.0) - delta
		if _main_time[c] <= 0.0:
			_main_time[c] = 0.0
			if _byoyomi_left.get(c, 0) > 0:
				# 进入读秒
				_in_byoyomi[c] = true
				var cfg: Dictionary = _config.get(c, {})
				var byo_dur: float = float(cfg.get("byoyomi_duration", 30.0))
				_byoyomi_time[c] = byo_dur
				time_changed.emit(c)
			else:
				# 无读秒 → 触发单次超时 pass
				_trigger_timeout(c)
				return
		time_changed.emit(c)

# 触发单次超时：累加计数，未达上限发 timeout_pass，达上限发 time_out
func _trigger_timeout(c: int) -> void:
	_timeout_count[c] = int(_timeout_count.get(c, 0)) + 1
	if int(_timeout_count[c]) >= MAX_TIMEOUT_PASS:
		# 连续超时达上限 → 判负
		_active = -1
		time_out.emit(c)
	else:
		# 单次超时 → 执行 pass（GameScreen 调用 session.do_pass）
		# 恢复该方时间到初始值，供下一次行棋使用
		var cfg: Dictionary = _config.get(c, {})
		var init_main: float = float(cfg.get("main", -1.0))
		if init_main >= 0:
			_main_time[c] = init_main
		# 重置读秒状态（若有读秒配置）
		var byo: int = int(cfg.get("byoyomi", 0))
		if byo > 0:
			_byoyomi_left[c] = byo
			_in_byoyomi[c] = false
			_byoyomi_time[c] = 0.0
		# 暂停计时，等待 pass 处理后 switch_to 切换
		_active = -1
		timeout_pass.emit(c)

func pause() -> void:
	_paused = true

func resume() -> void:
	_paused = false

# 获取某方剩余时间（用于 UI 显示）
# 返回 { "main": float, "byoyomi_left": int, "byoyomi_time": float, "in_byoyomi": bool }
func get_time(color: int) -> Dictionary:
	return {
		"main": _main_time.get(color, -1.0),
		"byoyomi_left": _byoyomi_left.get(color, 0),
		"byoyomi_time": _byoyomi_time.get(color, 0.0),
		"in_byoyomi": _in_byoyomi.get(color, false),
	}

# 获取行棋方计时进度（0~1，用于环形条）
# 1=满时间，0=耗尽；无限时间返回 -1
func get_progress(color: int) -> float:
	if _main_time.get(color, -1.0) < 0 and not _in_byoyomi.get(color, false):
		return -1.0  # 无限时间
	if _in_byoyomi.get(color, false):
		var cfg: Dictionary = _config.get(color, {})
		var byo_dur: float = float(cfg.get("byoyomi_duration", 30.0))
		if byo_dur <= 0:
			return 0.0
		return _byoyomi_time.get(color, 0.0) / byo_dur
	var init_main: float = float(_config.get(color, {}).get("main", -1.0))
	if init_main <= 0:
		return 0.0
	return _main_time.get(color, 0.0) / init_main
