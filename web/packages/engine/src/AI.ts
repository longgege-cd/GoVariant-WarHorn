// AI 对手 v4.3 —— 按《战争号角-边境线》AI 算法设计文档实现
// 纯规则引擎，无神经网络。四档难度：
//   简单：15候选 / 1层Alpha-Beta + 静态搜索 / 无MCTS / ≤500ms
//   普通：25候选 / 2层Alpha-Beta + 静态搜索 / 无MCTS / ≤1.5s
//   困难：40→12候选 / 3层Alpha-Beta + 静态搜索 / MCTS 100次 / ≤5s
//   大师：50→15候选 / 迭代加深 + PVS + 静态搜索 / 置换表 + MCTS 300次 / ≤15s
//
// 候选着法按文档 2.2 分类评分（提吃90 / 效率奖励88 / 救援85 / 压缩分领土·边境 /
// 突破78 / 边境70 / 围空扩展70 / 敌后渗透55-距边境×2 / 防守45），叠加历史启发式排序；
// 战略意图（§5 困难+）与濒危死活强化（§6 困难/大师）在根层候选加权引导方向。
// 评估函数按文档 4.1 维度表（分数差1.0 / 资源比例差 / 边境控制0.15 /
// 包围圈潜力0.1 / 潜在包围圈0.05 / 被围困奖惩 / 濒危棋子 / 虚手剩余 / 劫争 / 贴目）。
// 静态搜索（Quiescence）只展开战术着法（提吃/围困压缩/救援/突破包围圈）。

import {
  Color, opponent, BORDER_ROW,
  Zone, ownZone, enemyZone,
  isAttackZone,
  PASS_LIMIT_PER_GAME, PASS_COOLDOWN_TURNS,
} from "./Const.js";
import { BoardModel, Point } from "./BoardModel.js";
import { GoRules } from "./GoRules.js";
import { GameSession } from "./GameSession.js";
import { TerritoryDetector } from "./TerritoryDetector.js";
import { SiegeDetector } from "./SiegeDetector.js";

// ====== 四档难度配置（文档 §一） ======
export enum AIDifficulty {
  EASY = 0,
  NORMAL = 1,
  HARD = 2,
  MASTER = 3,
}

export const AI_DIFFICULTY_NAMES: Record<AIDifficulty, string> = {
  [AIDifficulty.EASY]: "简单",
  [AIDifficulty.NORMAL]: "普通",
  [AIDifficulty.HARD]: "困难",
  [AIDifficulty.MASTER]: "大师",
};

export const AI_DIFFICULTY_DESCS: Record<AIDifficulty, string> = {
  [AIDifficulty.EASY]: "1层读棋快棋",
  [AIDifficulty.NORMAL]: "2层战术读棋",
  [AIDifficulty.HARD]: "3层攻防读棋 + 蒙特卡洛",
  [AIDifficulty.MASTER]: "迭代加深 + PVS + 置换表 + 蒙特卡洛",
};

export interface AIConfig {
  maxCandidates: number; // 候选点数量上限（粗选）
  refineCands: number;   // 分层搜索精搜候选数（困难40→12 / 大师50→15）
  refinePly: number;     // Alpha-Beta 读棋深度（1/2/3；大师为迭代加深目标层）
  thinkTimeMs: number;   // 基础思考时间预算（动态调整见文档 §八）
  noise: number;         // 选点随机噪声幅度
  branch: number;        // 读棋时每层候选分支数
  mctsSims: number;      // MCTS 模拟次数（困难100 / 大师300）
  usePVS: boolean;       // 大师：PVS 主变例搜索
  useTT: boolean;        // 困难/大师：置换表
  useIterative: boolean; // 大师：迭代加深
  diversity: "off" | "light" | "full"; // 方案D 模块A：多样性惩罚档位（off=简单 / light=普通 / full=困难+大师）
  distWeight: number;    // 方案D 模块C：棋子分布评估权重（简单0.75 / 其余1.5）
  safety: "off" | "filter" | "full" | "master"; // 落子安全检测（off=简单 / filter=普通仅过滤 / full=困难 / master=大师+提吃预判）
}

export function getAIConfig(d: AIDifficulty): AIConfig {
  switch (d) {
    case AIDifficulty.EASY:
      return { maxCandidates: 15, refineCands: 15, refinePly: 1, thinkTimeMs: 500, noise: 10, branch: 8, mctsSims: 0, usePVS: false, useTT: false, useIterative: false, diversity: "off", distWeight: 0.75, safety: "off" };
    case AIDifficulty.NORMAL:
      return { maxCandidates: 25, refineCands: 25, refinePly: 2, thinkTimeMs: 1500, noise: 4, branch: 5, mctsSims: 0, usePVS: false, useTT: false, useIterative: false, diversity: "light", distWeight: 1.5, safety: "filter" };
    case AIDifficulty.HARD:
      return { maxCandidates: 40, refineCands: 12, refinePly: 3, thinkTimeMs: 5000, noise: 1, branch: 4, mctsSims: 100, usePVS: false, useTT: true, useIterative: false, diversity: "full", distWeight: 1.5, safety: "full" };
    case AIDifficulty.MASTER:
      // refinePly 从 8 降到 4：迭代加深根层对每个候选全窗口 -alphaBeta（非 PVS），8 层是指数爆炸主因，正常对局每手逼近 15s 上限；
      // 死活关键点已由根层保底（applyLifeDeathBoost）在 1-3 层锁死，4 层足够兼顾能力与速度
      return { maxCandidates: 50, refineCands: 15, refinePly: 4, thinkTimeMs: 15000, noise: 0, branch: 3, mctsSims: 300, usePVS: true, useTT: true, useIterative: true, diversity: "full", distWeight: 1.5, safety: "master" };
  }
}

export interface AIMove {
  type: "move" | "pass";
  row: number;
  col: number;
  reason: string;
}

interface ScoredMove {
  row: number;
  col: number;
  score: number;
  reason: string;
  cat: string; // 候选类别（历史启发式键）
}

// ====== 候选着法评分（文档 v9.0 §5.1 战斗阶段表） ======
// 提吃90 / 效率奖励88 / 救援85(己方濒危95) / 围困压缩(己方领土)85·(边境)82 /
// 加固边界点80 / 突破78 / 切断78 / 边境线58 / 围空扩展70 / 敌后渗透55 / 防守45
const CAT = {
  CAPTURE: "CAPTURE",       // 提吃对方棋子 90
  EFFICIENCY: "EFFICIENCY", // 效率奖励形成/跨阈值点 88（有效围空点推到4倍数边界）
  RESCUE: "RESCUE",         // 救援己方被围棋子 85（己方濒危95）
  COMPRESS: "COMPRESS",     // 压缩对方空间（己方领土85 / 边境82）
  REINFORCE: "REINFORCE",   // 加固边界点 80（己方包围圈边界弱气棋子）
  BREAK: "BREAK",           // 突破对方包围圈 78
  CUT: "CUT",               // 切断对方连接薄弱 78
  BORDER: "BORDER",         // 边境线要点 58
  EXPAND: "EXPAND",         // 形成/扩大包围圈 70
  INFILTRATE: "INFILTRATE", // 敌后渗透 55-距边境×2（为围空建根据地）
  DEFEND: "DEFEND",         // 防守要点 45
} as const;

const SCORE = {
  CAPTURE: 90,
  EFFICIENCY: 88,
  RESCUE: 85,
  RESCUE_DANGER: 95,   // 己方濒危时的救援
  COMPRESS_OWN: 85,   // 己方领土围困压缩
  COMPRESS_BORDER: 82, // 边境线围困压缩
  REINFORCE: 80,      // 加固边界点
  BREAK: 78,
  CUT: 78,            // 切断对方连接
  BORDER: 58,
  EXPAND: 70,
  INFILTRATE_BASE: 55,
  DEFEND: 45,
} as const;

// 效率奖励判定：相邻有效围空点每4点+2（规则书 v7.3 §3.2）
// 当己方某有效包围圈的有效围空点数 mod 4 == 3 时，再圈入1点即跨越4倍数阈值 →
// 该手立即净得约 +2 奖励（远高于普通扩展），故单独给 88 高分（仅次于提吃）。
const EFFICIENCY_CYCLE = 4;

// 四方向（上下左右）——用于包围度/墙扫描（形成包围圈、潜在包围圈评估）
const DIRS4: ReadonlyArray<readonly [number, number]> = [[-1, 0], [1, 0], [0, -1], [0, 1]];

// ====== 工具函数 ======

interface GroupInfo {
  stones: number[]; // 棋盘索引
  color: Color;
  libs: number[];
}

function collectGroups(board: BoardModel): GroupInfo[] {
  const size = board.size;
  const grid = board.grid;
  const seen = new Uint8Array(size * size);
  const groups: GroupInfo[] = [];
  for (let i = 0; i < grid.length; i++) {
    const color = grid[i] as Color;
    if (color === Color.EMPTY || seen[i]) continue;
    const stones: number[] = [];
    const stack: number[] = [i];
    seen[i] = 1;
    while (stack.length > 0) {
      const idx = stack.pop()!;
      stones.push(idx);
      const r = Math.floor(idx / size);
      const c = idx % size;
      if (r > 0 && grid[idx - size] === color && !seen[idx - size]) { seen[idx - size] = 1; stack.push(idx - size); }
      if (r < size - 1 && grid[idx + size] === color && !seen[idx + size]) { seen[idx + size] = 1; stack.push(idx + size); }
      if (c > 0 && grid[idx - 1] === color && !seen[idx - 1]) { seen[idx - 1] = 1; stack.push(idx - 1); }
      if (c < size - 1 && grid[idx + 1] === color && !seen[idx + 1]) { seen[idx + 1] = 1; stack.push(idx + 1); }
    }
    const libSet = new Set<number>();
    for (const idx of stones) {
      const r = Math.floor(idx / size);
      const c = idx % size;
      if (r > 0 && grid[idx - size] === Color.EMPTY) libSet.add(idx - size);
      if (r < size - 1 && grid[idx + size] === Color.EMPTY) libSet.add(idx + size);
      if (c > 0 && grid[idx - 1] === Color.EMPTY) libSet.add(idx - 1);
      if (c < size - 1 && grid[idx + 1] === Color.EMPTY) libSet.add(idx + 1);
    }
    groups.push({ stones, color, libs: Array.from(libSet) });
  }
  return groups;
}

function zoneOfRowLocal(row: number): Zone {
  if (row < BORDER_ROW) return Zone.BLACK;
  if (row === BORDER_ROW) return Zone.BORDER;
  return Zone.WHITE;
}

function countOwnHalf(board: BoardModel, color: Color): number {
  const size = board.size;
  let n = 0;
  for (let r = 0; r < size; r++) {
    if (zoneOfRowLocal(r) !== ownZone(color)) continue;
    for (let c = 0; c < size; c++) if (board.grid[r * size + c] === color) n++;
  }
  return n;
}

// 落子后新组群气数（自填气剔除用）
function libsAfterVirtualPlace(b: BoardModel, r: number, c: number, color: Color): number {
  const size = b.size;
  const grid = b.grid;
  const start = r * size + c;
  const seen = new Uint8Array(size * size);
  const stack: number[] = [start];
  seen[start] = 1;
  const libSet = new Set<number>();
  while (stack.length > 0) {
    const idx = stack.pop()!;
    const rr = Math.floor(idx / size);
    const cc = idx % size;
    if (rr > 0) {
      const v = grid[idx - size];
      if (v === color) { if (!seen[idx - size]) { seen[idx - size] = 1; stack.push(idx - size); } }
      else if (v === Color.EMPTY) libSet.add(idx - size);
    }
    if (rr < size - 1) {
      const v = grid[idx + size];
      if (v === color) { if (!seen[idx + size]) { seen[idx + size] = 1; stack.push(idx + size); } }
      else if (v === Color.EMPTY) libSet.add(idx + size);
    }
    if (cc > 0) {
      const v = grid[idx - 1];
      if (v === color) { if (!seen[idx - 1]) { seen[idx - 1] = 1; stack.push(idx - 1); } }
      else if (v === Color.EMPTY) libSet.add(idx - 1);
    }
    if (cc < size - 1) {
      const v = grid[idx + 1];
      if (v === color) { if (!seen[idx + 1]) { seen[idx + 1] = 1; stack.push(idx + 1); } }
      else if (v === Color.EMPTY) libSet.add(idx + 1);
    }
  }
  return libSet.size;
}

// 组群眼位候选：气点邻接 ≥2 己方子
function groupEyeCandidates(board: BoardModel, g: GroupInfo, color: Color): number[] {
  const size = board.size;
  const grid = board.grid;
  const out: number[] = [];
  for (const lib of g.libs) {
    const r = Math.floor(lib / size);
    const c = lib % size;
    let own = 0;
    for (const [nr, nc] of board.neighbors(r, c)) {
      if (grid[nr * size + nc] === color) own++;
    }
    if (own >= 2) out.push(lib);
  }
  return out;
}

// 组群能否连回另一颗己方子
function groupCanConnect(board: BoardModel, g: GroupInfo, color: Color): boolean {
  const size = board.size;
  const grid = board.grid;
  const ownSet = new Set<number>(g.stones);
  for (const lib of g.libs) {
    const r = Math.floor(lib / size);
    const c = lib % size;
    for (const [nr, nc] of board.neighbors(r, c)) {
      const ni = nr * size + nc;
      if (grid[ni] === color && !ownSet.has(ni)) return true;
    }
  }
  return false;
}

// 组群是否被围死（无自由逃生路线）
function groupIsConfined(board: BoardModel, g: GroupInfo): boolean {
  const size = board.size;
  const grid = board.grid;
  const opp = opponent(g.color);
  for (const lib of g.libs) {
    const r = Math.floor(lib / size);
    const c = lib % size;
    const newLibs = libsAfterVirtualPlace(board, r, c, g.color);
    if (newLibs <= g.libs.length) continue;
    let blocked = 0;
    if (r <= 0 || r >= size - 1) blocked++;
    if (c <= 0 || c >= size - 1) blocked++;
    for (const [nr, nc] of board.neighbors(r, c)) {
      const v = grid[nr * size + nc];
      if (v === opp) blocked++;
    }
    if (blocked < 2) return false;
  }
  return true;
}

// 切比雪夫距离 ≤ dist 内是否有己方棋（依托判定：防止孤军深入对方半场被反围）
function hasOwnSupport(board: BoardModel, r: number, c: number, color: Color, dist: number): boolean {
  const size = board.size;
  const grid = board.grid;
  for (let dr = -dist; dr <= dist; dr++) {
    for (let dc = -dist; dc <= dist; dc++) {
      const nr = r + dr;
      const nc = c + dc;
      if (nr < 0 || nr >= size || nc < 0 || nc >= size) continue;
      if (nr === r && nc === c) continue;
      if (grid[nr * size + nc] === color) return true;
    }
  }
  return false;
}

// 组群是否被完全围困（其空点/己子区域无法连通至棋盘边缘）。
// 用于死活识别：弥补 groupIsConfined 把"己方眼位空点"误判为可逃生口的缺陷
// （眼点四邻皆己方棋，blocked 计数为 0 → confined=false）。洪水填充穿越己子与空点，
// 若任意空点可达棋盘边缘则尚未围死；对方墙不可穿越。
function groupIsBoxedIn(board: BoardModel, g: GroupInfo, color: Color): boolean {
  const size = board.size;
  const grid = board.grid;
  const opp = opponent(color);
  const seen = new Set<number>(g.stones);
  const stack = [...g.stones];
  while (stack.length) {
    const idx = stack.pop()!;
    for (const [nr, nc] of board.neighbors(Math.floor(idx / size), idx % size)) {
      const ni = nr * size + nc;
      if (seen.has(ni)) continue;
      const v = grid[ni];
      if (v === opp) continue; // 对方墙：不可穿越
      seen.add(ni);
      stack.push(ni); // 己方棋或空点：继续
    }
  }
  for (const idx of seen) {
    if (grid[idx] !== Color.EMPTY) continue;
    const r = Math.floor(idx / size);
    const c = idx % size;
    if (r <= 0 || r >= size - 1 || c <= 0 || c >= size - 1) return false; // 空点可达边缘 → 未围死
  }
  return true;
}

// 组群是否死棋（死棋不救）。被围且无连络的组群若仍有眼位候选（一手可做活），不判死。
function groupIsDead(board: BoardModel, g: GroupInfo, color: Color): boolean {
  if (g.libs.length >= 4) return false;
  const connect = groupCanConnect(board, g, color);
  if (g.libs.length <= 2 && !connect) return true;
  return groupIsConfined(board, g) && !connect && groupEyeCandidates(board, g, color).length < 1;
}

// 组群是否按活子计分（GNU Go alive 原则）
function groupScoredAsAlive(board: BoardModel, g: GroupInfo, color: Color): boolean {
  if (groupIsDead(board, g, color)) return false;
  if (groupEyeCandidates(board, g, color).length >= 2) return true;
  if (groupCanConnect(board, g, color)) return true;
  if (!(g.stones.length >= 2 && g.libs.length >= 4)) return false;
  const size = board.size;
  for (const s of g.stones) {
    const r = Math.floor(s / size);
    if (Math.abs(r - BORDER_ROW) <= 2) return true;
  }
  return false;
}

// ====== 历史启发式表（文档 §2.4） ======
// 记录每类着法在搜索中的表现，表现好的着法优先搜索。
class HistoryTable {
  private table = new Map<string, number>();

  bump(cat: string, amount: number): void {
    const key = cat;
    this.table.set(key, (this.table.get(key) ?? 0) + amount);
  }

  get(cat: string): number {
    return this.table.get(cat) ?? 0;
  }
}

// ====== 置换表（困难/大师，文档 §3.5） ======
interface TTEntry {
  depth: number;
  score: number;
  flag: "exact" | "lower" | "upper";
  hash: number;
}
class TranspositionTable {
  private entries = new Map<number, TTEntry>();
  set(hash: number, depth: number, score: number, flag: TTEntry["flag"]): void {
    const e = this.entries.get(hash);
    if (e && e.depth >= depth) return;
    this.entries.set(hash, { depth, score, flag, hash });
  }
  get(hash: number): TTEntry | undefined {
    return this.entries.get(hash);
  }
  clear(): void {
    this.entries.clear();
  }
}

// 简单棋盘哈希（用 Zobrist 风格按格色加权；性能足够，无碰撞校验）
function boardHash(board: BoardModel): number {
  let h = 2166136261;
  for (let i = 0; i < board.grid.length; i++) {
    h ^= (board.grid[i] + 1) * (i + 1);
    h = Math.imul(h, 16777619);
  }
  return h >>> 0;
}

// ====== 评估函数（文档 §四） ======

// 资源分段权重（文档 §4.2）：随兵力上限自适应
function getResourceWeight(forceLimit: number, remainingRatio: number): number {
  let baseWeight: number;
  if (forceLimit <= 80) baseWeight = 50.0;
  else if (forceLimit <= 100) baseWeight = 35.0;
  else if (forceLimit <= 120) baseWeight = 25.0;
  else baseWeight = 15.0;
  if (remainingRatio < 0.2) return baseWeight * 2.0;
  if (remainingRatio < 0.4) return baseWeight * 1.5;
  return baseWeight;
}

// 潜在包围圈价值（文档 §4.1/§4.4：差1-2手闭合的包围圈，0.05/点量级）
// 对攻击区空点统计 4 方向 3 格内的己方墙：≥3 方向有墙 = 缺≤1手闭合（0.1/点），
// 2 方向 = 缺2手（0.05/点）。为搜索提供围空方向性——静态评估无法看穿多手闭合，
// 无此梯度时边境线与围空着法在评估上无差别，AI 倾向量大且同分的边境线候选。
function potentialEnclosureScore(board: BoardModel, color: Color): number {
  const size = board.size;
  const grid = board.grid;
  let pot = 0;
  for (let r = 0; r < size; r++) {
    if (!isAttackZone(r, color)) continue;
    for (let c = 0; c < size; c++) {
      const idx = r * size + c;
      if (grid[idx] !== Color.EMPTY) continue;
      let walls = 0;
      for (const [dr, dc] of DIRS4) {
        let nr = r + dr;
        let nc = c + dc;
        for (let k = 0; k < 3; k++, nr += dr, nc += dc) {
          if (nr < 0 || nr >= size || nc < 0 || nc >= size) break;
          const v = grid[nr * size + nc];
          if (v === color) { walls++; break; }
          if (v !== Color.EMPTY) break;
        }
      }
      if (walls >= 3) pot += 0.1;
      else if (walls === 2) pot += 0.05;
    }
  }
  return pot;
}

// 棋子分布广度（方案D 模块C）：(覆盖行数 + 覆盖列数) / 38.0，取值范围 0~1
// 全局视角奖励棋形舒展——AI 不会把兵力挤在一角，布局更接近人类的"均衡感"
function distributionScore(board: BoardModel, color: Color): number {
  const size = board.size;
  const grid = board.grid;
  const rowSeen = new Uint8Array(size);
  const colSeen = new Uint8Array(size);
  for (let i = 0; i < grid.length; i++) {
    if (grid[i] === color) {
      rowSeen[Math.floor(i / size)] = 1;
      colSeen[i % size] = 1;
    }
  }
  let covered = 0;
  for (let i = 0; i < size; i++) covered += rowSeen[i] + colSeen[i];
  return covered / (size * 2);
}

// 静态搜索用快速评估（文档 §6.2）：分数差 + 资源比例 + 边境控制 + 潜在包围圈 + 分布广度 + 死活奖惩
function lifeDeathDiff(board: BoardModel, rootColor: Color): number {
  const opp = opponent(rootColor);
  const groups = collectGroups(board);
  if (groups.length === 0) return 0;
  let diff = 0;
  const size = board.size;
  for (const g of groups) {
    if (g.color !== rootColor && g.color !== opp) continue;
    // 气数 ≥4 或完全开放 → 基本不是围死；快速剪枝避免昂贵的全盘死活
    if (g.libs.length >= 4) continue;
    const group = board.groupAt(Math.floor(g.stones[0] / size), g.stones[0] % size);
    if (!SiegeDetector.isSieged(board, group)) continue;
    const n = g.stones.length;
    diff += g.color === rootColor ? -n : n;
  }
  return diff * LIFE_DEATH_WEIGHT;
}

const LIFE_DEATH_WEIGHT = 3.0;
// 死活关键点根层保底：深搜索（3层/迭代）会用全局 eval(资源/分布)推高普通着法的 val，
// 把"一手必杀/必活"的死活点淹没。对已识别能翻转被围块死活的空点，根层 val 加该保底，
// 使其在深搜索中稳定优先（只作用于根层选点，不改全局评估，副作用小）。
const LIFE_DEATH_ROOT_BONUS = 8.0;

// ====== 战略规划/多目标评估上下文（文档 v9.0 §8） ======
// 根层每手预计算一次的全局偏移，经 SearchState.ec 在各搜索叶层共享，保证根决策与叶评估一致。
interface EvalCtx {
  tempoVal: number;        // 先手权价值 0.2
  passDiff: number;        // 虚手剩余差（root视角）
  koThreatDiff: number;    // 劫材差（我方劫材 - 对方劫材）
  stabilityDiff: number;   // 围空稳固性差
  stabilityWeight: number; // 稳定权重 0.3~0.5
  opening: boolean;        // 布局位置（前4手）
  trend: number;           // 近10手趋势（无对局分数历史时缺省0）
}

// 围空稳固性（文档 v9.0 §5.6/§8.1）：己方包围圈边界弱气棋子数折算为负分；
// 值越高代表己方包围圈越稳固（脆弱边界越少）
function enclosureStabilityScore(board: BoardModel, color: Color): number {
  const size = board.size;
  const grid = board.grid;
  const groups = collectGroups(board);
  const groupByStone = new Map<number, GroupInfo>();
  for (const g of groups) for (const i of g.stones) groupByStone.set(i, g);
  let s = 0;
  const encs = TerritoryDetector.enclosures(board);
  for (const e of encs) {
    if (e.color !== color) continue;
    for (const bIdx of e.borderStonesIdx) {
      if (grid[bIdx] !== color) continue;
      const g = groupByStone.get(bIdx);
      if (!g || g.libs.length === 0) continue;
      const L = g.libs.length;
      if (L === 1) s -= 6;      // 边界被叫吃，包围圈岌岌可危
      else if (L === 2) s -= 4;
      else if (L === 3) s -= 2;
      else s += 1;              // 气足边界健康
    }
  }
  return s;
}

// 构建根层评估上下文（每手一次）
function buildEvalCtx(session: GameSession, aiColor: Color): EvalCtx {
  const opp = opponent(aiColor);
  const myPass = PASS_LIMIT_PER_GAME - (session.passCounts.get(aiColor) ?? 0);
  const oppPass = PASS_LIMIT_PER_GAME - (session.passCounts.get(opp) ?? 0);
  const groups = collectGroups(session.board);
  let myKoThreat = 0; // 我可提的对方1气组（我方劫材）
  let oppKoThreat = 0; // 对方可提的己方1气组
  for (const g of groups) {
    if (g.libs.length !== 1) continue;
    if (g.color === opp) myKoThreat++;
    else if (g.color === aiColor) oppKoThreat++;
  }
  const placed = session.board.countColor(Color.BLACK) + session.board.countColor(Color.WHITE);
  return {
    tempoVal: 0.2,
    passDiff: myPass - oppPass,
    koThreatDiff: myKoThreat - oppKoThreat,
    stabilityDiff: enclosureStabilityScore(session.board, aiColor) - enclosureStabilityScore(session.board, opp),
    stabilityWeight: 0.4,
    opening: placed < 8,
    trend: 0, // 无对局分数历史，缺省0（v9.0 §8.1"趋势"）
  };
}

function quickEvaluate(
  board: BoardModel,
  rootColor: Color,
  komi: number,
  pieceLimit: number,
  rootLeft: number,
  oppLeft: number,
  distWeight: number,
  ec?: EvalCtx
): number {
  let scoreDiff = 0;
  let effPotDiff = 0; // 效率奖励潜力差（文档 §4.3：跨4倍数阈值的潜在+2）
  // 围空分差（TerritoryDetector 真实围空）
  const encs = TerritoryDetector.enclosures(board);
  for (const e of encs) {
    let s = 0;
    let valid = 0;
    for (const p of e.points) {
      if (isAttackZone(p.row, e.color)) {
        s += 2;
        valid++;
      }
    }
    if (valid >= 4) s += 2 * Math.floor(valid / 4); // 效率奖励 v7.3 §3.2
    // 效率奖励潜力：effective_points % 4 == 3 → 差1手 +2；==2 → 差2手 +1
    const pot = valid % 4 === 3 ? 2.0 : valid % 4 === 2 ? 1.0 : 0.0;
    effPotDiff += e.color === rootColor ? pot : -pot;
    if (e.color === rootColor) scoreDiff += s;
    else scoreDiff -= s;
  }
  // 死活奖惩（文档 §4.1"被围困奖惩"）：围杀对方组群 + 己方被围困 -（死活判定决定局部杀棋/做活收益）
  const ldDiff = lifeDeathDiff(board, rootColor);
  // v7.3 已取消活子分：落子本身不得分
  const total = pieceLimit > 0 ? pieceLimit : 1;
  const rrRoot = rootLeft / total;
  const rrOpp = oppLeft / total;
  const resDiff = (rrRoot - rrOpp) * 20.0;
  let borderControl = 0;
  for (let c = 0; c < board.size; c++) {
    const v = board.grid[BORDER_ROW * board.size + c];
    if (v === rootColor) borderControl++;
    else if (v !== Color.EMPTY) borderControl--;
  }
  // 潜在包围圈差（文档 §4.1）：引导搜索朝"接近闭合"的围空方向发展
  const potDiff =
    potentialEnclosureScore(board, rootColor) - potentialEnclosureScore(board, opponent(rootColor));
  // 分布广度差（方案D 模块C）：全局奖励棋形舒展，权重按难度分层
  const distDiff =
    (distributionScore(board, rootColor) - distributionScore(board, opponent(rootColor))) * distWeight;
  let v = scoreDiff * 1.0 + resDiff + borderControl * 0.15 + potDiff + distDiff + effPotDiff * 0.5 + ldDiff;
  if (rootColor === Color.WHITE) v += komi;
  // 战略规划/多目标评估维度（文档 v9.0 §8.1）——均为根层预计算的全局偏移（ec 各叶层共享保证一致性）
  if (ec) {
    v += ec.tempoVal;                          // 先手权价值 0.2
    v += ec.passDiff * 2.0;                    // 虚手剩余差 2.0/次（战略资源）
    v += ec.koThreatDiff * 1.0;                // 劫材差 1.0
    v += ec.stabilityDiff * ec.stabilityWeight; // 围空稳固性 0.3~0.5
    if (ec.opening) v += 0.5;                  // 布局位置 0.5（仅前4手）
    v += ec.trend * 0.3;                       // 趋势 0.3
  }
  return v;
}

// ====== 候选生成器（文档 §二） ======

interface CandCtx {
  ready: boolean;   // 己方框架稳固（己方半场 ≥ FRAMEWORK_SOLID）
  deploy: boolean;  // 布局阶段
  opening: boolean; // 前 4 手
}

// 布局阶段候选（文档 v9.0 §5.1）：角部 80 / 靠近边境线 70 / 中央附近 65 / 己方领土其他 40
// 角部优先于边境线：本游戏得分在对方半场/边境，开局先立己方角部奠基，符合传统围棋"占角>占边"
function genDeployCandidates(board: BoardModel, color: Color): ScoredMove[] {
  const size = board.size;
  const myZone = ownZone(color);
  const out: ScoredMove[] = [];
  for (let r = 0; r < size; r++) {
    if (zoneOfRowLocal(r) !== myZone) continue;
    for (let c = 0; c < size; c++) {
      if (!board.isEmpty(r, c)) continue;
      const dist = Math.abs(r - BORDER_ROW);
      let score: number;
      let cat: string;
      if ((r <= 1 || r >= size - 2) && (c <= 1 || c >= size - 2)) { score = 80; cat = "CORNER"; }
      else if (dist <= 1) { score = 70; cat = "BORDER_LINE"; }
      else if (Math.abs(c - Math.floor(size / 2)) <= 1 && dist <= 3) { score = 65; cat = "CENTER"; }
      else { score = 40; cat = "OWN_AREA"; }
      out.push({ row: r, col: c, score, reason: "布局", cat });
    }
  }
  return out;
}

// 战斗阶段候选（文档 §2.2）
function genBattleCandidates(
  board: BoardModel,
  toMove: Color,
  koPoint: Point,
  history: HistoryTable,
  ctx: CandCtx
): ScoredMove[] {
  const opp = opponent(toMove);
  const size = board.size;
  const grid = board.grid;
  const groups = collectGroups(board);
  // 组群 id 映射：连锁切断/连接薄弱检测用
  const groupId = new Int32Array(size * size).fill(-1);
  for (let gi = 0; gi < groups.length; gi++) {
    for (const idx of groups[gi].stones) groupId[idx] = gi;
  }
  const map = new Map<number, ScoredMove>();
  const tactical = new Set<number>();
  const add = (idx: number, score: number, reason: string, cat: string): void => {
    if (grid[idx] !== Color.EMPTY) return;
    const ex = map.get(idx);
    const h = history.get(cat);
    const s = score + h * 0.5;
    if (ex === undefined || s > ex.score) {
      map.set(idx, { row: Math.floor(idx / size), col: idx % size, score: s, reason, cat });
    }
  };

  // 1) 提吃对方棋子 95：对方组群仅 1 气 → 填其唯一气点
  for (const g of groups) {
    if (g.color !== opp || g.libs.length !== 1) continue;
    const lib = g.libs[0];
    tactical.add(lib);
    add(lib, SCORE.CAPTURE + g.stones.length * 2, `提吃${g.stones.length}子`, CAT.CAPTURE);
  }

  // 2) 救援己方被围棋子 88：己方被围组群（值得救的）→ 扩大空间（填气/逃）
  for (const g of groups) {
    if (g.color !== toMove || g.libs.length === 0) continue;
    if (groupIsDead(board, g, toMove)) continue;
    if (!groupIsConfined(board, g)) continue;
    const threat = g.libs.length <= 2;
    for (const lib of g.libs) {
      tactical.add(lib);
      // 己方濒危(空点≤2)时救援提到 95（文档 v9.0 §5.1）
      add(lib, SCORE.RESCUE + g.stones.length + (threat ? SCORE.RESCUE_DANGER - SCORE.RESCUE : 0), "救援己方被围", CAT.RESCUE);
    }
  }

  // 3) 压缩对方空间 82：对方被围且圈内合法落子空点 = 4 或 5 → 填眼/紧气
  for (const g of groups) {
    if (g.color !== opp || g.libs.length === 0) continue;
    if (!groupIsConfined(board, g)) continue;
    // 圈内合法空点（不含自身棋子位，近似：气点 + 邻接空点）
    const inside: number[] = [];
    for (const lib of g.libs) {
      if (grid[lib] === Color.EMPTY) inside.push(lib);
    }
    const nInside = inside.length;
    if (nInside === 4 || nInside === 5) {
      for (const lib of inside) {
        tactical.add(lib);
        // 围困压缩按落点分区：己方领土85 / 边境线82（文档 v7.0 §2.2）
        const dist = Math.abs(Math.floor(lib / size) - BORDER_ROW);
        const comp = dist <= 1 ? SCORE.COMPRESS_BORDER : SCORE.COMPRESS_OWN;
        add(lib, comp, "压缩对方空间", CAT.COMPRESS);
      }
    }
    // 无眼位 → 破眼优先
    if (groupEyeCandidates(board, g, opp).length === 0) {
      for (const lib of inside) add(lib, SCORE.COMPRESS_OWN + 3, "破眼围杀", CAT.COMPRESS);
    }
  }

  // 4) 突破对方包围圈 78（文档 §2.3 FindEnclosureBreakMoves）：
  //    对方包围圈边界 1 气棋子 → 打其唯一气点破墙
  const encs = TerritoryDetector.enclosures(board);
  for (const e of encs) {
    if (e.color !== opp) continue;
    for (const idx of e.borderStonesIdx) {
      const r = Math.floor(idx / size);
      const c = idx % size;
      if (grid[idx] !== opp) continue;
      const g = collectGroupAt(board, r, c);
      if (g === null || g.libs.length !== 1) continue;
      const lib = g.libs[0];
      if (grid[lib] !== Color.EMPTY) continue;
      tactical.add(lib);
      add(lib, SCORE.BREAK, "突破对方包围圈", CAT.BREAK);
    }
  }

  // 5) 边境线要点 58 + 边境线围困风险检测（文档 v9.0 §5.5）：
  //    边境线是战略要地，孤子易被围困——落子后气数≤2 则扣30，气=3 扣10
  for (let c = 0; c < size; c++) {
    const idx = BORDER_ROW * size + c;
    if (grid[idx] !== Color.EMPTY) continue;
    let ownNbr = 0;
    for (const [nr, nc] of board.neighbors(BORDER_ROW, c)) {
      if (grid[nr * size + nc] === toMove) ownNbr++;
    }
    let risk = 0;
    const sim = board.clone();
    if (GoRules.tryMove(sim, BORDER_ROW, c, toMove, koPoint).legal) {
      const g = groupInfoAfterPlace(sim, BORDER_ROW, c, toMove);
      if (g.libs <= 2) risk = -30;
      else if (g.libs === 3) risk = -10;
    }
    add(idx, SCORE.BORDER + ownNbr * 3 + risk, "边境线要点", CAT.BORDER);
  }

  // 6) 形成/扩大包围圈 70 + 效率奖励 88（文档 v7.0 §2.2）：
  //    a) 扩大：己方闭合围空圈边界外侧空点（把墙向外推，围更多空点）
  //    b) 效率奖励：该圈有效围空点数 mod 4 == 3 时，再圈入1点即跨4倍数阈值 → 88 高分
  //    c) 形成：攻击区空点被己方棋 ≥3 方向夹住（差≤1手闭合）→ 闭圈点
  for (const e of encs) {
    if (e.color !== toMove) continue;
    const inside = new Set<number>();
    for (const p of e.points) inside.add(p.row * size + p.col);
    // 有效围空点（简化取攻击区空点数；围困棋子部分在评估层由真实计分兜底）
    let valid = 0;
    for (const p of e.points) if (isAttackZone(p.row, toMove)) valid++;
    const crossThreshold = valid > 0 && valid % EFFICIENCY_CYCLE === EFFICIENCY_CYCLE - 1;
    for (const bIdx of e.borderStonesIdx) {
      const br = Math.floor(bIdx / size);
      const bc = bIdx % size;
      for (const [nr, nc] of board.neighbors(br, bc)) {
        const idx = nr * size + nc;
        if (grid[idx] !== Color.EMPTY) continue;
        if (inside.has(idx)) continue; // 圈内空点是围空得分点，落子=自填
        if (!isAttackZone(nr, toMove)) continue; // 己方半场围空不得分，不扩展
        if (crossThreshold) add(idx, SCORE.EFFICIENCY, "跨效率阈值扩圈", CAT.EFFICIENCY);
        else add(idx, SCORE.EXPAND, "扩大包围圈", CAT.EXPAND);
      }
    }
  }
  for (let r = 0; r < size; r++) {
    if (!isAttackZone(r, toMove)) continue;
    for (let c = 0; c < size; c++) {
      const idx = r * size + c;
      if (grid[idx] !== Color.EMPTY) continue;
      let walls = 0;
      for (const [dr, dc] of DIRS4) {
        let nr = r + dr;
        let nc = c + dc;
        for (let k = 0; k < 3; k++, nr += dr, nc += dc) {
          if (nr < 0 || nr >= size || nc < 0 || nc >= size) break;
          const v = grid[nr * size + nc];
          if (v === toMove) { walls++; break; }
          if (v === opp) break; // 对方棋挡道，该方向无法闭合
        }
      }
      if (walls >= 3) add(idx, SCORE.EXPAND + 5, "形成包围圈", CAT.EXPAND);
      else if (walls === 2) add(idx, SCORE.EXPAND - 8, "形成包围圈", CAT.EXPAND);
    }
  }

  // 6b) 围空稳固性/加固边界点 80（文档 v9.0 §5.1/§5.6）：
  //     己方包围圈边界气数≤3 的棋子是其弱点，其气点应补强——避免被对方一手冲垮包围圈
  for (const e of encs) {
    if (e.color !== toMove) continue;
    for (const bIdx of e.borderStonesIdx) {
      if (grid[bIdx] !== toMove) continue;
      const gi = groupId[bIdx];
      if (gi < 0) continue;
      const g = groups[gi];
      if (g.libs.length > 3) continue; // 气足，无需加固
      for (const lib of g.libs) {
        if (grid[lib] !== Color.EMPTY) continue;
        tactical.add(lib);
        add(lib, SCORE.REINFORCE, "加固边界点", CAT.REINFORCE);
      }
    }
  }

  // 6c) 薄弱点扫描·连接薄弱→切断 78（文档 v9.0 §5.2）：
  //     某空点邻接≥2个不同对方组群 → 对方可在该点连接，抢先切断可分裂其棋势
  for (let r = 0; r < size; r++) {
    for (let c = 0; c < size; c++) {
      const idx = r * size + c;
      if (grid[idx] !== Color.EMPTY) continue;
      let g1 = -1;
      let g2 = -1;
      for (const [nr, nc] of board.neighbors(r, c)) {
        const ni = nr * size + nc;
        if (grid[ni] !== opp) continue;
        const gid = groupId[ni];
        if (gid < 0) continue;
        if (g1 === -1) g1 = gid;
        else if (g1 !== gid && g2 === -1) g2 = gid;
      }
      if (g2 !== -1) {
        tactical.add(idx);
        add(idx, SCORE.CUT + 10, "切断对方连接", CAT.CUT);
      }
    }
  }

  // 7) 敌后渗透 55-距边境×2：对方领土空点（文档 §2.2）。己方框架稳固后主动进攻，
  //    但须有己方棋依托（邻格或切比雪夫≤2），杜绝孤军深入对方半场被反围。
  if (ctx.ready) {
    for (let r = 0; r < size; r++) {
      if (zoneOfRowLocal(r) !== enemyZone(toMove)) continue;
      for (let c = 0; c < size; c++) {
        const idx = r * size + c;
        if (grid[idx] !== Color.EMPTY) continue;
        const dist = Math.abs(r - BORDER_ROW);
        let ownNbr = 0;
        let oppNbr = 0;
        for (const [nr, nc] of board.neighbors(r, c)) {
          const v = grid[nr * size + nc];
          if (v === toMove) ownNbr++;
          else if (v === opp) oppNbr++;
        }
        if (ownNbr === 0 && !hasOwnSupport(board, r, c, toMove, 2)) continue;
        let s = SCORE.INFILTRATE_BASE - dist * 2 + ownNbr * 4 + oppNbr * 2;
        // 资源薄弱区域(3×3对方棋子≤1)：薄弱点扫描加成 +10（文档 v9.0 §5.2）
        let opp3 = 0;
        for (let dr = -1; dr <= 1; dr++) {
          for (let dc = -1; dc <= 1; dc++) {
            const nr = r + dr;
            const nc = c + dc;
            if (nr < 0 || nr >= size || nc < 0 || nc >= size) continue;
            if (grid[nr * size + nc] === opp) opp3++;
          }
        }
        if (opp3 <= 1) s += 10;
        if (s <= 0) continue;
        add(idx, s, "敌后渗透", CAT.INFILTRATE);
      }
    }
  }

  // 8) 防守要点 45：己方领土靠近对方棋子（对方已侵入才有防守价值；否则自补）
  for (let r = 0; r < size; r++) {
    if (zoneOfRowLocal(r) !== ownZone(toMove)) continue;
    for (let c = 0; c < size; c++) {
      const idx = r * size + c;
      if (grid[idx] !== Color.EMPTY) continue;
      let oppNbr = 0;
      for (const [nr, nc] of board.neighbors(r, c)) {
        if (grid[nr * size + nc] === opp) oppNbr++;
      }
      if (oppNbr > 0) add(idx, SCORE.DEFEND + oppNbr * 2, "防守要点", CAT.DEFEND);
    }
  }

  const arr = Array.from(map.values());
  arr.sort((a, b) => b.score - a.score);
  const out: ScoredMove[] = [];
  for (const m of arr) {
    const idx = m.row * size + m.col;
    if (!tactical.has(idx) && libsAfterVirtualPlace(board, m.row, m.col, toMove) < 2) continue;
    out.push(m);
  }
  return out;
}

// 收集 (r,c) 处的组群（返回 GroupInfo 或 null）
function collectGroupAt(board: BoardModel, r: number, c: number): GroupInfo | null {
  if (board.getAt(r, c) === Color.EMPTY) return null;
  const idx = r * board.size + c;
  for (const g of collectGroups(board)) {
    if (g.stones.includes(idx)) return g;
  }
  return null;
}

// ====== 候选总入口 ======
function genCandidates(
  board: BoardModel,
  toMove: Color,
  koPoint: Point,
  maxN: number,
  history: HistoryTable,
  ctx: CandCtx,
  diversity: "off" | "light" | "full" = "off"
): ScoredMove[] {
  if (ctx.deploy) {
    const depl = genDeployCandidates(board, toMove);
    depl.sort((a, b) => b.score - a.score);
    return depl.slice(0, maxN);
  }
  const battle = genBattleCandidates(board, toMove, koPoint, history, ctx);
  // 方案D 模块A：多样性惩罚后重新排序
  applyDiversityPenalty(battle, board, toMove, diversity);
  battle.sort((a, b) => b.score - a.score);
  return battle.slice(0, maxN);
}

// 文档 v9.0 §5.4 多样性惩罚与探索奖励：
//   light（普通）：曼哈顿≤2 内己方 ≥6 → -10
//   full（困难/大师）：≥6 → -20；≥4 → -10；距离≤1 内 ≥3 → 额外 -5
//   + 同行/列惩罚：某行/列己方≥4 → 该行/列候选 -10
//   + 区域探索奖励：3×3 己方密度 0/1/2 → +12/+6/+2
// 战术着法（提/救/压/破/加固/切断）不受惩罚——这些是必须下的，避免误伤
function applyDiversityPenalty(
  cands: ScoredMove[],
  board: BoardModel,
  color: Color,
  mode: "off" | "light" | "full"
): void {
  if (mode === "off") return;
  const size = board.size;
  const grid = board.grid;
  // 同行/列密度：预计算（贴近 v9.0 §5.4）
  const rowOwn = new Int32Array(size);
  const colOwn = new Int32Array(size);
  for (let r = 0; r < size; r++) {
    for (let c = 0; c < size; c++) {
      if (grid[r * size + c] === color) { rowOwn[r]++; colOwn[c]++; }
    }
  }
  for (const m of cands) {
    if (m.cat === CAT.CAPTURE || m.cat === CAT.RESCUE || m.cat === CAT.COMPRESS || m.cat === CAT.BREAK || m.cat === CAT.CUT || m.cat === CAT.REINFORCE) continue;
    // 统计曼哈顿距离 ≤ 2 内己方棋子数量
    let nearby = 0;
    let in3 = 0; // 3×3 己方密度（探索奖励）
    for (let dr = -2; dr <= 2; dr++) {
      for (let dc = -2; dc <= 2; dc++) {
        if (Math.abs(dr) + Math.abs(dc) > 2) continue;
        const r = m.row + dr;
        const c = m.col + dc;
        if (r < 0 || r >= size || c < 0 || c >= size) continue;
        const cur = grid[r * size + c];
        if (cur === color) nearby++;
        if (Math.abs(dr) <= 1 && Math.abs(dc) <= 1 && cur === color) in3++;
      }
    }
    let penalty = 0;
    if (nearby >= 6) penalty = mode === "light" ? 10 : 20;
    else if (nearby >= 4) penalty = mode === "light" ? 0 : 10;
    // 距离≤1 内己方棋子 ≥3：避免连成直线（仅完整版）
    if (mode === "full") {
      let adj = 0;
      for (const [nr, nc] of board.neighbors(m.row, m.col)) {
        if (grid[nr * size + nc] === color) adj++;
      }
      if (adj >= 3) penalty += 5;
    }
    // 同行/列惩罚：整行/列己方≥4，落点扣10（贴近 v9.0 §5.4）
    if (rowOwn[m.row] >= 4) penalty += 10;
    if (colOwn[m.col] >= 4) penalty += 10;
    if (penalty > 0) m.score -= penalty;
    // 区域探索奖励：3×3 己方密度低 → 鼓励开拓新战场
    if (in3 === 0) m.score += 12;
    else if (in3 === 1) m.score += 6;
    else if (in3 === 2) m.score += 2;
  }
}

// ====== 落子安全检测（送死修复） ======

// 落子后 (row,col) 所在组群的气数（局部 BFS，避免全盘扫描）
function groupInfoAfterPlace(board: BoardModel, row: number, col: number, color: Color): { libs: number; uniqueLib: number } {
  const size = board.size;
  const idx = row * size + col;
  const seen = new Uint8Array(size * size);
  const stack: number[] = [idx];
  seen[idx] = 1;
  const libSet = new Set<number>();
  while (stack.length > 0) {
    const i = stack.pop()!;
    const r = Math.floor(i / size);
    const c = i % size;
    if (r > 0) {
      const ni = i - size;
      const v = board.grid[ni];
      if (v === color) { if (!seen[ni]) { seen[ni] = 1; stack.push(ni); } }
      else if (v === Color.EMPTY) libSet.add(ni);
    }
    if (r < size - 1) {
      const ni = i + size;
      const v = board.grid[ni];
      if (v === color) { if (!seen[ni]) { seen[ni] = 1; stack.push(ni); } }
      else if (v === Color.EMPTY) libSet.add(ni);
    }
    if (c > 0) {
      const ni = i - 1;
      const v = board.grid[ni];
      if (v === color) { if (!seen[ni]) { seen[ni] = 1; stack.push(ni); } }
      else if (v === Color.EMPTY) libSet.add(ni);
    }
    if (c < size - 1) {
      const ni = i + 1;
      const v = board.grid[ni];
      if (v === color) { if (!seen[ni]) { seen[ni] = 1; stack.push(ni); } }
      else if (v === Color.EMPTY) libSet.add(ni);
    }
  }
  const libs = libSet.size;
  return { libs, uniqueLib: libs === 1 ? Array.from(libSet)[0] : -1 };
}

// 落子安全评估：模拟落子后检查气数（1气-50 / 2气-20 / 3气-5）+ 曼哈顿≤2 敌我力量（对方×-3 / 己方×+2）
function evaluateMoveSafety(board: BoardModel, row: number, col: number, color: Color, koPoint: Point): number {
  const sim = board.clone();
  const res = GoRules.tryMove(sim, row, col, color, koPoint);
  if (!res.legal) return -Infinity;
  const size = sim.size;
  const g = groupInfoAfterPlace(sim, row, col, color);
  let safety = 0;
  if (g.libs === 1) safety -= 50;
  else if (g.libs === 2) safety -= 20;
  else if (g.libs <= 3) safety -= 5;
  let oppN = 0;
  let allyN = 0;
  for (let dr = -2; dr <= 2; dr++) {
    for (let dc = -2; dc <= 2; dc++) {
      if (Math.abs(dr) + Math.abs(dc) > 2) continue;
      const r = row + dr;
      const c = col + dc;
      if (r < 0 || r >= size || c < 0 || c >= size) continue;
      const v = sim.grid[r * size + c];
      if (v === color) allyN++;
      else if (v !== Color.EMPTY) oppN++;
    }
  }
  safety -= oppN * 3;
  safety += allyN * 2;
  return safety;
}

// 大师：落子后对手能否立即提掉新子
function canOpponentCaptureImmediately(board: BoardModel, row: number, col: number, color: Color, koPoint: Point): boolean {
  const size = board.size;
  const idx = row * size + col;
  const sim = board.clone();
  const res = GoRules.tryMove(sim, row, col, color, koPoint);
  if (!res.legal) return true;
  const g = groupInfoAfterPlace(sim, row, col, color);
  if (g.libs !== 1) return false;
  const lib = g.uniqueLib;
  if (lib < 0) return false;
  const sim2 = sim.clone();
  const res2 = GoRules.tryMove(sim2, Math.floor(lib / size), lib % size, opponent(color), koPoint);
  if (!res2.legal) return false;
  return res2.captured.some((p) => p.row * size + p.col === idx);
}

// 对候选点应用安全检测（按难度分层；只在根层调用，搜索树内由评估兜底）
//   filter（普通）：排除 safety ≤ -40 的极端危险点
//   full（困难）：过滤 + score += safety * 0.5
//   master（大师）：full + 排除对手能立即提吃新子的点
function applyMoveSafety(
  cands: ScoredMove[],
  board: BoardModel,
  color: Color,
  koPoint: Point,
  mode: "off" | "filter" | "full" | "master"
): void {
  if (mode === "off" || cands.length === 0) return;
  const keep: ScoredMove[] = [];
  let safestIdx = 0;
  let safestVal = -Infinity;
  for (let i = 0; i < cands.length; i++) {
    const m = cands[i];
    // 战术死活类（围杀/破眼/提吃/救援/突破）：落点气少是围杀对方的正常手段，
    // 不按普通落子安全惩罚，否则高难度会误删杀棋关键手
    if (m.cat === CAT.COMPRESS || m.cat === CAT.CAPTURE || m.cat === CAT.BREAK || m.cat === CAT.RESCUE) { keep.push(m); continue; }
    const safety = evaluateMoveSafety(board, m.row, m.col, color, koPoint);
    if (safety > safestVal) { safestVal = safety; safestIdx = i; }
    if (safety <= -40) continue; // 极端危险，直接排除
    if (mode === "master" && canOpponentCaptureImmediately(board, m.row, m.col, color, koPoint)) continue;
    if (mode === "full" || mode === "master") m.score += safety * 0.5;
    keep.push(m);
  }
  // 全部危险时保留最安全的点，避免无子可下
  if (keep.length === 0) keep.push(cands[safestIdx]);
  cands.length = 0;
  cands.push(...keep);
}

// ====== 威胁检测 + 强制防守 + 收益排序（让AI更聪明） ======

// 局面分类（贴合兵力：分差相对总兵力，兵力少时阈值更敏感）
function classifySituation(scoreDiff: number, pieceLimit: number): Situation {
  const rel = scoreDiff / Math.max(1, pieceLimit);
  if (rel > 0.15) return "leading";
  if (rel < -0.15) return "trailing";
  return "balanced";
}

// 对手威胁检测：模拟对手全部候选，找对己方危害最大的着法（提吃/围困压缩/形成大包围圈/救援等）
function detectThreat(
  board: BoardModel,
  toMove: Color,
  koPoint: Point,
  history: HistoryTable,
  komi: number,
  pieceLimit: number,
  distWeight: number
): ThreatInfo | null {
  const opp = opponent(toMove);
  const oppCtx: CandCtx = { ready: countOwnHalf(board, opp) >= 10, deploy: false, opening: false };
  const oppCands = genBattleCandidates(board, opp, koPoint, history, oppCtx);
  const cur = quickEvaluate(board, toMove, komi, pieceLimit, 0, 0, distWeight);
  let best: ThreatInfo | null = null;
  for (const m of oppCands) {
    const sim = board.clone();
    const res = GoRules.tryMove(sim, m.row, m.col, opp, koPoint);
    if (!res.legal) continue;
    const after = quickEvaluate(sim, toMove, komi, pieceLimit, 0, 0, distWeight);
    const gain = -(after - cur); // 对手收益 = root 视角价值下降
    if (gain > 0 && (best === null || gain > best.gain)) {
      best = { row: m.row, col: m.col, gain, reason: m.reason, captureSize: res.captured.length };
    }
  }
  return best;
}

// 强制防守：威胁过大时，能贴近威胁点的候选加分（阻断），远离的进攻点降级
function applyThreatDefense(cands: ScoredMove[], threat: ThreatInfo | null): void {
  if (threat === null) return;
  for (const m of cands) {
    if (m.cat === CAT.CAPTURE || m.cat === CAT.RESCUE || m.cat === CAT.BREAK || m.cat === CAT.COMPRESS) continue;
    const near = Math.max(Math.abs(m.row - threat.row), Math.abs(m.col - threat.col)) <= 2;
    if (near) m.score += 15; // 贴近威胁点 = 能消除/降低威胁，加分
    else m.score *= 0.5;     // 远离威胁的进攻点降级
  }
}

// ====== 战略意图选择器（文档 v7.0 §5，困难+） ======
type StrategicIntent = "build" | "annihilate" | "borderfight" | "defend" | "resource";

// 边境线己方棋子数（边境控制权）
function countBorderOwn(board: BoardModel, color: Color): number {
  let n = 0;
  for (let c = 0; c < board.size; c++) {
    if (board.grid[BORDER_ROW * board.size + c] === color) n++;
  }
  return n;
}

// 意图选择：资源紧张→消耗战；落后→防守反击；对方在己方领地有弱棋→歼灭入侵；
// 边境线失守→边境争夺；否则→围大空
function chooseIntent(
  board: BoardModel,
  color: Color,
  situation: Situation,
  ratio: number,
  borderOwn: number
): StrategicIntent {
  if (ratio < 0.4) return "resource";
  if (situation === "trailing") return "defend";
  const opp = opponent(color);
  for (const g of collectGroups(board)) {
    if (g.color !== opp) continue;
    // 对方在己方领地有被围/濒危弱棋 → 歼灭入侵（提吃+压缩）
    if (groupIsConfined(board, g) || g.libs.length <= 3) return "annihilate";
  }
  if (borderOwn < 6) return "borderfight";
  return "build";
}

// 意图→候选方向加权（只调增减，不改变候选本身；战术必下着法不受压制）
// 战术死活候选（压缩/提吃/救援/突破）是杀棋/做活的"必下点"，意图加权只做方向引导，
// 不应因当前意图而减分压制，否则困难/大师在杀棋题会去抢边境线而忽略杀棋点。
function isTactical(cat: string): boolean {
  return cat === CAT.COMPRESS || cat === CAT.CAPTURE || cat === CAT.RESCUE || cat === CAT.BREAK || cat === CAT.CUT || cat === CAT.REINFORCE;
}
function applyIntentWeight(cands: ScoredMove[], intent: StrategicIntent): void {
  for (const m of cands) {
    switch (intent) {
      case "resource": // 高效得分、保留资源：效率奖励/边境线优先
        if (m.cat === CAT.EFFICIENCY || m.cat === CAT.BORDER) m.score += 6;
        else if (!isTactical(m.cat)) m.score -= 4;
        break;
      case "annihilate": // 歼灭入侵：提吃/压缩优先
        if (m.cat === CAT.CAPTURE || m.cat === CAT.COMPRESS) m.score += 8;
        break;
      case "borderfight": // 边境线争夺
        if (m.cat === CAT.BORDER) m.score += 8;
        else if (!isTactical(m.cat)) m.score -= 2;
        break;
      case "build": // 围大空：扩圈/效率阈值优先
        if (m.cat === CAT.EFFICIENCY || m.cat === CAT.EXPAND) m.score += 8;
        break;
      case "defend": // 防守反击：救援/补强优先，压制渗透
        if (m.cat === CAT.RESCUE || m.cat === CAT.DEFEND) m.score += 8;
        else if (m.cat === CAT.INFILTRATE) m.score -= 12;
        break;
    }
  }
}

// ====== §6 死活强化（文档 v7.0 §6.5 困难/大师） ======
// 现有 RESCUE/COMPRESS 已完成"被围块目标识别（空点4~5、无两眼）"与基础做活/杀棋候选。
// 这里进一步对濒危块做"做活(+6)/杀棋(+5)"评分强化，拉进文档数值区间（做活≈90 / 杀棋≈92），
// 且仅对的确能影响死活块的关键点加成，避免稀释全局候选排序。
function applyLifeDeathBoost(cands: ScoredMove[], board: BoardModel, toMove: Color): Map<number, number> {
  const opp = opponent(toMove);
  const groups = collectGroups(board);
  const size = board.size;
  const boostByIdx = new Map<number, number>(); // idx -> 加分（取最大）
  for (const g of groups) {
    if (g.color !== toMove && g.color !== opp) continue;
    if (!groupIsBoxedIn(board, g, g.color)) continue;  // 未被围困（可连通至棋盘边缘）
    if (g.libs.length < 2 || g.libs.length > 5) continue; // 空点2~5（含3点做活/4点杀棋等濒危生死关键；<2为单纯打吃由CAPTURE/RESCUE处理）
    // 不再以 groupEyeCandidates>=2 排除：眼窝内空点四邻多为己子，误判"已活"会斩断做活块的 boost。
    if (g.color === toMove && groupIsDead(board, g, toMove)) continue; // 己方死棋不救
    // 己方被围但可活：救活整组价值≈组子数×2（逼近 quickEvaluate 死活奖惩阶跃，防深搜索(border 全局涨到几十)淹没救活单步）；
    // 对方被围可杀：加强攻击点。
    const n = g.stones.length;
    const boost = g.color === toMove ? Math.min(90, 8 + n * 2) : Math.min(90, 6 + n);
    for (const lib of g.libs) {
      const cur = boostByIdx.get(lib) ?? 0;
      if (boost > cur) boostByIdx.set(lib, boost);
    }
  }
  if (boostByIdx.size === 0) return boostByIdx;
  for (const m of cands) {
    const idx = m.row * size + m.col;
    const b = boostByIdx.get(idx);
    if (b !== undefined) m.score += b;
  }
  return boostByIdx;
}

// 按实际收益排序（搜索顺序优化：收益高的先搜，剪枝更有效；替代固定"吃子优先"）
function sortCandidatesByGain(
  cands: ScoredMove[],
  board: BoardModel,
  toMove: Color,
  koPoint: Point,
  komi: number,
  pieceLimit: number,
  distWeight: number
): void {
  if (cands.length <= 1) return;
  const cur = quickEvaluate(board, toMove, komi, pieceLimit, 0, 0, distWeight);
  const gainOf = (m: ScoredMove): number => {
    const sim = board.clone();
    const res = GoRules.tryMove(sim, m.row, m.col, toMove, koPoint);
    if (!res.legal) return -Infinity;
    return quickEvaluate(sim, toMove, komi, pieceLimit, 0, 0, distWeight) - cur;
  };
  // 主要排序按实际收益；strategy/意图加权通过 score 作次要键软性引导
  cands.sort((a, b) => gainOf(b) - gainOf(a) || b.score - a.score);
}

// ====== Alpha-Beta / PVS / 静态搜索（文档 §三） ======

// 对手最高威胁（威胁检测结果）
interface ThreatInfo {
  row: number;
  col: number;
  gain: number;       // 对手落子后收益（对手视角，>0 即对己方不利）
  reason: string;
  captureSize: number;
}

type Situation = "leading" | "balanced" | "trailing";

interface SearchState {
  board: BoardModel;
  toMove: Color;
  koPoint: Point;
  komi: number;
  pieceLimit: number;
  rootColor: Color;
  prisRoot: number; // 已提对方子数（root 视角）
  prisOpp: number;  // 已提 root 方子数
  history: HistoryTable;
  tt: TranspositionTable | null;
  deadline: number;
  config: AIConfig;
  threat: ThreatInfo | null;   // 对手最高威胁（防守模式触发用）
  situation: Situation;        // 局面分类（领先/均势/落后）
  intent: StrategicIntent;     // 战略意图（文档 §5，困难+驱动候选方向加权）
  ec: EvalCtx | undefined;   // 战略/多目标评估上下文（文档 v9.0 §8，根层每手预计算）
}

// 静态搜索：只展开战术着法（提吃/围困压缩/救援/突破包围圈），避免搜索爆炸（文档 §3.3）
function quiescenceSearch(
  st: SearchState,
  alpha: number,
  beta: number,
  depth: number
): number {
  const base = quickEvaluate(st.board, st.rootColor, st.komi, st.pieceLimit, 0, 0, st.config.distWeight, st.ec);
    // 负极大值形式：当前节点对 toMove 有利 = -对 root 有利（若 toMove 非 root）
  let score = st.toMove === st.rootColor ? base : -base;
  if (score >= beta) return beta;
  if (score > alpha) alpha = score;
  if (depth <= 0) return alpha;

  // 仅生成战术候选（提/救/压/破），降低开销
  const opp = opponent(st.toMove);
  const groups = collectGroups(st.board);
  const moves: Array<{ row: number; col: number }> = [];
  for (const g of groups) {
    if (g.libs.length === 1) {
      if (g.color === opp) moves.push({ row: Math.floor(g.libs[0] / st.board.size), col: g.libs[0] % st.board.size });
      continue;
    }
  }
  for (const m of moves) {
    if (Date.now() > st.deadline) break;
    const sim = st.board.clone();
    const res = GoRules.tryMove(sim, m.row, m.col, st.toMove, st.koPoint);
    if (!res.legal) continue;
    const child: SearchState = {
      ...st,
      board: sim,
      toMove: opponent(st.toMove),
      koPoint: res.koPoint ?? { row: -1, col: -1 },
      prisRoot: st.prisRoot + (st.toMove === st.rootColor ? res.captured.length : 0),
      prisOpp: st.prisOpp + (st.toMove === st.rootColor ? 0 : res.captured.length),
    };
    const val = -quiescenceSearch(child, -beta, -alpha, depth - 1);
    if (val >= beta) return beta;
    if (val > alpha) alpha = val;
  }
  return alpha;
}

// Alpha-Beta 负极大值（全难度）；大师用 PVS 零窗口（文档 §3.2）
function alphaBeta(
  st: SearchState,
  depth: number,
  alpha: number,
  beta: number,
  ply: number
): number {
  const hash = boardHash(st.board);
  if (st.tt) {
    const e = st.tt.get(hash);
    if (e && e.depth >= depth) {
      if (e.flag === "exact") return e.score;
      if (e.flag === "lower" && e.score >= beta) return e.score;
      if (e.flag === "upper" && e.score <= alpha) return e.score;
    }
  }

  if (depth <= 0) {
    return quiescenceSearch(st, alpha, beta, 3);
  }
  if (Date.now() > st.deadline) return alpha;

  const ctx: CandCtx = { ready: countOwnHalf(st.board, st.rootColor) >= 10, deploy: false, opening: ply < 4 };
  const cands = genCandidates(st.board, st.toMove, st.koPoint, st.config.branch, st.history, ctx, st.config.diversity);
  if (cands.length === 0) {
    // 无候选 → 虚手或直接评估
    const base = quickEvaluate(st.board, st.rootColor, st.komi, st.pieceLimit, 0, 0, st.config.distWeight, st.ec);
    return st.toMove === st.rootColor ? base : -base;
  }

  let best = -Infinity;
  let bestFlag: TTEntry["flag"] = "upper";
  for (let i = 0; i < cands.length; i++) {
    const m = cands[i];
    const sim = st.board.clone();
    const res = GoRules.tryMove(sim, m.row, m.col, st.toMove, st.koPoint);
    if (!res.legal) continue;
    const child: SearchState = {
      ...st,
      board: sim,
      toMove: opponent(st.toMove),
      koPoint: res.koPoint ?? { row: -1, col: -1 },
      prisRoot: st.prisRoot + (st.toMove === st.rootColor ? res.captured.length : 0),
      prisOpp: st.prisOpp + (st.toMove === st.rootColor ? 0 : res.captured.length),
    };
    let val: number;
    if (st.config.usePVS && i > 0) {
      // 零窗口试探
      val = -alphaBeta(child, depth - 1, -alpha - 1, -alpha, ply + 1);
      if (val > alpha && val < beta) {
        val = -alphaBeta(child, depth - 1, -beta, -alpha, ply + 1);
      }
    } else {
      val = -alphaBeta(child, depth - 1, -beta, -alpha, ply + 1);
    }
    st.history.bump(m.cat, val > 0 ? 1 : -0.5);
    if (val > best) { best = val; bestFlag = "exact"; }
    if (val > alpha) alpha = val;
    if (alpha >= beta) { bestFlag = "lower"; break; }
  }
  if (st.tt) st.tt.set(hash, depth, best, bestFlag);
  return best;
}

// 迭代加深根搜索（大师，文档 §3.1）
function iterativeDeepeningRoot(
  st: SearchState,
  depth: number
): { move: ScoredMove | null; score: number } {
  const ctx: CandCtx = { ready: countOwnHalf(st.board, st.rootColor) >= 10, deploy: false, opening: false };
  const cands = genCandidates(st.board, st.toMove, st.koPoint, st.config.maxCandidates, st.history, ctx, st.config.diversity);
  applyMoveSafety(cands, st.board, st.toMove, st.koPoint, st.config.safety);
  applyThreatDefense(cands, st.threat);
  applyIntentWeight(cands, st.intent);
  const ldKeyPoints = applyLifeDeathBoost(cands, st.board, st.toMove);
  sortCandidatesByGain(cands, st.board, st.toMove, st.koPoint, st.komi, st.pieceLimit, st.config.distWeight);
  let bestMove: ScoredMove | null = null;
  let bestScore = -Infinity;
  for (let d = 1; d <= depth && Date.now() <= st.deadline; d++) {
    let curBest: ScoredMove | null = null;
    let curScore = -Infinity;
    for (const m of cands) {
      if (Date.now() > st.deadline) break;
      const sim = st.board.clone();
      const res = GoRules.tryMove(sim, m.row, m.col, st.toMove, st.koPoint);
      if (!res.legal) continue;
      const child: SearchState = {
        ...st,
        board: sim,
        toMove: opponent(st.toMove),
        koPoint: res.koPoint ?? { row: -1, col: -1 },
      };
      // 死活关键点根层保底：迭代加深深挖会把死活着点 val 淹没在全局 eval 里，手动保底优先
      // 保底值取 applyLifeDeathBoost 按组群规模缩放的 boost（救活大组价值高），而非固定小值
      const val = -alphaBeta(child, d - 1, -Infinity, Infinity, 1) +
        (ldKeyPoints.get(m.row * st.board.size + m.col) ?? 0);
      if (val > curScore) { curScore = val; curBest = m; }
    }
    if (curBest) { bestMove = curBest; bestScore = curScore; }
  }
  return { move: bestMove, score: bestScore };
}

// MCTS（困难/大师关键局面，文档 §六）
function mctsSearch(
  st: SearchState,
  sims: number
): ScoredMove | null {
  const ctx: CandCtx = { ready: countOwnHalf(st.board, st.rootColor) >= 10, deploy: false, opening: false };
  const rootCands = genCandidates(st.board, st.toMove, st.koPoint, st.config.maxCandidates, st.history, ctx, st.config.diversity);
  applyMoveSafety(rootCands, st.board, st.toMove, st.koPoint, st.config.safety);
  applyThreatDefense(rootCands, st.threat);
  applyIntentWeight(rootCands, st.intent);
  if (st.config.useTT || st.config.useIterative) applyLifeDeathBoost(rootCands, st.board, st.toMove);
  sortCandidatesByGain(rootCands, st.board, st.toMove, st.koPoint, st.komi, st.pieceLimit, st.config.distWeight);
  if (rootCands.length === 0) return null;
  const visits = new Map<number, number>();
  const wins = new Map<number, number>();
  const deadline = st.deadline;
  let simCount = 0;
  while (simCount < sims && Date.now() <= deadline) {
    // 根节点 UCT 选点
    let bestCand: ScoredMove | null = null;
    let bestUct = -Infinity;
    for (const m of rootCands) {
      const key = m.row * st.board.size + m.col;
      const n = visits.get(key) ?? 0;
      const w = wins.get(key) ?? 0;
      let uct: number;
      if (n === 0) uct = m.score + Math.random() * 50;
      else uct = (w / n) + Math.sqrt(2 * Math.log(Math.max(1, simCount)) / n) + m.score * 1e-4;
      if (uct > bestUct) { bestUct = uct; bestCand = m; }
    }
    if (bestCand === null) break;
    // 模拟
    const sim = st.board.clone();
    const res = GoRules.tryMove(sim, bestCand.row, bestCand.col, st.toMove, st.koPoint);
    if (!res.legal) { break; }
    const val = mctsSimulate(sim, opponent(st.toMove), res.koPoint ?? { row: -1, col: -1 }, st, 0);
    const key = bestCand.row * st.board.size + bestCand.col;
    visits.set(key, (visits.get(key) ?? 0) + 1);
    wins.set(key, (wins.get(key) ?? 0) + (val > 0 ? 1 : 0));
    simCount++;
  }
  let best: ScoredMove | null = null;
  let bestScore = -Infinity;
  for (const m of rootCands) {
    const key = m.row * st.board.size + m.col;
    const n = visits.get(key) ?? 0;
    const w = wins.get(key) ?? 0;
    const score = n === 0 ? 0 : w / n;
    if (score > bestScore) { bestScore = score; best = m; }
  }
  return best;
}

// MCTS 引导式模拟（文档 §6.1）：战术候选优先，Softmax 选择
function mctsSimulate(
  board: BoardModel,
  toMove: Color,
  koPoint: Point,
  st: SearchState,
  depth: number
): number {
  if (depth >= 20 || Date.now() > st.deadline) {
    return quickEvaluate(board, st.rootColor, st.komi, st.pieceLimit, 0, 0, st.config.distWeight, st.ec);
  }
  const opp = opponent(toMove);
  // 战术候选（提吃优先）
  const groups = collectGroups(board);
  for (const g of groups) {
    if (g.color === opp && g.libs.length === 1) {
      const lib = g.libs[0];
      const sim = board.clone();
      if (GoRules.tryMove(sim, Math.floor(lib / board.size), lib % board.size, toMove, koPoint).legal) {
        return -mctsSimulate(sim, opp, { row: -1, col: -1 }, st, depth + 1);
      }
    }
  }
  // 战略候选
  const ctx: CandCtx = { ready: countOwnHalf(board, st.rootColor) >= 10, deploy: false, opening: false };
  const cands = genCandidates(board, toMove, koPoint, 12, st.history, ctx);
  if (cands.length > 0) {
    // Softmax（temperature=0.7 简化：按分数加权随机）
    const total = cands.reduce((a, m) => a + Math.max(1, m.score), 0);
    let pick = Math.random() * total;
    for (const m of cands) {
      pick -= Math.max(1, m.score);
      if (pick <= 0) {
        const sim = board.clone();
        const res = GoRules.tryMove(sim, m.row, m.col, toMove, koPoint);
        if (res.legal) {
          return -mctsSimulate(sim, opp, res.koPoint ?? { row: -1, col: -1 }, st, depth + 1);
        }
      }
    }
  }
  return quickEvaluate(board, st.rootColor, st.komi, st.pieceLimit, 0, 0, st.config.distWeight, st.ec);
}

// ====== 虚手评估（文档 §五） ======
function shouldPass(bestGain: number, resRatio: number): boolean {
  // 终局临近（剩余兵力比例越低越积极）：子越少越倾向虚手结束，避免空耗子力
  // 剩余兵力充足时保持保守，仅当最佳着法几乎无收益时才虚手（避免提前终局）
  const thr = resRatio < 0.2 ? 2.0 : resRatio < 0.35 ? 1.0 : 0.5;
  return bestGain < thr;
}

// ====== 时间管理（文档 §八.2）：单手思考 = 基础 × 阶段系数 × 资源系数 × 局势系数 ======
function dynamicThinkTime(
  config: AIConfig,
  session: GameSession,
  scoreDiff: number
): number {
  const ply = session.ply;
  let phaseCoef: number;
  if (ply < 4) phaseCoef = 0.3;
  else if (ply < 30) phaseCoef = 0.8;
  else if (ply < 100) phaseCoef = 1.0;
  else phaseCoef = 1.2;
  let resCoef: number;
  const left = session.piecesLeft(session.toMove);
  const ratio = session.pieceLimit > 0 ? left / session.pieceLimit : 1;
  if (ratio > 0.7) resCoef = 0.8;
  else if (ratio > 0.4) resCoef = 1.0;
  else if (ratio > 0.2) resCoef = 1.2;
  else resCoef = 1.5;
  let sitCoef: number;
  // 局势系数按相对兵力的分差（资源紧张时微小分差更关键）
  const rel = Math.abs(scoreDiff) / Math.max(1, session.pieceLimit);
  if (rel > 0.15) sitCoef = 0.5;
  else if (rel > 0.05) sitCoef = 0.8;
  else sitCoef = 1.0;
  const ms = config.thinkTimeMs * phaseCoef * resCoef * sitCoef;
  return Math.max(120, Math.min(config.thinkTimeMs * 2, Math.round(ms)));
}

// ====== 搜索引擎 ======
class SearchEngine {
  private readonly history = new HistoryTable();
  private readonly tt = new TranspositionTable();
  private readonly gameHistory = new HistoryTable();

  findBestMove(session: GameSession, aiColor: Color, config: AIConfig): AIMove {
    if (session.piecesLeft(aiColor) <= 0) {
      return { type: "pass", row: -1, col: -1, reason: "兵力用尽" };
    }

    // 布局阶段：部署候选（己方领土）
    if (session.isInDeployPhase()) {
      const ctx: CandCtx = { ready: false, deploy: true, opening: true };
      const cands = genCandidates(session.board, aiColor, session.koPoint, config.maxCandidates, this.gameHistory, ctx);
      if (cands.length > 0) {
        const pick = cands[Math.floor(Math.random() * Math.min(3, cands.length))];
        return { type: "move", row: pick.row, col: pick.col, reason: "布局" };
      }
    }

    // 战术快通道：对方 1 气组群 → 立即提（本游戏提子 +2/子，价值极高）
    {
      const opp = opponent(aiColor);
      const groups = collectGroups(session.board);
      let bestCap: { row: number; col: number; n: number } | null = null;
      for (const g of groups) {
        if (g.color !== opp || g.libs.length !== 1) continue;
        const lib = g.libs[0];
        const sim = session.board.clone();
        if (GoRules.tryMove(sim, Math.floor(lib / session.board.size), lib % session.board.size, aiColor, session.koPoint).legal) {
          if (bestCap === null || g.stones.length > bestCap.n) {
            bestCap = { row: Math.floor(lib / session.board.size), col: lib % session.board.size, n: g.stones.length };
          }
        }
      }
      if (bestCap !== null && bestCap.n >= 2) {
        return { type: "move", row: bestCap.row, col: bestCap.col, reason: `提吃${bestCap.n}子` };
      }
    }

    const score = session.scores();
    const scoreDiff = score.black.occupationTerritory + score.black.occupationEfficiency + score.black.defenseSiege - score.white.occupationTerritory - score.white.occupationEfficiency - score.white.defenseSiege;
    // 局面分类（相对兵力）+ 对手威胁检测（根层每手一次）
    const situation = classifySituation(aiColor === Color.BLACK ? scoreDiff : -scoreDiff, session.pieceLimit);
    const distW = config.distWeight;
    const threatDetected = config.safety !== "off"
      ? detectThreat(session.board, aiColor, session.koPoint, this.history, session.komi, session.pieceLimit, distW)
      : null;
    // 强制防守触发：威胁收益 > 动态阈值(5×阶段×兵力) 且 > 己方总分10%，或对方可提 ≥5 子
    const myBd = aiColor === Color.BLACK ? score.black : score.white;
    const myTotal = Math.abs(myBd.occupationTerritory + myBd.occupationEfficiency + myBd.defenseAnnihilate + myBd.defenseSiege + myBd.casualtyLoss + myBd.casualtySpecial);
    const resRatio = session.pieceLimit > 0 ? session.piecesLeft(aiColor) / session.pieceLimit : 1;
    const phaseCoef = session.ply >= 100 ? 0.6 : session.ply >= 40 ? 0.8 : 1.0;
    const resCoef = resRatio < 0.2 ? 0.6 : resRatio < 0.4 ? 0.8 : 1.0;
    const dynThreshold = Math.max(3, 5 * phaseCoef * resCoef);
    const threat: ThreatInfo | null =
      threatDetected !== null && (threatDetected.gain > Math.max(dynThreshold, myTotal * 0.1) || threatDetected.captureSize >= 5)
        ? threatDetected
        : null;
    const thinkMs = dynamicThinkTime(config, session, aiColor === Color.BLACK ? scoreDiff : -scoreDiff);
    const deadline = Date.now() + thinkMs;
    // 战略意图（文档 §5，困难+）：驱动候选方向加权
    const intent: StrategicIntent = chooseIntent(session.board, aiColor, situation, resRatio, countBorderOwn(session.board, aiColor));

    const st: SearchState = {
      board: session.board.clone(),
      toMove: aiColor,
      koPoint: session.koPoint,
      komi: session.komi,
      pieceLimit: session.pieceLimit,
      rootColor: aiColor,
      prisRoot: 0,
      prisOpp: 0,
      history: this.history,
      tt: config.useTT ? this.tt : null,
      deadline,
      config,
      threat,
      situation,
      intent,
      ec: buildEvalCtx(session, aiColor),
    };

    // 主搜索
    let best: ScoredMove | null = null;
    let bestScore = -Infinity;
    // MCTS 返回胜率而非收益值，其 bestScore 保持 -Infinity；终局增益单独用静态评估差计算（文档 §五）
    let mctsGain: number | null = null;
    if (config.useIterative) {
      const r = iterativeDeepeningRoot(st, config.refinePly);
      best = r.move;
      bestScore = r.score;
    } else {
      // 大劣时放宽敌后渗透（冒险渗透，敢于牺牲找翻盘）
      const ctx: CandCtx = { ready: countOwnHalf(session.board, aiColor) >= 10 || situation === "trailing", deploy: false, opening: false };
      const cands = genCandidates(session.board, aiColor, session.koPoint, config.maxCandidates, this.history, ctx, config.diversity);
      applyMoveSafety(cands, session.board, aiColor, session.koPoint, config.safety);
      applyThreatDefense(cands, threat);
      applyIntentWeight(cands, intent);
      const ldKeyPoints = applyLifeDeathBoost(cands, session.board, aiColor);
      sortCandidatesByGain(cands, session.board, aiColor, session.koPoint, session.komi, session.pieceLimit, distW);
      for (const m of cands) {
        if (Date.now() > deadline) break;
        const sim = session.board.clone();
        const res = GoRules.tryMove(sim, m.row, m.col, aiColor, session.koPoint);
        if (!res.legal) continue;
        const child: SearchState = { ...st, board: sim, toMove: opponent(aiColor), koPoint: res.koPoint ?? { row: -1, col: -1 } };
        const val = -alphaBeta(child, config.refinePly - 1, -Infinity, Infinity, 1) +
          (ldKeyPoints.get(m.row * session.board.size + m.col) ?? 0);
        if (Date.now() > deadline) break;
        if (val > bestScore) { bestScore = val; best = m; }
      }
      // 困难/大师：关键局面补充 MCTS（文档 §6.3 触发条件：资源紧张 / 分数接近 / 大量围困）
      // 关键：需进入中盘（全局 ≥40 子）才触发——开局双方分差恒为 0，若直接按
      // |scoreDiff|<5 触发则每步都跑 MCTS，HARD 每手飙到数秒（实测 100 手 76 秒）。
      const piecesLeft = session.piecesLeft(aiColor);
      const ratio = session.pieceLimit > 0 ? piecesLeft / session.pieceLimit : 1;
      const siegedMy = session.siegedGroups().filter((g) => g.color === aiColor).reduce((a, g) => a + g.stones.length, 0);
      const placedAll = session.board.countColor(Color.BLACK) + session.board.countColor(Color.WHITE);
      if (config.mctsSims > 0 && placedAll >= 40 && (ratio < 0.2 || Math.abs(scoreDiff) < 5 || siegedMy > 5 || situation === "trailing")) {
        // 战术死活候选（杀棋压缩/提吃/救援/突破）或死活关键点是一手必杀/必活的强制着，
        // 浅搜索已能精准判定；MCTS 随机模拟会把单步死活稀释成"看起来收益普通"，不得覆盖。
        const aliveKeyPoint = best !== null && ldKeyPoints.has(best.row * session.board.size + best.col);
        const tacticalBest = best !== null && (isTactical(best.cat) || aliveKeyPoint);
        const m = tacticalBest ? null : mctsSearch(st, config.mctsSims);
        if (m !== null) {
          best = m;
          // 静态评估差：落子后 - 落子前（否则 -Infinity 触发恒虚手，HARD 中盘即疯狂 pass）
          const sim = session.board.clone();
          const res = GoRules.tryMove(sim, m.row, m.col, aiColor, session.koPoint);
          if (res.legal) {
            const after = quickEvaluate(sim, aiColor, session.komi, session.pieceLimit, 0, 0, config.distWeight);
            const before = quickEvaluate(session.board, aiColor, session.komi, session.pieceLimit, 0, 0, config.distWeight);
            mctsGain = after - before;
          }
        }
      }
    }

    if (best === null) {
      const ctx2: CandCtx = { ready: true, deploy: false, opening: false };
      const cands2 = genCandidates(session.board, aiColor, session.koPoint, config.maxCandidates, this.history, ctx2, config.diversity);
      return this._pickFirstLegal(session.board, cands2, aiColor, session.koPoint);
    }

    // 最终合法性校验（MCTS/迭代加深可能返回劫争禁着点）
    if (!GoRules.isLegal(session.board, best.row, best.col, aiColor, session.koPoint)) {
      const ctx2: CandCtx = { ready: true, deploy: false, opening: false };
      const cands2 = genCandidates(session.board, aiColor, session.koPoint, config.maxCandidates, this.history, ctx2, config.diversity);
      return this._pickFirstLegal(session.board, cands2, aiColor, session.koPoint);
    }

    // 虚手评估（终局）：中后盘且最佳着法增益极低 → 虚手
    const placed = session.board.countColor(Color.BLACK) + session.board.countColor(Color.WHITE);
    const passCount = session.passCounts.get(aiColor) ?? 0;
    const passCooldown = session.passCooldown.get(aiColor) ?? PASS_COOLDOWN_TURNS;
    const passAvailable = passCount < PASS_LIMIT_PER_GAME && passCooldown >= PASS_COOLDOWN_TURNS;
    const baseScore = quickEvaluate(session.board, aiColor, session.komi, session.pieceLimit, 0, 0, config.distWeight);
    const bestGain = mctsGain !== null ? mctsGain : bestScore - baseScore;
    const resRatioEnd = session.pieceLimit > 0 ? session.piecesLeft(aiColor) / session.pieceLimit : 1;
    if (passAvailable && placed >= 70 && shouldPass(bestGain, resRatioEnd)) {
      return { type: "pass", row: -1, col: -1, reason: "局面已定型，虚手" };
    }

    return { type: "move", row: best.row, col: best.col, reason: best.reason };
  }

  private _pickFirstLegal(
    board: BoardModel,
    cands: ScoredMove[],
    color: Color,
    koPoint: Point
  ): AIMove {
    for (const m of cands) {
      if (!board.inBounds(m.row, m.col)) continue;
      if (GoRules.isLegal(board, m.row, m.col, color, koPoint)) {
        return { type: "move", row: m.row, col: m.col, reason: m.reason };
      }
    }
    // 全不合法 → 全盘找任意合法点
    for (let r = 0; r < board.size; r++) {
      for (let c = 0; c < board.size; c++) {
        if (GoRules.isLegal(board, r, c, color, koPoint)) {
          return { type: "move", row: r, col: c, reason: "兜底落子" };
        }
      }
    }
    return { type: "pass", row: -1, col: -1, reason: "无合法点" };
  }
}

// ====== 开局模式库（困难/大师，文档 §七） ======
// 简化：模式选择在布局阶段由 `genDeployCandidates` 的评分体现（边境线/角部/中央），
// 困难/大师在部署阶段偏好边境线附近（抢线型默认），普通/简单偏好角部。

// ====== AI 引擎总控 ======
export class AIEngine {
  readonly color: Color;
  private readonly difficulty: AIDifficulty;
  private readonly searchEngine = new SearchEngine();

  constructor(color: Color, difficulty: AIDifficulty = AIDifficulty.NORMAL) {
    this.color = color;
    this.difficulty = difficulty;
  }

  chooseMove(session: GameSession): AIMove {
    const config = getAIConfig(this.difficulty);
    return this.searchEngine.findBestMove(session, this.color, config);
  }
}

// ====== 临时诊断导出（定位后移除） ======
export function __dbgCandPipeline(board: BoardModel, toMove: Color, safety: "off" | "filter" | "full" | "master", maxCand: number): any {
  const ctx: CandCtx = { ready: true, deploy: false, opening: false };
  const ko = { row: -1, col: -1 };
  let cands = genCandidates(board, toMove, ko, maxCand, new HistoryTable(), ctx, "full");
  const all = cands.map((m) => ({ r: m.row, c: m.col, cat: m.cat, s: m.score }));
  const ld = applyLifeDeathBoost(cands, board, toMove);
  const afterBoost = cands.map((m) => ({ r: m.row, c: m.col, cat: m.cat, s: m.score, ld: ld.has(m.row * board.size + m.col) }));
  applyMoveSafety(cands, board, toMove, ko, safety);
  const afterSafety = cands.map((m) => ({ r: m.row, c: m.col, cat: m.cat, s: m.score }));
  const size = board.size;
  const removedIds = new Set(all.map((m) => m.r * size + m.c));
  for (const m of afterSafety) removedIds.delete(m.r * size + m.c);
  const removed = all.filter((m) => removedIds.has(m.r * size + m.c) && (ld.has(m.r * size + m.c) || m.cat === "EXPAND"));
  return { all, afterBoost, afterSafety, removed };
}

// 临时诊断：复刻根搜索，输出各候选 -alphaBeta+boost 值（固定深度 depth）
export function __dbgRootVals(session: GameSession, aiColor: Color, depth: number): any {
  const config = getAIConfig(AIDifficulty.MASTER);
  const history = new HistoryTable();
  const score = session.scores();
  const scoreDiff = score.black.occupationTerritory + score.black.occupationEfficiency + score.black.defenseSiege - score.white.occupationTerritory - score.white.occupationEfficiency - score.white.defenseSiege;
  const situation = classifySituation(aiColor === Color.BLACK ? scoreDiff : -scoreDiff, session.pieceLimit);
  const distW = config.distWeight;
  const threatDetected = detectThreat(session.board, aiColor, session.koPoint, history, session.komi, session.pieceLimit, distW);
  const myBd = aiColor === Color.BLACK ? score.black : score.white;
  const myTotal = Math.abs(myBd.occupationTerritory + myBd.occupationEfficiency + myBd.defenseAnnihilate + myBd.defenseSiege + myBd.casualtyLoss + myBd.casualtySpecial);
  const resRatio = session.pieceLimit > 0 ? session.piecesLeft(aiColor) / session.pieceLimit : 1;
  const dynThreshold = 5;
  const threat: ThreatInfo | null = threatDetected !== null && (threatDetected.gain > Math.max(dynThreshold, myTotal * 0.1) || threatDetected.captureSize >= 5) ? threatDetected : null;
  const deadline = Date.now() + 60000;
  const intent: StrategicIntent = chooseIntent(session.board, aiColor, situation, resRatio, countBorderOwn(session.board, aiColor));
  const st: SearchState = {
    board: session.board.clone(),
    toMove: aiColor,
    koPoint: session.koPoint,
    komi: session.komi,
    pieceLimit: session.pieceLimit,
    rootColor: aiColor,
    prisRoot: 0,
    prisOpp: 0,
    history,
    tt: config.useTT ? new TranspositionTable() : null,
    deadline,
    config,
    threat,
    situation,
    intent,
    ec: buildEvalCtx(session, aiColor),
  };
  const ctx: CandCtx = { ready: countOwnHalf(st.board, st.rootColor) >= 10, deploy: false, opening: false };
  const cands = genCandidates(st.board, st.toMove, st.koPoint, config.maxCandidates, st.history, ctx, config.diversity);
  applyMoveSafety(cands, st.board, st.toMove, st.koPoint, config.safety);
  applyThreatDefense(cands, st.threat);
  applyIntentWeight(cands, st.intent);
  const ld = applyLifeDeathBoost(cands, st.board, st.toMove);
  sortCandidatesByGain(cands, st.board, st.toMove, st.koPoint, st.komi, st.pieceLimit, config.distWeight);
  const rows: any[] = [];
  for (const m of cands) {
    if (Date.now() > deadline) break;
    const sim = st.board.clone();
    const res = GoRules.tryMove(sim, m.row, m.col, st.toMove, st.koPoint);
    if (!res.legal) continue;
    const child: SearchState = { ...st, board: sim, toMove: opponent(st.toMove), koPoint: res.koPoint ?? { row: -1, col: -1 } };
    const val = -alphaBeta(child, depth - 1, -Infinity, Infinity, 1) + (ld.get(m.row * st.board.size + m.col) ?? 0);
    rows.push({ r: m.row, c: m.col, cat: m.cat, baseS: m.score, ld: ld.has(m.row * st.board.size + m.col), val });
  }
  rows.sort((a, b) => b.val - a.val);
  const evBefore = quickEvaluate(st.board, st.rootColor, st.komi, st.pieceLimit, 0, 0, config.distWeight);
  const firstWin = rows.find((a) => a.ld) ?? rows[0];
  const simW = st.board.clone();
  const lres = GoRules.tryMove(simW, firstWin?.r ?? 0, firstWin?.c ?? 0, st.toMove, st.koPoint);
  const evAfterWin = lres.legal ? quickEvaluate(simW, st.rootColor, st.komi, st.pieceLimit, 0, 0, config.distWeight) : NaN;
  return { top: rows.slice(0, 12), evBefore, evAfterWin };
}
