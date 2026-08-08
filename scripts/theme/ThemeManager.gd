# 主题管理器（autoload）
#
# 职责：
#   - 注册所有可用主题
#   - 持有当前主题
#   - 主题切换时发信号，UI 监听并重绘
#
# 用法：
#   ThemeManager.current  # 当前主题（BaseTheme）
#   ThemeManager.switch_to("cyber")
#   ThemeManager.theme_changed.connect(_on_theme_changed)
extends Node

signal theme_changed(new_theme: BaseTheme)

const DefaultTheme = preload("res://scripts/theme/DefaultTheme.gd")
const PixelClassicTheme = preload("res://scripts/theme/PixelClassicTheme.gd")
const CyberTheme = preload("res://scripts/theme/CyberTheme.gd")

var current: BaseTheme = null
var themes: Array[BaseTheme] = []
var _registry: Dictionary = {}  # id -> BaseTheme

func _ready() -> void:
	register(DefaultTheme.new())
	register(PixelClassicTheme.new())
	register(CyberTheme.new())
	if themes.size() > 0:
		current = themes[0]

# 注册主题
func register(theme: BaseTheme) -> void:
	if _registry.has(theme.id):
		push_warning("主题已注册: %s" % theme.id)
		return
	_registry[theme.id] = theme
	themes.append(theme)

# 切换主题
func switch_to(theme_id: String) -> bool:
	if not _registry.has(theme_id):
		Log.w("主题不存在: %s" % theme_id)
		return false
	current = _registry[theme_id]
	Log.i("主题切换至: %s" % current.display_name)
	theme_changed.emit(current)
	return true

# 取下一个主题（循环切换）
func cycle_next() -> void:
	if themes.is_empty():
		return
	var idx: int = themes.find(current)
	idx = (idx + 1) % themes.size()
	switch_to(themes[idx].id)

# 取主题列表（用于UI显示）
func list_display_names() -> Array:
	var out: Array = []
	for t in themes:
		out.append(t.display_name)
	return out
