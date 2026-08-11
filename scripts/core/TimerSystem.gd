# 对局计时系统：纯逻辑（RefCounted + signal），不依赖 Node
#
# 设计（参考围棋总时间制）：
#   - 每方有 main_time（秒，-1=无限）和 byoyomi（读秒次数，0=无读秒）
#   - 行棋方消耗 main_time；main_time 耗尽后进入读秒
#   - 无读秒时主时间耗尽，或读秒次数用尽 → 直接 time_out 判负
#   - 落子后切换行棋方，不重置已消耗时间（总时间累计制）
#   - 非行棋方不计时
#   - pause/resume 支持暂停菜单
class_name TimerSystem
extends RefCounted

signal time_out(color: int)  # 时间耗尽（含读秒） → 直接判负
signal time_changed(color: int)  # 时间变化通知（UI 刷新）

# 时间配置：{ color: { "main": float(-1=无限), "byoyomi": int(0=无) } }
var _config: Dictionary = {}
# 当前方剩余时间
var _main_time: Dictionary = {}  # color -> float
var _byoyomi_left: Dictionary = {}  # color -> int（剩余读秒次数）
var _byoyomi_time: Dictionary = {}  # color -> float（当前读秒倒计时）
var _in_byoyomi: Dictionary = {}  # color -> bool
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
	for c in [Const.BLACK, Const.WHITE]:
		var cfg: Dictionary = config.get(c, {"main": -1.0, "byoyomi": 0})
		_main_time[c] = float(cfg.get("main", -1.0))
		_byoyomi_left[c] = int(cfg.get("byoyomi", 0))
		_byoyomi_time[c] = 0.0
		_in_byoyomi[c] = false
	_active = -1
	_paused = false

# 切换行棋方（落子后调用）：停止旧方计时，启动新方
# 总时间累计制（参考围棋包干时间）：落子后切换行棋方，不重置该方已消耗的主时间和读秒状态
func switch_to(color: int) -> void:
	_active = color
	# 首次切换到某方（或该方时间未被初始化）时，才用初始配置兜底
	var cfg: Dictionary = _config.get(color, {})
	if not _main_time.has(color):
		_main_time[color] = float(cfg.get("main", -1.0))
		_byoyomi_left[color] = int(cfg.get("byoyomi", 0))
		_in_byoyomi[color] = false
		_byoyomi_time[color] = 0.0

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
				# 读秒用尽 → 直接判负
				_active = -1
				time_out.emit(c)
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
				# 无读秒 → 直接判负
				_active = -1
				time_out.emit(c)
				return
		time_changed.emit(c)

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
