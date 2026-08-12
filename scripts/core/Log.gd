# 全局日志 autoload（轻量，避免依赖 Godot 节点即可调用）
# 调用：Log.i("msg"), Log.w("msg"), Log.e("msg")
# 同时输出到 stdout 和文件 user://logs/game_YYYYMMDD.log（便于 GUI 模式诊断）
extends Node

enum Level { DEBUG, INFO, WARN, ERROR }

var level: int = Level.INFO
var _sink: Callable = Callable()  # 测试时可注入自定义收集器
var _file: FileAccess = null
var _file_day: String = ""

func _ready() -> void:
	_open_file()

func _open_file() -> void:
	var day: String = Time.get_date_string_from_system()
	if _file_day == day and _file != null:
		return
	if _file != null:
		_file.close()
	_file_day = day
	DirAccess.make_dir_recursive_absolute("user://logs")
	_file = FileAccess.open("user://logs/game_%s.log" % day, FileAccess.WRITE)
	if _file == null:
		push_warning("Log: 无法打开日志文件 user://logs/game_%s.log" % day)

func set_sink(s: Callable) -> void:
	_sink = s

func _emit(lvl: int, msg: String) -> void:
	if lvl < level:
		return
	var tag: String = ["D", "I", "W", "E"][lvl]
	var ts: String = Time.get_time_string_from_system()
	var line: String = "[%s][%s] %s" % [tag, ts, msg]
	if _sink.is_valid():
		_sink.call(line)
	else:
		print(line)
	if _file != null:
		_file.store_line(line)
		_file.flush()

func d(msg: String) -> void: _emit(Level.DEBUG, msg)
func i(msg: String) -> void: _emit(Level.INFO, msg)
func w(msg: String) -> void: _emit(Level.WARN, msg)
func e(msg: String) -> void: _emit(Level.ERROR, msg)
