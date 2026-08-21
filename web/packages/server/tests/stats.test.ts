// 聚合统计单元测试：验证 computeStats 对平衡采集字段的聚合正确性
// 纯函数测试，无需启动服务器。用法：npx tsx packages/server/tests/stats.test.ts

import { computeStats } from "../src/Stats.js";
import type { GameRecord } from "../src/Store.js";

function record(over: Partial<GameRecord>): GameRecord {
  return {
    id: "r",
    black: "A",
    white: "B",
    winner: "黑方胜",
    winnerColor: 1,
    reason: "双方连续虚手",
    ply: 80,
    finalBlack: 50,
    finalWhite: 45,
    endedAt: Date.now(),
    komi: 0.5,
    pieceLimit: 120,
    timerBaseSec: 600,
    timerIncrementSec: 10,
    endCategory: "pass",
    durationSec: 600,
    scoreDiff: 5,
    stonesBlack: 60,
    stonesWhite: 58,
    passBlack: 1,
    passWhite: 1,
    captureBlack: 3,
    captureWhite: 2,
    breakdownBlack: {
      occupationLive: 20, occupationTerritory: 10, occupationEfficiency: 2, defenseAnnihilate: 6,
      defenseSiege: 4, casualtyLoss: -3, casualtySpecial: 0,
    },
    breakdownWhite: {
      occupationLive: 18, occupationTerritory: 8, occupationEfficiency: 0, defenseAnnihilate: 4,
      defenseSiege: 2, casualtyLoss: -6, casualtySpecial: 0,
    },
    ...over,
  };
}

const r1 = record({});
const r2 = record({
  winner: "白方胜", winnerColor: 2, scoreDiff: -5, finalBlack: 45, finalWhite: 50,
  endCategory: "resign", durationSec: 300, ply: 40,
});
const r3 = record({
  winner: "和棋", winnerColor: 0, scoreDiff: 0, endCategory: "timeout",
  komi: 7.5, pieceLimit: 90, timerBaseSec: 300, timerIncrementSec: 30,
  ply: 80, durationSec: 300,
});

const s = computeStats([r1, r2, r3]);
const assert = (cond: boolean, msg: string): void => {
  if (!cond) throw new Error(`断言失败: ${msg}`);
};

assert(s.totalGames === 3, "totalGames=3");
assert(s.blackWins === 1, "blackWins=1");
assert(s.whiteWins === 1, "whiteWins=1");
assert(s.draws === 1, "draws=1");
assert(s.blackWinRate === 0.5, "blackWinRate=0.5");
assert(s.avgScoreDiff === 0, `avgScoreDiff=0 (实际 ${s.avgScoreDiff})`);
assert(s.avgPly === 200 / 3, `avgPly=200/3 (实际 ${s.avgPly})`);
assert(s.avgDurationSec === 400, `avgDurationSec=400 (实际 ${s.avgDurationSec})`);
assert(s.endReasonCounts.pass === 1 && s.endReasonCounts.resign === 1 && s.endReasonCounts.timeout === 1, "终局原因分布");
assert(s.forfeitCount === 2, "认输+超时 = 2 局");
assert(s.avgForfeitScoreDiff === -2.5, `认输/超时局平均分差=-2.5 (实际 ${s.avgForfeitScoreDiff})`);
assert(s.avgStones!.black === 60, `avgStones.black=60 (实际 ${s.avgStones!.black})`);
assert(s.avgCaptures!.black === 3 && s.avgCaptures!.white === 2, "平均提吃数");
assert(s.avgBreakdownBlack!.occupationLive === 20, "avgBreakdownBlack.occupationLive");
assert(s.avgBreakdownBlack!.defenseAnnihilate === 6, "avgBreakdownBlack.defenseAnnihilate");
assert(s.paramsSeen.length === 2, `参数分组=2 (实际 ${s.paramsSeen.length})`);
const p1 = s.paramsSeen.find((p) => p.komi === 0.5)!;
assert(p1.games === 2, "默认参数组 2 局");

// 空数据边界
const empty = computeStats([]);
assert(empty.totalGames === 0, "空数据 totalGames=0");
assert(empty.blackWinRate === null && empty.avgScoreDiff === null && empty.avgBreakdownBlack === null, "空数据聚合为 null");

console.log("=== 聚合统计测试全部通过 ===");
console.log(JSON.stringify({ totalGames: s.totalGames, blackWinRate: s.blackWinRate, endReasonCounts: s.endReasonCounts, paramsSeen: s.paramsSeen }, null, 2));
