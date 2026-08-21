// 临时探针：打印 AI 在真实杀棋/做活题上的首手选择，定位死活不成的根因
import { Color } from "../src/Const.js";
import { BoardModel } from "../src/BoardModel.js";
import { SiegeDetector } from "../src/SiegeDetector.js";
import { AIEngine, AIDifficulty, __dbgCandPipeline, __dbgRootVals } from "../src/AI.js";
import { GameSession } from "../src/GameSession.js";
import { generateProblems } from "./life_death_bench.js";

// 复制 AI.groupIsBoxedIn 的逻辑做独立验证
function boxedIn(b: BoardModel, stones: number[], color: Color): boolean {
  const size = b.size, grid = b.grid, opp = color === Color.BLACK ? Color.WHITE : Color.BLACK;
  const seen = new Set<number>(stones);
  const stack = [...stones];
  while (stack.length) {
    const idx = stack.pop()!;
    const r = Math.floor(idx / size), c = idx % size;
    const nb: Array<[number, number]> = [];
    if (r > 0) nb.push([r - 1, c]);
    if (r < size - 1) nb.push([r + 1, c]);
    if (c > 0) nb.push([r, c - 1]);
    if (c < size - 1) nb.push([r, c + 1]);
    for (const [nr, nc] of nb) {
      const ni = nr * size + nc;
      if (seen.has(ni)) continue;
      const v = grid[ni];
      if (v === opp) continue;
      seen.add(ni); stack.push(ni);
    }
  }
  for (const idx of seen) {
    if (grid[idx] !== Color.EMPTY) continue;
    const r = Math.floor(idx / size), c = idx % size;
    if (r <= 0 || r >= size - 1 || c <= 0 || c >= size - 1) return false;
  }
  return true;
}

const all = generateProblems();
const kills = all.filter((p) => p.kind === "kill");
const lives = all.filter((p) => p.kind === "live");

function rebuild(prob: { black: Array<[number, number]>; white: Array<[number, number]> }): BoardModel {
  const b = new BoardModel(19);
  for (const [r, c] of prob.black) b.setAt(r, c, Color.BLACK);
  for (const [r, c] of prob.white) b.setAt(r, c, Color.WHITE);
  return b;
}

function solveOk(prob: any, diff: AIDifficulty): { ok: boolean; move: any } {
  const b = rebuild(prob);
  const session = new GameSession({ enableDeployPhase: false });
  for (const [r, c] of prob.black) session.board.setAt(r, c, Color.BLACK);
  for (const [r, c] of prob.white) session.board.setAt(r, c, Color.WHITE);
  session.toMove = prob.solver;
  const ai = new AIEngine(prob.solver, diff);
  const move = ai.chooseMove(session);
  const seed = prob.white[0];
  const wg = b.groupAt(seed[0], seed[1]);
  const before = SiegeDetector.isAlive(b, wg);
  const sim = b.clone();
  if (move.type === "move") sim.setAt(move.row, move.col, prob.solver);
  const wg2 = sim.groupAt(seed[0], seed[1]);
  const after = SiegeDetector.isAlive(sim, wg2);
  const ok = prob.kind === "live" ? (before === after ? false : after) : after !== before;
  return { ok, move };
}

// 全量统计各难度做活/杀棋，并打印【简单】难度未解出的做活题
const diffs: Array<[AIDifficulty, string]> = [
  [AIDifficulty.EASY, "简单"],
  [AIDifficulty.NORMAL, "普通"],
  [AIDifficulty.HARD, "困难"],
  [AIDifficulty.MASTER, "大师"],
];
for (const [d, name] of diffs) {
  if (process.env.PROBE_DIFF && name !== process.env.PROBE_DIFF) continue;
  let lw = 0, kw = 0;
  const fails: string[] = [];
  for (const p of lives) if (solveOk(p, d).ok) lw++;
  for (const p of kills) if (solveOk(p, d).ok) kw++;
  console.log(`${name}: 做活 ${lw}/${lives.length} | 杀棋 ${kw}/${kills.length}`);
}

// ASCII 棋盘打印（含坐标），聚焦白块周边
function dumpBoard(b: BoardModel, label: string): void {
  console.log(label);
  const size = b.size;
  let head = "   ";
  for (let c = 0; c < size; c++) head += (c % 5 === 0 ? String(c) : " ").padStart(1, " ");
  console.log(head.repeat(0)); console.log(head);
  for (let r = 0; r < size; r++) {
    let line = String(r).padStart(2, " ");
    for (let c = 0; c < size; c++) {
      const v = b.grid[r * size + c];
      line += v === Color.BLACK ? "●" : v === Color.WHITE ? "○" : "·";
    }
    console.log(line);
  }
}

console.log("\n===== 大师 | 未解出做活题（首个失败，含局面与候选诊断） =====");
for (const p of lives) {
  const r = solveOk(p, AIDifficulty.MASTER);
  if (r.ok) continue;
  const b = rebuild(p);
  const seed = p.white[0];
  const wg = b.groupAt(seed[0], seed[1]);
  const libSet = b.liberties(wg.stones).map((pt) => pt.row * b.size + pt.col);
  const s = new Set(libSet);
  const works: number[] = [];
  for (let rr = 0; rr < b.size; rr++)
    for (let cc = 0; cc < b.size; cc++) {
      if (!b.isEmpty(rr, cc)) continue;
      const sim = b.clone();
      sim.setAt(rr, cc, p.solver);
      const g2 = sim.groupAt(seed[0], seed[1]);
      if (SiegeDetector.isAlive(sim, g2)) works.push(rr * b.size + cc);
    }
  const inLib = works.filter((i) => s.has(i));
  dumpBoard(b, `--- ${p.comment} | AI下(${r.move.row},${r.move.col}) cat=${(r as any).move.cat ?? "?"} | 白块libs=${libSet.length} | 可转活点${works.length}个(在libs内${inLib.length}): [${inLib.map((i) => `${Math.floor(i / 19)},${i % 19}`).join(" ")}] ---`);
  const dbg = __dbgCandPipeline(b, p.solver, "master", 50);
  for (const wi of inLib) {
    const wal = dbg.all.find((m: any) => m.r * 19 + m.c === wi);
    const won = dbg.afterSafety.find((m: any) => m.r * 19 + m.c === wi);
    console.log(`  win点(${Math.floor(wi / 19)},${wi % 19}): inCands=${!!wal} cat=${wal?.cat} baseS=${wal?.s} | 存活safety后=${!!won} s=${won?.s}`);
  }
  // 根搜索 val 诊断
  const s2 = new GameSession({ enableDeployPhase: false });
  for (const [rr, cc] of p.black) s2.board.setAt(rr, cc, Color.BLACK);
  for (const [rr, cc] of p.white) s2.board.setAt(rr, cc, Color.WHITE);
  s2.toMove = p.solver;
  const rv = __dbgRootVals(s2, p.solver, 6);
  console.log(`  [真实AI下(${r.move.row},${r.move.col}) 理由=${r.move.reason}]  quickEvaluate(白视角): before=${rv.evBefore.toFixed(1)} 落首win点后=${rv.evAfterWin.toFixed(1)}`);
  console.log("  根搜索 top12 (val):");
  for (const t of rv.top) {
    const isWin = inLib.some((i) => Math.floor(i / 19) === t.r && i % 19 === t.c);
    console.log(`    (${t.r},${t.c}) cat=${t.cat} baseS=${t.baseS} ld=${t.ld} val=${t.val.toFixed(1)}${isWin ? " <==WIN" : ""}`);
  }
  break;
}
let n = 0;
for (const p of lives) {
  const r = solveOk(p, AIDifficulty.EASY);
  if (r.ok) continue;
  n++;
  if (n > 20) break;
  // 暴力验证：哪些空点能转活；白块 libs；AI是否可选其中点
  const b = rebuild(p);
  const seed = p.white[0];
  const wg = b.groupAt(seed[0], seed[1]);
  const libSet = b.liberties(wg.stones).map((pt) => pt.row * b.size + pt.col);
  const s = new Set(libSet);
  const works: number[] = [];
  for (let rr = 0; rr < b.size; rr++)
    for (let cc = 0; cc < b.size; cc++) {
      if (!b.isEmpty(rr, cc)) continue;
      const sim = b.clone();
      sim.setAt(rr, cc, p.solver);
      const g2 = sim.groupAt(seed[0], seed[1]);
      if (SiegeDetector.isAlive(sim, g2)) works.push(rr * b.size + cc);
    }
  const inLib = works.filter((i) => s.has(i));
  const wgStones = wg.stones.map((pt) => pt.row * b.size + pt.col);
  console.log(
    `${p.comment} | AI下(${r.move.row},${r.move.col}) | 白块libs=${libSet.length} | boxedIn=${boxedIn(b, wgStones, p.solver)} | 可转活点${works.length}个(在libs内${inLib.length})`
  );
}