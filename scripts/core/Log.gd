# 全局日志 autoload（轻量，避免依赖 Godot 节点即可调用）
extends Node
# 调用：Log.i("msg"), Log.w("msg"), Log.e("msg")

enum Level { DEBUG, INFO, WARN, ERROR }

var level: int = Level.INFO
var _sink: Callable = Callable()  # 测试时可注入自定义收集器

func set_sink(s: Callable) -> void:
	_sink = s

func _emit(lvl: int, msg: String) -> void:
	if lvl < level:
		return
	var tag: String = ["D", "I", "W", "E"][lvl]
	var line: String = "[%s] %s" % [tag, msg]
	if _sink.is_valid():
		_sink.call(line)
	else:
		print(line)

func d(msg: String) -> void: _emit(Level.DEBUG, msg)
func i(msg: String) -> void: _emit(Level.INFO, msg)
func w(msg: String) -> void: _emit(Level.WARN, msg)
func e(msg: String) -> void: _emit(Level.ERROR, msg)
