// 服务器运行配置：从环境变量读取可调平衡参数
// 公测用途：部署时无需改代码即可做参数实验（贴目/兵力/计时），
//   每局对局记录会快照当时的参数值，供平衡调参分析。
// 环境变量一览：
//   WARHORN_KOMI                贴目（默认 0.5）
//   WARHORN_PIECE_LIMIT         每方兵力上限（默认 120，v7.3）
//   WARHORN_TIMER_BASE_SEC      正式阶段基础时间（秒，默认 600）
//   WARHORN_TIMER_INCREMENT_SEC 每手加时（秒，默认 0，读秒制已弃用）
//   WARHORN_BYO_PERIOD_SEC      每次读秒秒数（默认 60）
//   WARHORN_BYO_COUNT           读秒次数（默认 5）
//   WARHORN_DEPLOY_TIMER_SEC    布局阶段每方独立时间（秒，默认 60）
//   WARHORN_ADMIN_TOKEN         /admin/stats 访问令牌（空=不鉴权）

import {
  KOMI_DEFAULT,
  PIECE_LIMIT,
  TIMER_BASE_SEC,
  TIMER_INCREMENT_SEC,
  BYO_PERIOD_SEC,
  BYO_COUNT,
  DEPLOY_TIMER_SEC,
} from "@warhorn/engine";

export interface ServerConfig {
  komi: number;
  pieceLimit: number;
  timerBaseSec: number;
  timerIncrementSec: number;
  byoPeriodSec: number; // 每次读秒秒数
  byoCount: number; // 读秒次数
  deployTimerSec: number;
  adminToken: string;
}

function num(env: string | undefined, fallback: number): number {
  if (env === undefined || env === "") return fallback;
  const n = Number(env);
  return Number.isFinite(n) && n >= 0 ? n : fallback;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): ServerConfig {
  return {
    komi: num(env.WARHORN_KOMI, KOMI_DEFAULT),
    pieceLimit: num(env.WARHORN_PIECE_LIMIT, PIECE_LIMIT),
    timerBaseSec: num(env.WARHORN_TIMER_BASE_SEC, TIMER_BASE_SEC),
    timerIncrementSec: num(env.WARHORN_TIMER_INCREMENT_SEC, TIMER_INCREMENT_SEC),
    byoPeriodSec: num(env.WARHORN_BYO_PERIOD_SEC, BYO_PERIOD_SEC),
    byoCount: num(env.WARHORN_BYO_COUNT, BYO_COUNT),
    deployTimerSec: num(env.WARHORN_DEPLOY_TIMER_SEC, DEPLOY_TIMER_SEC),
    adminToken: env.WARHORN_ADMIN_TOKEN ?? "",
  };
}
