// 常量定义：棋盘尺寸、颜色、领土分区、贴目、兵力上限、虚手规则、计时配置
// 与 GDScript c:\边境线\scripts\core\Const.gd 对齐

export const BOARD_SIZE = 19;
export const BORDER_ROW = 9; // 0基：第10行 = 边境线
export const PIECE_LIMIT = 120; // 每方兵力上限 v7.3（与桌面端 Const.gd 默认一致）
export const KOMI_DEFAULT = 0.5; // 白方贴目（黑方扣贴目）

export const Color = {
  EMPTY: 0,
  BLACK: 1,
  WHITE: 2,
} as const;
export type Color = (typeof Color)[keyof typeof Color];

export const Zone = {
  BLACK: 0, // 黑方领土（row 0..8）
  BORDER: 1, // 边境线（row 9）
  WHITE: 2, // 白方领土（row 10..18）
} as const;
export type Zone = (typeof Zone)[keyof typeof Zone];

// 虚手规则（规划文档 §3）
export const PASS_LIMIT_PER_GAME = 2; // 每方每局虚手次数上限
export const PASS_COOLDOWN_TURNS = 2; // 冷却：自上次虚手后需 2 个己方实际行棋回合

// 计时配置（规划 v9/V 阶段：围棋比赛读秒制，主限时 + 读秒 N 次，不再每手加时）
export const TIMER_BASE_SEC = 10 * 60; // 主限时 10 分钟
export const TIMER_INCREMENT_SEC = 0; // 已弃用：读秒制裁去每手加时（保持字段为 0 以兼容）
export const BYO_PERIOD_SEC = 60; // 每次读秒 60 秒
export const BYO_COUNT = 5; // 读秒 5 次

// 布局阶段（规划文档 §3：前4手必须落己方领土）
export const DEPLOY_PHASE_MOVES = 4; // 黑1白1黑2白2
export const DEPLOY_STONES_PER_SIDE = 2;
export const DEPLOY_TIMER_SEC = 60; // 布局阶段每方独立计时（1分钟）

// 匹配确认超时
export const MATCH_CONFIRM_TIMEOUT_SEC = 10;

// 战争迷雾（可选规则）：第30手（总手数）黎明，迷雾消散、全盘可见
export const FOG_DAWN_PLY = 30;
export const FOG_VISION_RADIUS = 2; // 曼哈顿距离≤2 可见

export function opponent(color: Color): Color {
  return color === Color.WHITE ? Color.BLACK : Color.WHITE;
}

export function zoneOfRow(row: number): Zone {
  if (row < BORDER_ROW) return Zone.BLACK;
  if (row === BORDER_ROW) return Zone.BORDER;
  return Zone.WHITE;
}

export function ownZone(color: Color): Zone {
  return color === Color.BLACK ? Zone.BLACK : Zone.WHITE;
}

export function enemyZone(color: Color): Zone {
  return color === Color.BLACK ? Zone.WHITE : Zone.BLACK;
}

// 防御区：己方领土 ∪ 边境（用于围困分/歼灭分）
export function isDefenseZone(row: number, color: Color): boolean {
  const z = zoneOfRow(row);
  return z === Zone.BORDER || z === ownZone(color);
}

// 攻击区：对方领土 ∪ 边境（用于活子分/围空分）
export function isAttackZone(row: number, color: Color): boolean {
  const z = zoneOfRow(row);
  return z === Zone.BORDER || z === enemyZone(color);
}
