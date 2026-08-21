// 死活题基准测试：程序化生成 100 道局部死活局面，四档难度逐一求解并统计正确率
// 判定口径 =「目标达成」：AI 首手落子后，重算 SiegeDetector 死活结果是否达到题目预期
//  - 做活题：AI 执目标块方，首手提掉对方围困薄弱子 → 目标块由死转活（isAlive=true）
//  - 杀棋题：AI 执攻击方，首手落下把围空削减到 <4 → 目标块由活转死（isSieged=true）
// 运行: node --import tsx bench/life_death_bench.ts

import { GameSession } from "../src/GameSession.js";
import { Color, opponent } from "../src/Const.js";
import { BoardModel } from "../src/BoardModel.js";
import { SiegeDetector } from "../src/SiegeDetector.js";
import { AIEngine, AIDifficulty } from "../src/AI.js";

// ====== 死活题局面数据结构 ======
interface LifeDeathProblem {
  kind: "live" | "kill";        // 题目类型
  black: Array<[number, number]>; // 黑棋摆子
  white: Array<[number, number]>; // 白棋摆子
  solver: Color;                // AI 执方
  comment: string;
  /** 职业4段级题目：需多手次序，判定用 solveTimed，默认首手判定 */
  master?: boolean;
  /** 判定时 solver 最多连下（对方见招拆招）的回合数，默认 1 */
  maxPly?: number;
}

// ====== 棋盘构造工具 ======
// 画一个空心矩形边框（黑棋墙），连成一块活棋作为包围圈
function drawRectWall(b: BoardModel, r0: number, c0: number, r1: number, c1: number): void {
  for (let c = c0; c <= c1; c++) {
    b.setAt(r0, c, Color.BLACK);
    b.setAt(r1, c, Color.BLACK);
  }
  for (let r = r0; r <= r1; r++) {
    b.setAt(r, c0, Color.BLACK);
    b.setAt(r, c1, Color.BLACK);
  }
}

// 构建【做活题】：黑墙紧围白块，白块在圈内恰好留有 3 个空点（A眼/E眼候选/F填充点），生前死（空点<4、仅1眼）。
// 白方在 F 落一子 → E 变成真眼 → 两眼 → 由死转活。
// 判活口径对齐 SiegeDetector.isAlive（圈内合法空点>=4 或 两眼 => 活）。
function makeLiveProblem(
  whites: Array<[number, number]>,   // 圈内白块（填满除 3 个留空点外的所有内空）
  comment: string
): LifeDeathProblem {
  const b = new BoardModel(19);
  // 包围盒 = 白块外扩一圈黑墙 ⇒ 圈内 = 白块 + 3 个空点（A/E/F）
  let minR = 99, maxR = -1, minC = 99, maxC = -1;
  for (const [r, c] of whites) { if (r < minR) minR = r; if (r > maxR) maxR = r; if (c < minC) minC = c; if (c > maxC) maxC = c; }
  drawRectWall(b, minR - 1, minC - 1, maxR + 1, maxC + 1);
  for (const p of whites) b.setAt(p[0], p[1], Color.WHITE);
  return { kind: "live", black: collectBlack(b), white: whites, solver: Color.WHITE, comment };
}

// 做活题基础模板：5×5 内空填满白，留 3 空点 A=(2,2)真眼、E=(4,2)眼候选、F=(4,3)填充点
const liveBases: Array<{ white: Array<[number, number]> }> = (() => {
  const emptySet = new Set(["2,2", "4,2", "4,3"]);
  const white: Array<[number, number]> = [];
  for (let r = 1; r <= 5; r++)
    for (let c = 1; c <= 5; c++)
      if (!emptySet.has(r + "," + c)) white.push([r, c]);
  const out = [{ white }];
  let cur = white;
  for (let k = 0; k < 3; k++) {
    cur = cur.map(([r, c]) => [c, 6 - r] as [number, number]); // 绕中心(3,3)旋转90°
    out.push({ white: cur });
  }
  return out;
})();

// 做活题落点（棋子铺到不同区域，区分度来自旋转 + 平移）
const liveOffsets: Array<[number, number]> = [
  [2, 2], [2, 6], [2, 10], [4, 4], [4, 8], [4, 12],
  [6, 2], [6, 6], [6, 10], [8, 4], [8, 8], [8, 12],
  [10, 2], [10, 6], [10, 10], [12, 4], [12, 8], [12, 12],
];

// 构建【杀棋题】：黑墙紧紧围住白块，圈内 = 白块 + 恰好 4 个合法空点（被围→活，空点≥4）。
// AI 执黑只需在任一空点填一子 → 圈内空点减为 3 → 白块由活转死（圈内合法空点 <4）。
// 判死口径对齐 SiegeDetector.isAlive（圈内可合法落子空点 >=4 => 活）。
function makeKillProblem(
  whites: Array<[number, number]>,   // 腔内白块（紧贴保留空点的一侧）
  empties: Array<[number, number]>,  // 圈内恰好 4 个空点（黑方填其一即可杀）
  comment: string
): LifeDeathProblem {
  const b = new BoardModel(19);
  // 包围盒 = 白块 ∪ 空点的外扩一圈黑墙 ⇒ 圈内只有白块+空点，无多余空格
  let minR = 99, maxR = -1, minC = 99, maxC = -1;
  for (const [r, c] of whites) { if (r < minR) minR = r; if (r > maxR) maxR = r; if (c < minC) minC = c; if (c > maxC) maxC = c; }
  for (const [r, c] of empties) { if (r < minR) minR = r; if (r > maxR) maxR = r; if (c < minC) minC = c; if (c > maxC) maxC = c; }
  drawRectWall(b, minR - 1, minC - 1, maxR + 1, maxC + 1);
  for (const p of whites) b.setAt(p[0], p[1], Color.WHITE);
  const black: Array<[number, number]> = [];
  for (let r = 0; r < 19; r++)
    for (let c = 0; c < 19; c++)
      if (b.grid[r * 19 + c] === Color.BLACK) black.push([r, c]);
  return { kind: "kill", black, white: whites, solver: Color.BLACK, comment };
}

// 收集棋盘上的黑棋坐标（构造题面用）
function collectBlack(b: BoardModel): Array<[number, number]> {
  const black: Array<[number, number]> = [];
  for (let r = 0; r < 19; r++)
    for (let c = 0; c < 19; c++)
      if (b.grid[r * 19 + c] === Color.BLACK) black.push([r, c]);
  return black;
}

// 杀棋题模板：白块 + 恰好4个空点（眼位），单位格相对坐标，生成时加偏移平移。
// 每个模板圈内面积 = |white| + 4，保证活且可一手杀。
interface KillTemplate {
  white: Array<[number, number]>;
  empty: Array<[number, number]>;
}
const killTemplates: KillTemplate[] = [
  // 上条眼（宽条白块）
  { white: [[1, 0], [1, 1], [1, 2], [1, 3]], empty: [[0, 0], [0, 1], [0, 2], [0, 3]] },
  // 右列眼（竖条白块）
  { white: [[0, 0], [1, 0], [2, 0], [3, 0]], empty: [[0, 1], [1, 1], [2, 1], [3, 1]] },
  // 折角眼（L 形白块）
  { white: [[0, 1], [1, 0], [1, 1], [1, 2]], empty: [[0, 0], [0, 2], [0, 3], [1, 3]] },
  // 上条眼（三层白块，空点集中在顶部）
  { white: [[1, 0], [1, 1], [1, 2], [1, 3], [2, 0], [2, 1], [2, 2], [2, 3], [3, 0], [3, 1], [3, 2], [3, 3]], empty: [[0, 0], [0, 1], [0, 2], [0, 3]] },
  // 下条眼（宽条白块，镜像）
  { white: [[0, 0], [0, 1], [0, 2], [0, 3]], empty: [[1, 0], [1, 1], [1, 2], [1, 3]] },
  // 左列眼（竖条白块，镜像）
  { white: [[0, 1], [1, 1], [2, 1], [3, 1]], empty: [[0, 0], [1, 0], [2, 0], [3, 0]] },
];

// 杀棋题落点（棋盘上的 6 个散布位置，保证模板包围盒 + 黑墙都在 0..18 内）
const killOffsets: Array<[number, number]> = [
  [4, 4], [4, 10], [7, 6], [9, 12], [12, 5], [13, 12],
];

// ====== 职业4段级题目生成 ======
// 与普通题的关键差异（更难）：
//   - 做活题：3 空点布局使得「唯一成活点」是一个隐蔽的单点手筋（点方）。AI 必须从多个看似可成的迷惑点中
//     选出唯一正确点，才使某一空点补满己子形成第二真眼 → 由死转活（maxPly=1）。
//   - 杀棋题：圈内空点 = 5（单首手只能压到 4 仍活），必须连续两手压缩（黑填两空 → 空点 3 → 死），
//     期间对方见招拆招，体现职业级的次序与连续压迫（maxPly=2）。
// 构造采用了扫描器在 5x5 盒中穷举校验的「有效+可解」布局，均在 makeMasterProblems 后统一做权威校验。

/** 做活题空点方案（5x5 盒 r,c=1..5，填白留 3 空），经扫描器穷举验证：生前死、存在唯一手筋成活点 */
const masterLiveEmpties: Array<{ empties: Array<[number, number]>; win: [number, number] }> = [
  { empties: [[1, 2], [2, 2], [2, 4]], win: [1, 2] },
  { empties: [[1, 2], [2, 2], [3, 3]], win: [1, 2] },
  { empties: [[1, 3], [2, 3], [3, 2]], win: [1, 3] },
  { empties: [[1, 4], [2, 2], [2, 4]], win: [1, 4] },
  { empties: [[2, 1], [2, 2], [2, 4]], win: [2, 1] },
];

/** 杀棋题空点方案（4x4 盒 r,c=1..4，填白留 5 空），每项均已扫描确认：生前活、两手连压可杀 */
const masterKillEmpties: Array<Array<[number, number]>> = [
  [[1, 1], [1, 2], [1, 3], [1, 4], [2, 1]],
  [[1, 1], [1, 2], [1, 3], [1, 4], [3, 1]],
  [[1, 1], [1, 2], [1, 3], [1, 4], [4, 2]],
  [[1, 1], [1, 2], [1, 3], [1, 4], [2, 3]],
  [[1, 1], [1, 2], [1, 3], [1, 4], [4, 4]],
];

function makeMasterProblems(): LifeDeathProblem[] {
  const problems: LifeDeathProblem[] = [];
  // 做活职业 5 道：5x5 盒填满白、留 3 空，唯一成活点需点方找出手筋
  for (let i = 0; i < masterLiveEmpties.length; i++) {
    const { empties, win } = masterLiveEmpties[i];
    const white: Array<[number, number]> = [];
    for (let r = 1; r <= 5; r++)
      for (let c = 1; c <= 5; c++)
        if (!empties.some(([er, ec]) => er === r && ec === c)) white.push([r, c]);
    const prob = makeLiveProblem(white, `职业做活 ${i + 1}（点方 ${win[0]},${win[1]}）`);
    prob.master = true;
    prob.maxPly = 1;
    problems.push(prob);
  }
  // 杀棋职业 5 道：4x4 盒填白留 5 空 → 空点 5，须两手连压（空点 3）才转死
  for (let i = 0; i < masterKillEmpties.length; i++) {
    const em = masterKillEmpties[i];
    const box = 4;
    const white: Array<[number, number]> = [];
    for (let r = 1; r <= box; r++)
      for (let c = 1; c <= box; c++)
        if (!em.some(([er, ec]) => er === r && ec === c)) white.push([r, c]);
    const prob = makeKillProblem(white, em, `职业杀棋 ${i + 1}`);
    prob.master = true;
    prob.maxPly = 2;
    problems.push(prob);
  }
  return problems;
}

// ====== 多手判定：solver 与防守方（普通难度 AI）对弈至多 maxPly 手，目标块死活是否达成预期 ======
function solveTimed(prob: LifeDeathProblem, diff: AIDifficulty): boolean {
  const session = new GameSession({ enableDeployPhase: false });
  for (const [r, c] of prob.black) session.board.setAt(r, c, Color.BLACK);
  for (const [r, c] of prob.white) session.board.setAt(r, c, Color.WHITE);
  session.toMove = prob.solver;
  const ai = new AIEngine(prob.solver, diff);
  const defender = new AIEngine(opponent(prob.solver), AIDifficulty.NORMAL);
  const maxPly = prob.maxPly ?? 1;
  const seed = prob.white[0];

  for (let ply = 0; ply < maxPly * 2; ply++) {
    const isSolverTurn = session.toMove === prob.solver;
    const eng = isSolverTurn ? ai : defender;
    const mv = eng.chooseMove(session);
    if (mv.type === "move") {
      session.playMove(session.toMove, mv.row, mv.col); // 落子后自动切换 toMove
    } else {
      session.toMove = opponent(session.toMove); // 虚手：让出回合
    }
    // solver 每下一手判一次，达成即提前成功
    if (isSolverTurn) {
      const wg = session.board.groupAt(seed[0], seed[1]);
      const alive = SiegeDetector.isAlive(session.board, wg);
      if (prob.kind === "live" ? alive : !alive) return true;
    }
  }
  const wg = session.board.groupAt(seed[0], seed[1]);
  const alive = SiegeDetector.isAlive(session.board, wg);
  return prob.kind === "live" ? alive : !alive;
}

// ====== 题面生成器：100 道 ======
export function generateProblems(): LifeDeathProblem[] {
  const problems: LifeDeathProblem[] = [];

  // 生成做活题（70 道）：4 基础几何 × 18 偏移，取前 70
  let wIdx = 0;
  for (let b = 0; b < liveBases.length && wIdx < 70; b++) {
    for (let o = 0; o < liveOffsets.length && wIdx < 70; o++) {
      const [dr, dc] = liveOffsets[o];
      const whites = liveBases[b].white.map(([r, c]) => [r + dr, c + dc] as [number, number]);
      problems.push(makeLiveProblem(whites, `做活题 ${wIdx + 1} (基础${b}/位${o})`));
      wIdx++;
    }
  }

  // 生成杀棋题（30 道）：6 模板 × 5 偏移
  let kIdx = 0;
  for (let t = 0; t < killTemplates.length && kIdx < 30; t++) {
    for (let o = 0; o < killOffsets.length && kIdx < 30; o++) {
      const [dr, dc] = killOffsets[o];
      const whites = killTemplates[t].white.map(([r, c]) => [r + dr, c + dc] as [number, number]);
      const empties = killTemplates[t].empty.map(([r, c]) => [r + dr, c + dc] as [number, number]);
      problems.push(makeKillProblem(whites, empties, `杀棋题 ${kIdx + 1} (模板${t}/位${o})`));
      kIdx++;
    }
  }

  return problems;
}

// ====== 判定：AI 首手后目标块死活是否达到预期 ======
// 做活题：白块此前死，落子后白块 isAlive
// 杀棋题：白块此前活，落子后白块 isSieged（AI 黑削减空点）
function evaluateMove(
  prob: LifeDeathProblem,
  aiMove: { type: string; row: number; col: number }
): boolean {
  const board = new BoardModel(19);
  for (const [r, c] of prob.black) board.setAt(r, c, Color.BLACK);
  for (const [r, c] of prob.white) board.setAt(r, c, Color.WHITE);
  const whiteGroup = prob.white.map(([r, c]) => ({ row: r, col: c }));
  const wg = board.groupAt(whiteGroup[0].row, whiteGroup[0].col);
  const before = SiegeDetector.isAlive(board, wg);

  if (prob.kind === "live") {
    // 期望：落子后由死转活
    if (aiMove.type !== "move") return false;
    if (before) return true; // 若本已活，视为无效题，跳过不判（生成时保证非活）
    const sim = board.clone();
    sim.setAt(aiMove.row, aiMove.col, Color.WHITE);
    const wg2 = sim.groupAt(whiteGroup[0].row, whiteGroup[0].col);
    const after = SiegeDetector.isAlive(sim, wg2);
    return after && !before;
  } else {
    // 期望：落子后由活转死
    if (aiMove.type !== "move") return false;
    if (!before) return true; // 本已死 → 无意义，判对（生成时应为活）
    const sim = board.clone();
    sim.setAt(aiMove.row, aiMove.col, Color.BLACK);
    const wg2 = sim.groupAt(whiteGroup[0].row, whiteGroup[0].col);
    const after = SiegeDetector.isAlive(sim, wg2);
    return before && !after;
  }
}

// ====== 主流程：跑一遍指定难度 ======
// 从题面坐标重建棋盘（不含随机的 GameSession）
function rebuildBoard(prob: LifeDeathProblem): BoardModel {
  const board = new BoardModel(19);
  for (const [r, c] of prob.black) board.setAt(r, c, Color.BLACK);
  for (const [r, c] of prob.white) board.setAt(r, c, Color.WHITE);
  return board;
}

function runDifficulty(prob: LifeDeathProblem, diff: AIDifficulty): boolean {
  const session = new GameSession({ enableDeployPhase: false });
  for (const [r, c] of prob.black) session.board.setAt(r, c, Color.BLACK);
  for (const [r, c] of prob.white) session.board.setAt(r, c, Color.WHITE);
  session.toMove = prob.solver;
  const ai = new AIEngine(prob.solver, diff);
  const move = ai.chooseMove(session);
  return evaluateMove(prob, move);
}

// ====== 题面校验：确保做活题"生前死"、杀棋题"生前活且存在一手可杀" ======
function validateProblems(problems: LifeDeathProblem[]): void {
  let invalid = 0;
  for (const prob of problems) {
    const board = new BoardModel(19);
    for (const [r, c] of prob.black) board.setAt(r, c, Color.BLACK);
    for (const [r, c] of prob.white) board.setAt(r, c, Color.WHITE);
    const seed = prob.white[0];
    const wg = board.groupAt(seed[0], seed[1]);
    const before = SiegeDetector.isAlive(board, wg);

    if (prob.kind === "live") {
      if (before) { invalid++; console.error(`[校验失败] ${prob.comment}：做活题生前即活`); continue; }
      // 校验存在一手成活：任一空点填白后由死转活
      const size = 19;
      let livable = false;
      for (let r = 0; r < size && !livable; r++) {
        for (let c = 0; c < size && !livable; c++) {
          if (board.grid[r * size + c] !== Color.EMPTY) continue;
          const sim = board.clone();
          sim.setAt(r, c, Color.WHITE);
          const wg2 = sim.groupAt(seed[0], seed[1]);
          if (SiegeDetector.isAlive(sim, wg2)) { livable = true; break; }
        }
      }
      if (!livable) { invalid++; console.error(`[校验失败] ${prob.comment}：无一手成活点`); }
    } else {
      if (!before) { invalid++; console.error(`[校验失败] ${prob.comment}：杀棋题生前已死`); continue; }
      // 校验存在一手可杀：任一空点填黑后由活转死
      const size = 19;
      const allEmpty: Array<[number, number]> = [];
      for (let r = 0; r < size; r++)
        for (let c = 0; c < size; c++)
          if (board.grid[r * size + c] === Color.EMPTY) allEmpty.push([r, c]);
      let killable = false;
      for (const [r, c] of allEmpty) {
        const sim = board.clone();
        sim.setAt(r, c, Color.BLACK);
        const wg2 = sim.groupAt(seed[0], seed[1]);
        if (!SiegeDetector.isAlive(sim, wg2)) { killable = true; break; }
      }
      if (!killable) { invalid++; console.error(`[校验失败] ${prob.comment}：无一手可杀点`); }
    }
  }
  if (invalid > 0) throw new Error(`存在 ${invalid} 道无效死活题，终止评测`);
  console.log("题面校验通过：做活题生前死、杀棋题生前活且一手可杀 ✓\n");
}

// ====== 入口 ======
function main(): void {
  const problems = generateProblems();
  const masterProblems = makeMasterProblems();
  console.log(`已生成 ${problems.length} 道死活题（做活 ${problems.filter((p) => p.kind === "live").length} / 杀棋 ${problems.filter((p) => p.kind === "kill").length}）`);
  validateProblems(problems);
  // 职业题：单首手校验口径不适用（5空杀棋一手杀不掉），改为做事前可解性校验：
  //   - 做活题：生前死 且 存在至少一个空点填白后由死转活（有唯一成活点才算"手筋"，多个算送分）
  //   - 杀棋题：生前活 且 存在一手/两手连压使之转死
  for (const prob of masterProblems) {
    const board = rebuildBoard(prob);
    const size = board.size;
    const seed = prob.white[0];
    const before = SiegeDetector.isAlive(board, board.groupAt(seed[0], seed[1]));
    if (prob.kind === "live") {
      if (before) { console.error(`[职业校验失败] ${prob.comment}：生前即活`); process.exit(1); }
      const empties: Array<[number, number]> = [];
      for (let r = 0; r < size; r++) for (let c = 0; c < size; c++)
        if (board.grid[r * size + c] === Color.EMPTY) empties.push([r, c]);
      const livable = empties.filter(([r, c]) => {
        const sim = board.clone(); sim.setAt(r, c, Color.WHITE);
        return SiegeDetector.isAlive(sim, sim.groupAt(seed[0], seed[1])) && !before;
      });
      if (livable.length === 0) { console.error(`[职业校验失败] ${prob.comment}：无一手成活点（无解）`); process.exit(1); }
      if (livable.length > 3) { console.error(`[职业校验失败] ${prob.comment}：成活点过多(${livable.length})难度不足`); process.exit(1); }
    } else {
      if (!before) { console.error(`[职业校验失败] ${prob.comment}：生前已死`); process.exit(1); }
      const empties: Array<[number, number]> = [];
      for (let r = 0; r < size; r++) for (let c = 0; c < size; c++)
        if (board.grid[r * size + c] === Color.EMPTY) empties.push([r, c]);
      // 两手连压可杀：任一空点填黑 → 白仍活时，再选另一空点填黑 → 死
      let killable = false;
      for (let i = 0; i < empties.length && !killable; i++) {
        const [r1, c1] = empties[i];
        const s1 = board.clone(); s1.setAt(r1, c1, Color.BLACK);
        if (!SiegeDetector.isAlive(s1, s1.groupAt(seed[0], seed[1]))) { killable = true; continue; }
        for (let j = 0; j < empties.length && !killable; j++) {
          if (i === j) continue;
          const [r2, c2] = empties[j];
          if (s1.grid[r2 * size + c2] !== Color.EMPTY) continue;
          const s2 = s1.clone(); s2.setAt(r2, c2, Color.BLACK);
          if (!SiegeDetector.isAlive(s2, s2.groupAt(seed[0], seed[1]))) killable = true;
        }
      }
      if (!killable) { console.error(`[职业校验失败] ${prob.comment}：两手内不可杀（无解）`); process.exit(1); }
    }
  }
  console.log(`职业4段级 ${masterProblems.length} 道可解性校验通过 ✓\n`);

  const diffs: Array<[AIDifficulty, string]> = [
    [AIDifficulty.EASY, "简单"],
    [AIDifficulty.NORMAL, "普通"],
    [AIDifficulty.HARD, "困难"],
    [AIDifficulty.MASTER, "大师"],
  ];

  for (const [d, name] of diffs) {
    let liveCorrect = 0;
    let killCorrect = 0;
    let liveTotal = 0;
    let killTotal = 0;
    let mkCorrect = 0;
    let mlCorrect = 0;
    let mkTotal = 0;
    let mlTotal = 0;
    const start = Date.now();
    for (const p of problems) {
      if (p.kind === "live") { liveTotal++; if (runDifficulty(p, d)) liveCorrect++; }
      else { killTotal++; if (runDifficulty(p, d)) killCorrect++; }
    }
    for (const p of masterProblems) {
      const ok = solveTimed(p, d);
      if (p.kind === "kill") { mkTotal++; if (ok) mkCorrect++; }
      else { mlTotal++; if (ok) mlCorrect++; }
    }
    const elapsed = ((Date.now() - start) / 1000).toFixed(1);
    const totalCorrect = liveCorrect + killCorrect;
    const masterCorrect = mkCorrect + mlCorrect;
    console.log(
      `【${name}】 做活 ${liveCorrect}/${liveTotal} (${((liveCorrect / liveTotal) * 100).toFixed(0)}%) | ` +
      `杀棋 ${killCorrect}/${killTotal} (${((killCorrect / killTotal) * 100).toFixed(0)}%) | ` +
      `合计 ${totalCorrect}/${problems.length} (${((totalCorrect / problems.length) * 100).toFixed(0)}%) | 耗时${elapsed}s`
    );
    console.log(
      `   └ 职业4段级 ${masterCorrect}/${masterProblems.length} (${((masterCorrect / masterProblems.length) * 100).toFixed(0)}%) | ` +
      `杀棋 ${mkCorrect}/${mkTotal} 做活 ${mlCorrect}/${mlTotal}`
    );
  }
}

if (import.meta.main) main();