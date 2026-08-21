// 对局记录聚合统计（/admin/stats 输出源）
// 纯函数：输入 GameRecord[]，输出各维度聚合值，无副作用、可独立测试。
// 防膨胀：不新增落盘文件，运行时对已限容的 games.json 做一次性聚合。

import type { ScoreBreakdown } from "@warhorn/shared";
import type { EndCategory, GameRecord } from "./Store.js";

export interface AvgBreakdown {
  occupationLive: number;
  occupationTerritory: number;
  occupationEfficiency: number;
  defenseAnnihilate: number;
  defenseSiege: number;
  casualtyLoss: number;
  casualtySpecial: number;
}

export interface GameStats {
  generatedAt: number;
  totalGames: number;
  // 胜负
  blackWins: number;
  whiteWins: number;
  draws: number;
  blackWinRate: number | null; // 有胜负对局中的黑方胜率
  // 贴目合理性：黑方相对分差分布
  avgScoreDiff: number | null;
  // 对局规模/节奏
  avgPly: number | null;
  avgDurationSec: number | null;
  // 终局原因分布
  endReasonCounts: Record<EndCategory, number>;
  // 认输/超时/断线时的平均分差（"绝望阈值"参考）
  forfeitCount: number;
  avgForfeitScoreDiff: number | null;
  // 得分构成
  avgBreakdownBlack: AvgBreakdown | null;
  avgBreakdownWhite: AvgBreakdown | null;
  // 兵力/虚手/提吃
  avgStones: { black: number; white: number } | null;
  avgPass: { black: number; white: number } | null;
  avgCaptures: { black: number; white: number } | null;
  // 参数分组（若未来做参数实验，可对比不同参数下的胜率）
  paramsSeen: Array<{
    komi: number;
    pieceLimit: number;
    timerBaseSec: number;
    timerIncrementSec: number;
    games: number;
  }>;
}

function avgOf(values: number[]): number | null {
  return values.length === 0 ? null : values.reduce((a, b) => a + b, 0) / values.length;
}

function avgBreakdown(values: ScoreBreakdown[]): AvgBreakdown | null {
  if (values.length === 0) return null;
  const sum: AvgBreakdown = {
    occupationLive: 0,
    occupationTerritory: 0,
    occupationEfficiency: 0,
    defenseAnnihilate: 0,
    defenseSiege: 0,
    casualtyLoss: 0,
    casualtySpecial: 0,
  };
  for (const v of values) {
    sum.occupationLive += v.occupationLive;
    sum.occupationTerritory += v.occupationTerritory;
    sum.occupationEfficiency += v.occupationEfficiency;
    sum.defenseAnnihilate += v.defenseAnnihilate;
    sum.defenseSiege += v.defenseSiege;
    sum.casualtyLoss += v.casualtyLoss;
    sum.casualtySpecial += v.casualtySpecial;
  }
  const n = values.length;
  return {
    occupationLive: sum.occupationLive / n,
    occupationTerritory: sum.occupationTerritory / n,
    occupationEfficiency: sum.occupationEfficiency / n,
    defenseAnnihilate: sum.defenseAnnihilate / n,
    defenseSiege: sum.defenseSiege / n,
    casualtyLoss: sum.casualtyLoss / n,
    casualtySpecial: sum.casualtySpecial / n,
  };
}

export function computeStats(games: GameRecord[]): GameStats {
  const decided = games.filter((g) => g.winnerColor === 1 || g.winnerColor === 2); // BLACK=1, WHITE=2
  const blackWins = decided.filter((g) => g.winnerColor === 1).length;
  const whiteWins = decided.filter((g) => g.winnerColor === 2).length;
  const draws = games.length - decided.length;

  const scoreDiffs: number[] = [];
  const plies: number[] = [];
  const durations: number[] = [];
  const forfeitDiffs: number[] = [];
  const stones: { black: number; white: number }[] = [];
  const passes: { black: number; white: number }[] = [];
  const captures: { black: number; white: number }[] = [];
  const bkBreakdowns: ScoreBreakdown[] = [];
  const wtBreakdowns: ScoreBreakdown[] = [];
  const endReasonCounts: Record<EndCategory, number> = {
    pass: 0,
    resign: 0,
    timeout: 0,
    disconnect: 0,
  };
  const paramsMap = new Map<string, { komi: number; pieceLimit: number; timerBaseSec: number; timerIncrementSec: number; games: number }>();

  for (const g of games) {
    // 兼容旧格式记录：新平衡字段缺失时跳过对应维度，避免 NaN
    if (typeof g.scoreDiff === "number") scoreDiffs.push(g.scoreDiff);
    if (typeof g.ply === "number") plies.push(g.ply);
    if (typeof g.durationSec === "number") durations.push(g.durationSec);
    if (g.endCategory !== "pass" && typeof g.scoreDiff === "number") forfeitDiffs.push(g.scoreDiff);
    if (typeof g.stonesBlack === "number" && typeof g.stonesWhite === "number") {
      stones.push({ black: g.stonesBlack, white: g.stonesWhite });
    }
    if (typeof g.passBlack === "number" && typeof g.passWhite === "number") {
      passes.push({ black: g.passBlack, white: g.passWhite });
    }
    if (typeof g.captureBlack === "number" && typeof g.captureWhite === "number") {
      captures.push({ black: g.captureBlack, white: g.captureWhite });
    }
    if (g.breakdownBlack && g.breakdownWhite) {
      bkBreakdowns.push(g.breakdownBlack);
      wtBreakdowns.push(g.breakdownWhite);
    }
    if (g.endCategory in endReasonCounts) endReasonCounts[g.endCategory] += 1;

    // 仅对携带参数快照的新记录做参数分组
    if (typeof g.komi === "number" && typeof g.pieceLimit === "number") {
      const key = `${g.komi}|${g.pieceLimit}|${g.timerBaseSec}|${g.timerIncrementSec}`;
      const group = paramsMap.get(key);
      if (group) group.games += 1;
      else paramsMap.set(key, { komi: g.komi, pieceLimit: g.pieceLimit, timerBaseSec: g.timerBaseSec, timerIncrementSec: g.timerIncrementSec, games: 1 });
    }
  }

  const avgStones = stones.length
    ? { black: stones.reduce((a, s) => a + s.black, 0) / stones.length, white: stones.reduce((a, s) => a + s.white, 0) / stones.length }
    : null;
  const avgPass = passes.length
    ? { black: passes.reduce((a, s) => a + s.black, 0) / passes.length, white: passes.reduce((a, s) => a + s.white, 0) / passes.length }
    : null;
  const avgCaptures = captures.length
    ? { black: captures.reduce((a, s) => a + s.black, 0) / captures.length, white: captures.reduce((a, s) => a + s.white, 0) / captures.length }
    : null;

  return {
    generatedAt: Date.now(),
    totalGames: games.length,
    blackWins,
    whiteWins,
    draws,
    blackWinRate: decided.length > 0 ? blackWins / decided.length : null,
    avgScoreDiff: avgOf(scoreDiffs),
    avgPly: avgOf(plies),
    avgDurationSec: avgOf(durations),
    endReasonCounts,
    forfeitCount: forfeitDiffs.length,
    avgForfeitScoreDiff: avgOf(forfeitDiffs),
    avgBreakdownBlack: avgBreakdown(bkBreakdowns),
    avgBreakdownWhite: avgBreakdown(wtBreakdowns),
    avgStones,
    avgPass,
    avgCaptures,
    paramsSeen: [...paramsMap.values()].sort((a, b) => b.games - a.games),
  };
}
