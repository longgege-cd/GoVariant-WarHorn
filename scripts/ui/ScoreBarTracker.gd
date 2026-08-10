# 分数条动态基准追踪器
# 用固定参考上限计算条形长度，分数从0增长时条形真正变长（而非在固定槽内按比例填充）
# 独立于 UI 节点与 autoload，便于单元测试
extends RefCounted

# 固定参考上限（基于中等偏上对局的合理高分）
# 占领分=活子(1/子)+围空(2/点)，兵力上限171但实际对局中高分约80
# 防御分=歼灭(2/子)+围困(1/子)，高分约40
# 战损分=战损(-1/子)，高分约30
const REF_MAX := {"occ": 80, "def": 40, "cas": 30}


func reset() -> void:
	pass  # 固定上限无需重置


# 兼容旧接口：无操作（固定上限不需要更新）
func update(_my_bk, _opp_bk = null) -> void:
	pass


func get_max(key: String) -> int:
	return int(REF_MAX.get(key, 1))


func get_ratio(key: String, current: int) -> float:
	var m: int = get_max(key)
	if m <= 0:
		return 0.0
	return clamp(float(current) / float(m), 0.0, 1.0)
