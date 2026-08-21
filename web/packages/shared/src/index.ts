// 共享类型：WebSocket 协议消息、玩家/房间数据结构
// 前后端共用，避免类型漂移

export type PlayerStatus = "lobby" | "matching" | "practice" | "playing";

export interface Player {
  id: string; // Socket.id
  name: string; // 临时名字
  status: PlayerStatus;
  roomId?: string;
}

export type RoomStatus = "confirming" | "deployment" | "battle" | "ended";

export interface GameRoom {
  id: string;
  black: Player;
  white: Player;
  boardState: SerializedBoard;
  currentTurn: PlayerColor;
  timers: { black: number; white: number };
  moveCount: number;
  status: RoomStatus;
  confirmations: { black: boolean; white: boolean };
}

// 颜色常量（与 engine 一致，独立定义避免循环依赖）
export const PlayerColor = {
  EMPTY: 0,
  BLACK: 1,
  WHITE: 2,
} as const;
export type PlayerColor = (typeof PlayerColor)[keyof typeof PlayerColor];

// 序列化棋盘（用于网络传输）
export interface SerializedBoard {
  size: number;
  grid: number[]; // 长度 size*size，值 = PlayerColor
}

// 落子结果
export interface MoveOutcome {
  ok: boolean;
  reason?: string;
  moverColor: PlayerColor;
  placed?: { row: number; col: number }; // 虚手时为 {row:-1,col:-1}
  passed?: boolean;
  captures?: Array<{ row: number; col: number }>;
  capturedColor?: PlayerColor;
  ply?: number;
  gameOver?: boolean;
  result?: FinalResult;
  undid?: boolean; // 悔棋
  // 战争迷雾（可选规则）
  encounter?: boolean; // 遭遇战：本手落点被对方隐藏棋子占据，触发弹子/吞子
  revealed?: Array<{ row: number; col: number }>; // 遭遇战/黎明现形的对方隐藏棋子
  dawn?: boolean; // 本手后第30手黎明，迷雾消散
}

// 分数明细
export interface ScoreBreakdown {
  occupationLive: number; // 遗留字段（v7.3 已取消活子分，恒为0）
  occupationTerritory: number; // 围空分 +2/点
  occupationEfficiency: number; // 效率奖励 2×(⌊有效围空点数/4⌋)
  defenseAnnihilate: number; // 歼灭分 +3/子（己方领土/边境）
  defenseSiege: number; // 围困分 +2/子（己方领土/边境）
  casualtyLoss: number; // 普通战损 -1/子（负值）
  casualtySpecial: number; // 特种战损 -6/子（负值，MVP不用）
}

export interface ScoreSide {
  breakdown: ScoreBreakdown;
  total: number;
  komi: number;
  final: number;
}

export interface FinalResult {
  black: ScoreSide;
  white: ScoreSide;
  winner: string;
  winnerColor: PlayerColor;
  reason: string;
  ply: number;
}

// ====== WebSocket 事件类型 ======
export const ClientEvent = {
  LOBBY_JOIN: "lobby:join",
  MATCH_REQUEST: "match:request",
  MATCH_CONFIRM: "match:confirm",
  MATCH_DECLINE: "match:decline",
  PRACTICE_START: "practice:start",
  PRACTICE_END: "practice:end",
  MOVE_PLACE: "move:place",
  MOVE_PASS: "move:pass",
  RESIGN: "resign",
} as const;

export const ServerEvent = {
  LOBBY_UPDATE: "lobby:update",
  MATCH_FOUND: "match:found",
  MATCH_CANCELLED: "match:cancelled",
  GAME_START: "game:start",
  GAME_UPDATE: "game:update",
  GAME_OVER: "game:over",
  TIME_UPDATE: "time:update",
  ERROR: "error",
} as const;

export type ClientEventType = (typeof ClientEvent)[keyof typeof ClientEvent];
export type ServerEventType = (typeof ServerEvent)[keyof typeof ServerEvent];

// 服务器推送的负载
export interface LobbyUpdatePayload {
  onlineCount: number;
  matchingCount: number;
}

export interface MatchFoundPayload {
  roomId: string;
  opponentName: string;
  ownColor: PlayerColor;
  confirmTimeoutSec: number;
}

export interface GameStartPayload {
  roomId: string;
  blackName: string;
  whiteName: string;
  ownColor: PlayerColor;
  initialState: SerializedBoard;
  baseTimeSec: number;
  incrementSec: number; // 已弃用：读秒制裁去每手加时（恒为 0，兼容）
  byoPeriodSec: number; // 每次读秒秒数
  byoCount: number; // 读秒次数
  komi: number; // 本局贴目（黑方扣减）
  pieceLimit: number; // 本局每方兵力上限
}

// 读秒制计时快照（围棋比赛：主时 + 读秒N次）
export interface ColorTimer {
  main: number; // 剩余主时间（秒）
  inByoyomi: boolean; // 是否在读秒
  byoRemaining: number; // 剩余读秒次数
  byoCur: number; // 当前读秒剩余（秒）
}

export type TimersState = { black: ColorTimer; white: ColorTimer };

export interface GameUpdatePayload {
  outcome: MoveOutcome;
  board: SerializedBoard;
  currentTurn: PlayerColor;
  timers: TimersState;
  scores: { black: ScoreSide; white: ScoreSide };
  stonesPlaced: { black: number; white: number }; // 双方已用兵力（剩余 = pieceLimit - stonesPlaced）
}

export interface TimeUpdatePayload {
  black: ColorTimer;
  white: ColorTimer;
}

export interface GameOverPayload {
  winner: PlayerColor;
  reason: string;
  finalResult: FinalResult;
}

export interface ErrorPayload {
  message: string;
  code?: string;
}

// 服务器当前生效的游戏设置（大厅展示用，来自 GET /api/config）
export interface GameConfig {
  komi: number; // 贴目（黑方扣减）
  pieceLimit: number; // 每方兵力上限
  timerBaseSec: number; // 正式阶段基础时间（秒）
  timerIncrementSec: number; // 已弃用：读秒制裁去每手加时（恒为0）
  byoPeriodSec: number; // 每次读秒秒数
  byoCount: number; // 读秒次数
  deployTimerSec: number; // 布局阶段每方独立时间（秒）
}
