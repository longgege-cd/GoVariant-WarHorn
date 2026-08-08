# 全局常量：棋盘尺寸、领土分区、棋色
# 行号约定（0 基）：
#   黑方领土: 0..8  (规则中第1-9行)
#   边境线:   9     (规则中第10行)
#   白方领土: 10..18(规则中第11-19行)
class_name Const

const BOARD_SIZE: int = 19
const BORDER_ROW: int = 9          # 0基：第10行
const PIECE_LIMIT: int = 171       # 每方兵力上限

# 棋色
const EMPTY: int = 0
const BLACK: int = 1
const WHITE: int = 2

const KOMI_DEFAULT: float = 2.5    # 黑方贴目

# 领土分区枚举
enum Zone { BLACK, BORDER, WHITE }

static func opponent(color: int) -> int:
	return BLACK if color == WHITE else WHITE

# 行 -> 领土分区
static func zone_of_row(row: int) -> int:
	if row < BORDER_ROW:
		return Zone.BLACK
	elif row == BORDER_ROW:
		return Zone.BORDER
	else:
		return Zone.WHITE

# 某色棋的「己方领土」分区
static func own_zone(color: int) -> int:
	return Zone.BLACK if color == BLACK else Zone.WHITE

# 某色棋的「对方领土」分区
static func enemy_zone(color: int) -> int:
	return Zone.WHITE if color == BLACK else Zone.BLACK

# 给定坐标所在的分区
static func zone_of(row: int, _col: int) -> int:
	return zone_of_row(row)

# 该分区是否为某色的「己方领土或边境」（用于防御分判定）
static func is_defense_zone(row: int, color: int) -> bool:
	var z: int = zone_of_row(row)
	return z == Zone.BORDER or z == own_zone(color)

# 该分区是否为某色的「对方领土或边境」（用于占领分判定）
static func is_attack_zone(row: int, color: int) -> bool:
	var z: int = zone_of_row(row)
	return z == Zone.BORDER or z == enemy_zone(color)
