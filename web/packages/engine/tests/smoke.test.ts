// 规则引擎烟雾测试：验证核心流程能跑通
// 运行: npx tsx tests/smoke.test.ts

import assert from "node:assert";
import { GameSession } from "../src/GameSession.js";
import { BoardModel } from "../src/BoardModel.js";
import { GoRules } from "../src/GoRules.js";
import { Color, opponent, isAttackZone } from "../src/Const.js";
import { SiegeDetector } from "../src/SiegeDetector.js";
import { TerritoryDetector } from "../src/TerritoryDetector.js";
import { ScoreCalculator } from "../src/ScoreCalculator.js";
import { atariStoneSet, influenceMap } from "../src/StatusDetector.js";

let passed = 0;
let failed = 0;
function check(name: string, cond: boolean, extra?: unknown) {
  if (cond) {
    passed++;
    console.log(`  ✓ ${name}`);
  } else {
    failed++;
    console.error(`  ✗ ${name}`, extra ?? "");
  }
}

console.log("=== 规则引擎烟雾测试 ===\n");

// 测试1: 基本落子
console.log("测试1: 基本落子");
{
  const s = new GameSession({ enableDeployPhase: false });
  const r = s.playMove(Color.BLACK, 9, 9);
  check("黑下 (9,9) 成功", r.ok === true, r.reason);
  check("(9,9) 是黑子", s.board.getAt(9, 9) === Color.BLACK);
  check("轮白", s.toMove === Color.WHITE);
  check("ply=1", s.ply === 1);
}

// 测试2: 提子
console.log("\n测试2: 提子");
{
  const s = new GameSession({ enableDeployPhase: false });
  // 白子在 (5,5)，黑子围四周
  s.board.setAt(5, 5, Color.WHITE);
  s.board.setAt(4, 5, Color.BLACK);
  s.board.setAt(6, 5, Color.BLACK);
  s.board.setAt(5, 4, Color.BLACK);
  // 黑下 (5,6) 提白
  s.toMove = Color.BLACK;
  const r = s.playMove(Color.BLACK, 5, 6);
  check("黑下 (5,6) 提白", r.ok === true && (r.captures?.length ?? 0) === 1, r);
  check("(5,5) 变空", s.board.getAt(5, 5) === Color.EMPTY);
}

// 测试3: 自杀禁着
console.log("\n测试3: 自杀禁着");
{
  const s = new GameSession({ enableDeployPhase: false });
  // 白子完全围 (5,5) 四面
  s.board.setAt(4, 5, Color.WHITE);
  s.board.setAt(6, 5, Color.WHITE);
  s.board.setAt(5, 4, Color.WHITE);
  s.board.setAt(5, 6, Color.WHITE);
  s.toMove = Color.BLACK;
  const r = s.playMove(Color.BLACK, 5, 5); // 自杀（无气且未提子）
  check("黑下 (5,5) 自杀禁着", r.ok === false && r.reason === "自杀禁着", r);
  check("(5,5) 仍空", s.board.getAt(5, 5) === Color.EMPTY);
}

// 测试4: 虚手限制
console.log("\n测试4: 虚手限制");
{
  const s = new GameSession({ enableDeployPhase: false });
  // 黑第1次虚手
  const p1 = s.doPass(Color.BLACK);
  check("黑第1次虚手成功", p1.ok === true, p1.reason);
  // 白下子 → 黑下子（消耗1己方回合）→ 白下子 → 黑下子（消耗2己方回合，冷却满）
  s.toMove = Color.WHITE; s.playMove(Color.WHITE, 9, 9);
  s.toMove = Color.BLACK; s.playMove(Color.BLACK, 10, 10);
  s.toMove = Color.WHITE; s.playMove(Color.WHITE, 11, 11);
  s.toMove = Color.BLACK; s.playMove(Color.BLACK, 12, 12);
  // 黑第2次虚手（冷却满2己方回合）
  s.toMove = Color.BLACK;
  const p2 = s.doPass(Color.BLACK);
  check("黑第2次虚手成功（冷却满）", p2.ok === true, p2.reason);
  // 黑第3次虚手（超过每局2次上限）：需先消耗冷却
  s.toMove = Color.WHITE; s.playMove(Color.WHITE, 13, 13);
  s.toMove = Color.BLACK; s.playMove(Color.BLACK, 14, 14);
  s.toMove = Color.WHITE; s.playMove(Color.WHITE, 15, 15);
  s.toMove = Color.BLACK; s.playMove(Color.BLACK, 16, 16);
  s.toMove = Color.WHITE; s.playMove(Color.WHITE, 17, 17);
  s.toMove = Color.BLACK;
  const p3 = s.doPass(Color.BLACK);
  check("黑第3次虚手被拒（每局2次上限）", p3.ok === false && (p3.reason?.includes("用尽") ?? false), p3.reason);
}

// 测试5: 连续虚手终局
console.log("\n测试5: 连续虚手终局");
{
  const s = new GameSession({ enableDeployPhase: false });
  s.doPass(Color.BLACK);
  s.toMove = Color.WHITE;
  const r = s.doPass(Color.WHITE);
  check("白虚手后终局", r.ok === true && r.gameOver === true, r);
  check("gameOver=true", s.gameOver === true);
  check("有最终结果", s.lastFinalResult !== null);
}

// 测试6: 围空计分
console.log("\n测试6: 围空计分");
{
  const s = new GameSession({ enableDeployPhase: false });
  // 黑子完全围 (11,6) 一个空点（在白方领土 row 10..18，对黑是攻击区）
  // 完整包围：(10,5)(10,6)(10,7) / (11,5)(11,7) / (12,5)(12,6)(12,7)
  s.board.setAt(10, 5, Color.BLACK);
  s.board.setAt(10, 6, Color.BLACK);
  s.board.setAt(10, 7, Color.BLACK);
  s.board.setAt(11, 5, Color.BLACK);
  s.board.setAt(11, 7, Color.BLACK);
  s.board.setAt(12, 5, Color.BLACK);
  s.board.setAt(12, 6, Color.BLACK);
  s.board.setAt(12, 7, Color.BLACK);
  // (11,6) 是空点，被黑完全围
  const encs = TerritoryDetector.enclosures(s.board);
  const blackEncs = encs.filter((e) => e.color === Color.BLACK);
  check("检测到黑方围空圈", blackEncs.length > 0, encs);
  if (blackEncs.length > 0) {
    const totalPoints = blackEncs.reduce((sum, e) => sum + e.points.length, 0);
    check("围空点数≥1", totalPoints >= 1, totalPoints);
  }
  // 计分：(11,6) 在白方领土，对黑是攻击区，应计围空分 +2
  const scores = s.scores();
  check("黑方围空分>0", scores.black.occupationTerritory > 0, scores.black);
}

// 测试7: 死活判定
console.log("\n测试7: 死活判定");
{
  const board = new BoardModel();
  // 黑子在角落，两眼活
  // (0,0) (0,2) 黑子，(0,1) 空 = 眼1
  // (1,0) (1,2) 黑子，(1,1) 空 = 眼2
  // (2,0) (2,1) (2,2) 黑子封底
  board.setAt(0, 0, Color.BLACK);
  board.setAt(0, 2, Color.BLACK);
  board.setAt(1, 0, Color.BLACK);
  board.setAt(1, 2, Color.BLACK);
  board.setAt(2, 0, Color.BLACK);
  board.setAt(2, 1, Color.BLACK);
  board.setAt(2, 2, Color.BLACK);
  const groups = board.allGroups();
  const blackGroup = groups.find((g) => g.color === Color.BLACK);
  check("找到黑组群", blackGroup !== undefined);
  if (blackGroup) {
    const da = SiegeDetector.solveDeadAlive(board);
    // 用内容比较（allGroups 每次返回新对象）
    const isAlive = da.alive.some((g) =>
      g.color === blackGroup.color && g.stones.length === blackGroup.stones.length
    );
    check("角落两眼黑棋活", isAlive, da);
  }
}

// 测试8: 兵力上限
console.log("\n测试8: 兵力上限");
{
  const s = new GameSession({ pieceLimit: 2, enableDeployPhase: false });
  s.playMove(Color.BLACK, 9, 9);
  s.toMove = Color.WHITE;
  s.playMove(Color.WHITE, 10, 10);
  s.toMove = Color.BLACK;
  s.playMove(Color.BLACK, 9, 10);
  s.toMove = Color.WHITE;
  s.playMove(Color.WHITE, 10, 11);
  s.toMove = Color.BLACK;
  const r = s.playMove(Color.BLACK, 9, 11);
  check("兵力用尽时拒绝落子", r.ok === false && r.reason === "兵力已用尽", r);
}

// 测试9: 打吃检测（剩最后一口气）
console.log("\n测试9: 打吃检测");
{
  const board = new BoardModel();
  // 白子 (5,5) 被黑围三面，只剩 (5,6) 一口气 → 打吃
  board.setAt(5, 5, Color.WHITE);
  board.setAt(4, 5, Color.BLACK);
  board.setAt(6, 5, Color.BLACK);
  board.setAt(5, 4, Color.BLACK);
  const atari = atariStoneSet(board);
  check("白单子被打吃", atari.has(5 * 19 + 5), atari);
  // 黑棋块有多口气 → 非打吃
  const board2 = new BoardModel();
  board2.setAt(3, 3, Color.BLACK);
  board2.setAt(3, 4, Color.BLACK);
  const atari2 = atariStoneSet(board2);
  check("黑棋块多口气非打吃", !atari2.has(3 * 19 + 3) && !atari2.has(3 * 19 + 4), atari2);
}

// 测试10: 势力热力图
console.log("\n测试10: 势力热力图");
{
  const board = new BoardModel();
  board.setAt(9, 9, Color.BLACK);
  board.setAt(10, 10, Color.WHITE);
  const infl = influenceMap(board);
  // 黑子左侧紧邻点应为正（黑方势力）
  check("黑子左侧紧邻点黑方势力>0", infl[9 * 19 + 8] > 0, infl[9 * 19 + 8]);
  // 白子左侧两格点应为负（白方势力；紧邻点 (10,9) 恰被黑子正下方影响抵消为 0）
  check("白子左侧两格点白方势力<0", infl[10 * 19 + 8] < 0, infl[10 * 19 + 8]);
  // 远处点影响力弱于近处
  check("近处影响力 > 远处", infl[9 * 19 + 8] > infl[9 * 19 + 3], [infl[9 * 19 + 8], infl[9 * 19 + 3]]);
  // 棋子本身位置无影响（值为0，因为只计算空点延伸）
  check("棋子位置本身无影响", infl[9 * 19 + 9] === 0, infl[9 * 19 + 9]);
}

console.log(`\n=== 结果: ${passed} 通过, ${failed} 失败 ===`);
if (failed > 0) process.exit(1);
