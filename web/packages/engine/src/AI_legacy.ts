// AI 对手：传统围棋风格（参考 OGS 默认机器人 GNU Go 的架构）
//   - OGS 免费/访客账号的默认 AI 是 GNU Go：采用「龙（dragon）死活分析 + 影响力评估 +
//     战术读棋 + 价值驱动选点」，每一步都有明确意图，下出像人一样的传统棋形。
//   - KataGo（深度网络 + MCTS/PUCT）是 OGS 的强 AI，浏览器端无法运行神经网络；
//     故本引擎走 GNU Go 的「启发式 + 价值驱动 + 有限读棋」路线。
//
// GNU Go 决策管线（本文件忠实移植其骨架）：
//   1) 龙分析（dragon analysis）：把棋子组群连同其眼位/连接势分类为
//      危急(critical) / 弱(weak) / 活(alive) / 死(dead)。
//      这是 GNU Go 一切决策的基础——攻该攻的、守该守的，死棋不救、活棋不慌。
//   2) 候选生成（move generation）：战术点（提/逃/连/断）+ 龙攻防点 + 影响力大场。
//   3) 价值驱动选点（move valuation）：每个候选"落子前后局面评估差"即其价值
//      （≈ 这一手值几分），选价值最高者；而非按战术类别拍脑袋给固定优先级。
//      这正是 GNU Go 与传统启发式 AI 的本质区别：没有魔法数字塔，价值由评估函数派生。
//   4) 高难度追加 1-3 层攻防读棋（浅层极小极大），模拟双方最佳应对。
//   5) 时间预算：所有搜索受 thinkTimeMs 截止时间约束，到点即返回当前最优，绝不卡死。
//
// 本游戏棋盘有边境线（row 9）：黑方领土 row 0-8，白方领土 row 10-18，row 9 为前线。
// 因此评估函数做「分区加权」：围己方半场 = 安身立命（防御价值，权重低）；
// 围边境线 = 推进跳板（权重中）；围对方半场 = 本游戏的主得分来源（权重高）。
// 但价值是「平滑的评估差」而非硬门槛，所以不会出现"开局 12 手就全线抢边境"的退化——
// 早期己方框架未成、影响力够不到边境时，边境点的评估增量自然低。
//
// 三档难度：简单 / 普通 / 困难（候选数、读棋深度与思考时间递增，噪声递减）。
// web 引擎未实现特种部队，候选生成不含特种部队部署逻辑。
//
// 设计：
//   - 纯逻辑，不依赖 DOM/节点
//   - 搜索在 BoardModel.clone() 上模拟，不触碰真实对局
//   - 时间到即返回当前最优候选

import {
  Color, opponent, BORDER_ROW,
  Zone, ownZone, enemyZone,
  isDefenseZone, isAttackZone,
  PASS_LIMIT_PER_GAME, PASS_COOLDOWN_TURNS,
} from "./Const.js";
import { BoardModel, Point } from "./BoardModel.js";
import { GoRules } from "./GoRules.js";
import { GameSession } from "./GameSession.js";
import { TerritoryDetector } from "./TerritoryDetector.js";

// ====== 难度配置 ======
export enum AIDifficulty {
  EASY = 0,
  NORMAL = 1,
  HARD = 2,
}

export const AI_DIFFICULTY_NAMES: Record<AIDifficulty, string> = {
  [AIDifficulty.EASY]: "简单",
  [AIDifficulty.NORMAL]: "普通",
  [AIDifficulty.HARD]: "困难",
};

export const AI_DIFFICULTY_DESCS: Record<AIDifficulty, string> = {
  [AIDifficulty.EASY]: "浅读棋快棋",
  [AIDifficulty.NORMAL]: "战术读棋",
  [AIDifficulty.HARD]: "深度攻防读棋",
};

export interface AIConfig {
  maxCandidates: number; // 每节点候选子数量上限
  refinePly: number;     // 攻防读棋深度（1 = 只看本手效果，2 = 看对方最佳应手，3 = 再看己方应手）
  thinkTimeMs: number;   // 搜索时间预算（到点即返回，绝不超时）
  noise: number;         // 选点随机噪声幅度（简单更大 → 偶有恶手更像新手）
  branch: number;        // 读棋时每层候选分支数
}

export function getAIConfig(d: AIDifficulty): AIConfig {
  switch (d) {
    case AIDifficulty.EASY:
      return { maxCandidates: 12, refinePly: 1, thinkTimeMs: 400, noise: 10, branch: 8 };
    case AIDifficulty.NORMAL:
      return { maxCandidates: 24, refinePly: 2, thinkTimeMs: 1200, noise: 4, branch: 5 };
    case AIDifficulty.HARD:
      return { maxCandidates: 28, refinePly: 3, thinkTimeMs: 2000, noise: 1, branch: 4 };
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
}

// MCTS 节点（UCT 搜索）：board 为「经 moveInfo 落子后」的局面，koPoint 为该局面的劫点。
interface MCTSNode {
  board: BoardModel;
  toMove: Color;
  koPoint: Point;
  parent: MCTSNode | null;
  moveInfo: { row: number; col: number; reason: string } | null;
  children: MCTSNode[];
  untried: ScoredMove[]; // 尚未展开的候选（策略 ≈ genCandidates 输出）
  visits: number;
  valueSum: number;      // 回传价值累计（root 视角，越大越好）
  value: number;         // 该节点局面的静态评估（root 视角）
  prisRoot: number;      // 至该节点已累计：被 root 方提掉的对方子数
  prisOpp: number;       // 至该节点已累计：被对方提掉的 root 方子数
}

// ====== 候选「初筛种子」（GNU Go 式：仅为把候选收窄到 top-N 供搜索评估用） ======
// 因此数值只需粗分档，不需要精密调参。
// 关键：种子只决定「哪些候选进入 top-N 评估」，最终选点由「落子前后评估差」决定。
// 故 BIG（影响力大场 / 领地要点）必须与 ATTACK/DEFEND 同量级，
// 否则大场永远被挤在 top-N 之外，AI 只会盯着弱龙打（退化行为）。
const SEED = {
  CAPTURE: 100000, // 提吃对方 1 气组群（立即生效）
  SAVE: 90000,     // 逃出己方 1 气组群（值得救的）
  ATTACK: 24000,   // 攻击弱敌龙（仅得分区/防守区的龙，见候选生成注释）
  DEFEND: 21000,   // 防守弱己龙（仅框架/打入军）
  CONNECT: 11000,  // 连络（≥2 己方组群相邻的空点；比打吃/逃气略高，但低于大场/侵消）
  CUT: 12000,      // 分断（≥2 对方组群相邻的空点，需依托；破坏对方结构价值高）
  ATARI2: 10000,   // 打吃 2 气组群（仅可围死/侵入己方半场才生成）
  ESCAPE2: 9500,   // 逃气 2 气组群（仅值得救的才生成）
  BIG: 19000,      // 影响力大场（领地/边境要点，与攻防同量级才不会被挤出 top-N）
  INVADE: 20000,   // 侵消/打入（本游戏主得分来源，近前线大空边界点）
  RANDOM: 300,     // 随机兜底（几乎不会被选中，仅保证候选非空）
} as const;

// ====== 分区纪律（本游戏特有的边境线规则） ======
const OPENING_STONES = 20;           // 前 20 子视为布局（含双方）：只走布局要点 + 必要战术，不打无谓攻击
const ENEMY_ZONE_MIN_STONES = 20;    // 全局满 20 子后（双方布局基本完成）才准备跨半场——先立框架再进攻
const FRAMEWORK_SOLID = 10;          // 己方半场己方子 ≥ 10 → 框架初具，才可发动攻击/侵消（避免开局即乱战）
const FRONT_DEPTH = 4;               // 跨半场深入上限（距边境线 ≤4 行，依托前线）
const REDUCTION_MIN_REGION = 14;     // 侵消目标区域最小空点数
const INVADE_SUPPORT_DIST = 2;       // 侵入点需有己方棋子/边境依托（切比雪夫距离）

// ====== 终局虚手门槛 ======
// 关键：阈值必须能让对局"自然收束"。原主动虚手阈值 0.5 分太低——互杀局面中
// 永远有"提 1 子 = 2 分"的着法，bestGain 恒 > 0.5，双方永不虚手 → 对局拖成
// 无限拉锯（实测 228 手不终局、比分 200+）。阈值提高到"单子提/填子不值得"级别：
//   主动虚手 2.5 分（单子提≈2 分不值得；双子提≈4 分仍会走）
//   跟手虚手 6.0 分（对方示意终局后，只有 ≥6 分的大棋才值得不跟）
const ENDGAME_MIN_STONES = 70;        // 全局 ≥70 子才算进入中后盘，才允许判定终局虚手
const ENDGAME_FOLLOW_THRESHOLD = 6;   // 对方已虚手 → 本手增益 <6 分就跟手虚手（对方示意终局，AI 应配合）
const ENDGAME_PASS_THRESHOLD = 2.5;   // 对方未虚手 → 本手增益 <2.5 分才主动虚手（单子提/填子不值得）

// ====== 通用工具 ======

// 组群信息（stones/libs 用棋盘索引，避免反复分配 Point 对象）
interface GroupInfo {
  stones: number[];
  color: Color;
  libs: number[];
}

// 高效组群收集：单次扫描得到所有组群（含子数、气列表）
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

// 组群稳定标识：组群内最小棋盘索引（同组群恒同）
function groupInfoKey(g: GroupInfo): number {
  let min = Infinity;
  for (const s of g.stones) {
    if (s < min) min = s;
  }
  return min;
}

function zoneOfRowLocal(row: number): Zone {
  if (row < BORDER_ROW) return Zone.BLACK;
  if (row === BORDER_ROW) return Zone.BORDER;
  return Zone.WHITE;
}

// 己方半场内己方棋子数（框架稳固度）
function countOwnHalf(board: BoardModel, color: Color): number {
  const size = board.size;
  const grid = board.grid;
  let n = 0;
  for (let r = 0; r < size; r++) {
    if (zoneOfRowLocal(r) !== ownZone(color)) continue;
    for (let c = 0; c < size; c++) if (grid[r * size + c] === color) n++;
  }
  return n;
}

// 落子后己方组群的气数（用于判定是否自填气；需在 tryMove 之后调用）
function ownGroupLibs(b: BoardModel, row: number, col: number): number {
  const g = b.groupAt(row, col);
  if (g.stones.length === 0) return 0;
  return b.liberties(g.stones).length;
}

// 计算在 (r,c) 落 color 后（视同已落子、不提子）新组群的气数。
// 提子只增不减，故返回 0 → 自杀、1 → 自填气、>=2 → 安全（保守下界）。
// 用于候选生成阶段快速剔除自填气恶手，不必克隆棋盘做完整 tryMove。
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

// ====== 龙（Dragon）状态判定（GNU Go 死活分析的简化版） ======

// GNU Go "alive" 判定简化版：组群是否安全存活。
//   有 ≥2 眼位候选 → 活（有眼不怕围）；
//   能连回其它己方棋 → 活（有后援）；
//   组群 ≥2 子且气数 ≥3 → 有内部结构，大概率可活；
//   否则 → 孤立弱子（不算活子分，撒子乱下无收益）。
// 关键：单颗散子在对方半场即使气多也不算活——这正是 GNU Go 只让
//       "alive stones" 产生分数/影响力的原则，避免 AI 往对方半场乱撒子。
function groupIsAliveSafe(board: BoardModel, g: GroupInfo): boolean {
  if (groupEyeCandidates(board, g, g.color).length >= 2) return true;
  if (groupCanConnect(board, g, g.color)) return true;
  if (g.stones.length >= 2 && g.libs.length >= 3) return true;
  return false;
}

// 组群的眼位候选：气点邻接 ≥2 颗己方子（接近成眼，破眼/护眼价值高）
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

// 组群能否连回另一颗己方子（气点邻接其它己方组群）
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

// 切比雪夫距离 ≤ dist 内是否有己方棋（依托判定：能否连回/有靠山）
function hasOwnSupport(board: BoardModel, r: number, c: number, color: Color, dist: number): boolean {
  const size = board.size;
  const grid = board.grid;
  const r0 = Math.max(0, r - dist);
  const r1 = Math.min(size - 1, r + dist);
  const c0 = Math.max(0, c - dist);
  const c1 = Math.min(size - 1, c + dist);
  for (let sr = r0; sr <= r1; sr++) {
    for (let sc = c0; sc <= c1; sc++) {
      if (grid[sr * size + sc] === color) return true;
    }
  }
  return false;
}

// 组群是否「被围死」（无自由逃生路线）：
//   在任一气点落子后新组群气数 > 当前气数 = 该气是逃生路线；
//   若所有逃生路线都被墙/对方棋/边角堵死（受限 ≥2）→ 组群被围死，对手可逐个填气围杀。
// 用于「追打是否值得」：能围死才追，可逃则 tenuki（不浪费手数追无益目标）。
function groupIsConfined(board: BoardModel, g: GroupInfo): boolean {
  const size = board.size;
  const grid = board.grid;
  const opp = opponent(g.color);
  for (const lib of g.libs) {
    const r = Math.floor(lib / size);
    const c = lib % size;
    const newLibs = libsAfterVirtualPlace(board, r, c, g.color);
    if (newLibs <= g.libs.length) continue; // 填上不增气 → 死气，不算逃生路线
    // 扩气了 → 逃生路线；若该气点被墙/对方棋夹住（受限 ≥2），逃生仍被堵死
    let blocked = 0;
    if (r <= 0 || r >= size - 1) blocked++;
    if (c <= 0 || c >= size - 1) blocked++;
    for (const [nr, nc] of board.neighbors(r, c)) {
      const v = grid[nr * size + nc];
      if (v === opp) blocked++;
    }
    if (blocked < 2) return false; // 有自由逃生路线 → 可逃，未被围死
  }
  return true;
}

// 组群是否「死棋」（GNU Go 式：死棋不救，不浪费手数）：
//   气 ≤3、无眼位、连不回其它己方棋、且被围死 → 死棋。
function groupIsDead(board: BoardModel, g: GroupInfo, color: Color): boolean {
  if (g.libs.length >= 4) return false;
  const connect = groupCanConnect(board, g, color);
  if (g.libs.length <= 2 && !connect) return true;
  return groupIsConfined(board, g) && !connect;
}

// 龙（GNU Go dragon）：组群 + 生死状态 + 眼位 + 连接势
interface Dragon {
  g: GroupInfo;
  status: "critical" | "weak" | "alive" | "dead";
  eyeCandidates: number[];
  value: number; // 大致价值（子数）
}

// 龙状态判定：
//   双真眼候选 → 活（不攻）；1 气 → 危急（立即处理）；
//   死棋判定 → 死（不救）；其余 → 弱（可攻可守，是攻防重点）。
function analyzeDragons(board: BoardModel, color: Color): Dragon[] {
  const groups = collectGroups(board);
  const out: Dragon[] = [];
  for (const g of groups) {
    if (g.color !== color || g.libs.length === 0) continue;
    const eyeCandidates = groupEyeCandidates(board, g, color);
    let status: Dragon["status"];
    if (eyeCandidates.length >= 2) status = "alive";
    else if (g.libs.length === 1) status = "critical";
    else if (groupIsDead(board, g, color)) status = "dead";
    else status = "weak";
    out.push({ g, status, eyeCandidates, value: g.stones.length });
  }
  return out;
}

// 组群是否「按活子计分」（GNU Go alive 原则：只有能活的棋子才算活子分）：
//   死棋（groupIsDead）→ 不计；有 ≥2 眼位候选 → 活；能连回己方棋 → 活；
//   组群 ≥2 子、气 ≥4、且贴近前线（距边境 ≤2 行，有前线依托）→ 活；其余 → 不计。
// 关键：孤立散子（无眼、无连接、单子）不记分；对方半场深处的「2 子组群」即便气多，
//       无眼、连不回己方、又不贴近前线（可依托推进的跳板）→ 同样不记分
//       → 杜绝 AI 往对方半场深处撒子凑组群（"撒子乱下"的根源）。
function groupScoredAsAlive(board: BoardModel, g: GroupInfo, color: Color): boolean {
  if (groupIsDead(board, g, color)) return false;
  if (groupEyeCandidates(board, g, color).length >= 2) return true;
  if (groupCanConnect(board, g, color)) return true;
  if (!(g.stones.length >= 2 && g.libs.length >= 4)) return false;
  // 贴近前线（距边境 ≤2 行）→ 有前线依托，大概率可活；深入对方半场 → 不记分
  const size = board.size;
  for (const s of g.stones) {
    const r = Math.floor(s / size);
    if (Math.abs(r - BORDER_ROW) <= 2) return true;
  }
  return false;
}

// ====== 影响力函数（GNU Go influence.c 的简化版） ======
// 每颗棋子向四邻辐射影响力：距离 0/1/2/3 分别衰减为 3/1.6/0.8/0.3，
// 穿过空点与己方棋子，被对方棋子阻挡；单点影响力上限（防大龙远距离过冲）。
const INF_WEIGHTS = [3, 1.6, 0.8, 0.3];
const INF_RADIUS = INF_WEIGHTS.length - 1;
const INF_SATURATE = 5;

function computeInfluencePair(board: BoardModel, color: Color): { my: Float32Array; opp: Float32Array } {
  const size = board.size;
  const grid = board.grid;
  const my = new Float32Array(size * size);
  const opp = new Float32Array(size * size);
  const doColor = (srcColor: Color, out: Float32Array): void => {
    const oppC = opponent(srcColor);
    const dist = new Int16Array(size * size).fill(999);
    const queue: number[] = [];
    for (let i = 0; i < grid.length; i++) {
      if (grid[i] === srcColor) { queue.push(i); dist[i] = 0; }
    }
    while (queue.length > 0) {
      const idx = queue.pop()!;
      const d = dist[idx];
      out[idx] = Math.min(out[idx] + INF_WEIGHTS[d], INF_SATURATE);
      if (d >= INF_RADIUS) continue;
      const r = Math.floor(idx / size);
      const c = idx % size;
      if (r > 0) {
        const ni = idx - size;
        if (dist[ni] === 999 && grid[ni] !== oppC) { dist[ni] = d + 1; queue.push(ni); }
      }
      if (r < size - 1) {
        const ni = idx + size;
        if (dist[ni] === 999 && grid[ni] !== oppC) { dist[ni] = d + 1; queue.push(ni); }
      }
      if (c > 0) {
        const ni = idx - 1;
        if (dist[ni] === 999 && grid[ni] !== oppC) { dist[ni] = d + 1; queue.push(ni); }
      }
      if (c < size - 1) {
        const ni = idx + 1;
        if (dist[ni] === 999 && grid[ni] !== oppC) { dist[ni] = d + 1; queue.push(ni); }
      }
    }
  };
  doColor(color, my);
  doColor(opponent(color), opp);
  return { my, opp };
}

// 领地估算：复用游戏真实围空算法（TerritoryDetector.enclosures）。
//   GNU Go 式「墙成圈才算地」：只有己方连通墙围住的空点才算己方领地，
//   散落在空处的单子不圈地（这正是传统围棋的领地观，也是本引擎避免"撒子乱下"的关键）。
//   本游戏围空分只在「对方领土/边境」有效 → 按 isAttackZone 过滤，己方半场围空得 0 分。
//   返回「己方围空分 - 对方围空分」（每点 2 分，与游戏 occupationTerritory 口径一致）。
function territoryDifference(board: BoardModel, rootColor: Color): number {
  const encs = TerritoryDetector.enclosures(board);
  let myScore = 0;
  let oppScore = 0;
  for (const e of encs) {
    let s = 0;
    for (const p of e.points) {
      if (isAttackZone(p.row, e.color)) s += 2;
    }
    if (e.color === rootColor) myScore += s;
    else oppScore += s;
  }
  return myScore - oppScore;
}

// 死活感知局面评估（从 rootColor 视角，数值越大越好）。
// 注意：会就地修改 board（移除死子），调用方必须传入可丢弃的克隆局面。
//   1) 死子去除（迭代移除 ≤1 气组群，模拟提子连锁）
//   2) 真实围空（游戏围墙算法）：己方围空点（对方半场/边境）+2
//   3) 活子分：存活组群落在对方半场/边境的棋子 +1（对应游戏 occupationLive）
//   4) 提子/死子（每子约 2 分）
//   5) 弱子威胁度 + 连接度（小权重，避免"为打架而打架"）
// 关键：领地只看「连通墙围成的圈」，散子不圈地、死子直接扣分 →
//       撒子乱下不再有收益，AI 自然转向"连墙→围空→推进"的传统下法。
function evaluatePosition(
  board: BoardModel,
  rootColor: Color,
  komi: number,
  prisRoot: number,
  prisOpp: number
): number {
  const opp = opponent(rootColor);
  const size = board.size;
  const grid = board.grid;

  // 1) 死子去除（迭代移除 ≤1 气组群，模拟提子后的连锁；上限 5 轮防重）
  let deadRoot = 0;
  let deadOpp = 0;
  for (let iter = 0; iter < 5; iter++) {
    const groups = collectGroups(board);
    let removed = false;
    for (const g of groups) {
      if (g.libs.length > 1) continue;
      if (g.color === rootColor) deadRoot += g.stones.length;
      else if (g.color === opp) deadOpp += g.stones.length;
      else continue;
      for (const s of g.stones) grid[s] = Color.EMPTY;
      removed = true;
    }
    if (!removed) break;
  }

  // 2) 真实围空（游戏围墙算法）：己方围空点（对方半场/边境）+2
  const terr = territoryDifference(board, rootColor);

  // 3) 活子分：仅「能活的组群」计分（GNU Go alive 原则——被围死的墙/孤立散子
  //    不产生活子分；否则 AI 会因「对方半场撒一颗子 = +1 分」而乱下）
  let liveMy = 0;
  let liveOpp = 0;
  const groups = collectGroups(board);
  for (const g of groups) {
    if (g.libs.length === 0) continue;
    if (!groupScoredAsAlive(board, g, g.color)) continue;
    for (const s of g.stones) {
      if (isAttackZone(Math.floor(s / size), g.color)) {
        if (g.color === rootColor) liveMy++;
        else liveOpp++;
      }
    }
  }

  // 4) 提子/死子（每子约 2 分）+ 领地 + 活子
  let diff = terr + (liveMy - liveOpp) + (prisRoot - prisOpp) * 2 + (deadOpp - deadRoot) * 2;

  // 5) 弱子威胁度 + 连接度（小权重，避免"为打架而打架"）
  //    注意：不给「己方在对方地盘/边境的弱子」额外惩罚——本游戏主得分区在对方半场，
  //    打入初期必成弱子，重罚会导致 AI 缩在己方半场不敢推进（曾因此回归）。
  //    只奖励「对方侵入我方领土的弱子」（己方地盘优先围剿）。
  let weakRoot = 0;
  let weakOpp = 0;
  let weakOppOwn = 0;
  let rootGroups = 0;
  let oppGroups = 0;
  for (const g of groups) {
    if (g.libs.length === 0) continue;
    const w = g.stones.length;
    if (g.color === rootColor) {
      rootGroups++;
      weakRoot += g.libs.length === 2 ? w * 2 : g.libs.length === 3 ? w : 0;
    } else {
      oppGroups++;
      const wv = g.libs.length === 2 ? w * 2 : g.libs.length === 3 ? w : 0;
      weakOpp += wv;
      if (wv > 0 && groupHasZoneRow(board, g, (r) => isOwnGround(r, rootColor))) weakOppOwn += wv;
    }
  }
  diff += (weakOpp - weakRoot) * 0.4;       // 对方弱子多 = 己方有攻击目标；己方弱子多 = 危险
  diff += weakOppOwn * 0.8;                 // 对方侵入我方领土的弱子：攻击价值（己方地盘围剿）
  diff += (oppGroups - rootGroups) * 1.5;   // 对方被分断 = 己方好；己方连成片 = 己方好

  // 6) 围空潜力（低成本领地引导）：对方半场/边境空点邻接己方棋 → 潜在围空。
  //    真围空（territoryDifference）要求"围成圈"才 +2/点，未成形的围墙每手都是 0 分，
  //    导致 AI 看不到围空进展、只会单点侵消而从不收拢成空。这里给"贴墙扩展"少量
  //    增量分，引导 AI 持续围对方半场（仅统计 isAttackZone 区，己方半场填子不得分）。
  let pot = 0;
  for (let i = 0; i < grid.length; i++) {
    if (grid[i] !== Color.EMPTY) continue;
    const pr = Math.floor(i / size);
    if (!isAttackZone(pr, rootColor)) continue;
    let myN = 0;
    let oppN = 0;
    if (pr > 0) { const v = grid[i - size]; if (v === rootColor) myN++; else if (v === opp) oppN++; }
    if (pr < size - 1) { const v = grid[i + size]; if (v === rootColor) myN++; else if (v === opp) oppN++; }
    const pc = i % size;
    if (pc > 0) { const v = grid[i - 1]; if (v === rootColor) myN++; else if (v === opp) oppN++; }
    if (pc < size - 1) { const v = grid[i + 1]; if (v === rootColor) myN++; else if (v === opp) oppN++; }
    if (myN > 0 && oppN === 0) pot += 1;       // 纯己方封锁侧翼：潜力最高
    else if (myN > 0) pot += 0.5;               // 有对方干扰：仍可争夺
    else if (oppN > 0) pot -= 0.5;              // 对方封锁侧翼：对方潜力
  }
  // 权重 1.8：贴近真实围空收益(+2/点)。原 0.4 太弱，AI 读棋时感受不到
  // "连墙→最终围成圈"的梯度，导致只侵消散点、从不收拢成空（实测 160 手围空仅 +4）。
  diff += pot * 1.8;

  if (rootColor === Color.WHITE) diff += komi;
  return diff;
}

// ====== 搜索引擎（GNU Go 式「价值驱动选点 + 浅层攻防读棋」+ 时间预算） ======

interface MoveCtx {
  invasion: Point[] | null; // 预计算的近前线侵消/打入候选（仅根节点）
  phase: "opening" | "midgame";
  ready: boolean;           // 己方框架稳固（己方半场 ≥ FRAMEWORK_SOLID）→ 可发动攻击/侵消
  quick?: boolean;          // 深层搜索只做战术候选（跳过影响力大场，提速）
}

export class SearchEngine {
  // 战术快通道：对方组群在叫吃 → 立即提；己方组群在叫吃 → 立即逃（死棋不救）。
  // 保证 AI 具备基本战斗力（不无视叫吃），且避免读棋成本。
  private _tacticalFastPath(session: GameSession, aiColor: Color): AIMove | null {
    const groups = collectGroups(session.board);
    const opp = opponent(aiColor);
    let cap: { idx: number; size: number } | null = null;
    let esc: { idx: number; size: number; group: GroupInfo } | null = null;
    for (const g of groups) {
      if (g.color === opp && g.libs.length === 1) {
        if (cap === null || g.stones.length > cap.size) cap = { idx: g.libs[0], size: g.stones.length };
      } else if (g.color === aiColor && g.libs.length === 1) {
        if (esc === null || g.stones.length > esc.size) esc = { idx: g.libs[0], size: g.stones.length, group: g };
      }
    }
    const size = session.board.size;
    const ko = session.koPoint;

    // 提子优先（同大小或大于逃出目标时）
    if (cap !== null && (esc === null || cap.size >= esc.size)) {
      const row = Math.floor(cap.idx / size);
      const col = cap.idx % size;
      const sim = session.board.clone();
      const res = GoRules.tryMove(sim, row, col, aiColor, ko);
      if (res.legal && res.captured.length > 0) {
        return { type: "move", row, col, reason: `提吃${res.captured.length}子` };
      }
    }
    // 逃出（需确认逃出后不自填气、且确能增气；死棋不救 → 无快通道，交给主流程判断弃子）
    if (esc !== null && !groupIsDead(session.board, esc.group, aiColor)) {
      const row = Math.floor(esc.idx / size);
      const col = esc.idx % size;
      const sim = session.board.clone();
      const res = GoRules.tryMove(sim, row, col, aiColor, ko);
      if (res.legal && (res.captured.length > 0 || ownGroupLibs(sim, row, col) >= 2)) {
        return { type: "move", row, col, reason: "逃出" };
      }
    }
    return null;
  }

  // 落子后局面评估（从 aiColor 视角），作为「价值驱动」的基准
  private _evalAfter(board: BoardModel, aiColor: Color, komi: number, prisRoot: number, prisOpp: number): number {
    return evaluatePosition(board, aiColor, komi, prisRoot, prisOpp);
  }

  findBestMove(session: GameSession, aiColor: Color, config: AIConfig): AIMove {
    // 兵力用尽 → 虚手（无法再落子，避免客户端 playMove 报"兵力已用尽"）
    if (session.piecesLeft(aiColor) <= 0) {
      return { type: "pass", row: -1, col: -1, reason: "兵力用尽" };
    }

    const fast = this._tacticalFastPath(session, aiColor);
    if (fast !== null) return fast;

    const board = session.board;
    const placed = board.countColor(Color.BLACK) + board.countColor(Color.WHITE);
    const deadline = Date.now() + config.thinkTimeMs;
    const ctx: MoveCtx = {
      phase: placed < OPENING_STONES ? "opening" : "midgame",
      invasion: null,
      ready: countOwnHalf(board, aiColor) >= FRAMEWORK_SOLID,
    };

    // 布局：先看是否有敌子侵入己方半场需就地围堵（GNU Go 模式库本质就是"对侵入
    // 己方领地的敌子必有应对"），无威胁才走布局库占角/拆边。
    // 1 气组群已被 _tacticalFastPath 处理，这里补 2-3 气侵入者的压制。
    if (ctx.phase === "opening") {
      const threat = this._openingThreatResponse(board, aiColor);
      if (threat !== null) return threat;
      const mv = this._openingMove(board, aiColor, config.noise);
      if (mv !== null) return mv;
    }

    // 跨半场侵消/打入是本游戏的主得分来源（围对方半场的空才得分）：
    // 布局结束后（全局 ≥12 子）、己方框架初具（≥8 子）即开始依托前线推进，
    // 且只打近前线点（_findInvasionPoints 内部已限制深度 ≤ FRONT_DEPTH 并要求有依托）。
    if (ctx.phase === "midgame" && placed >= ENEMY_ZONE_MIN_STONES && countOwnHalf(board, aiColor) >= FRAMEWORK_SOLID) {
      ctx.invasion = _findInvasionPoints(board, aiColor);
    }

    // 主搜索：NORMAL/HARD 用 MCTS（UCT 深度读棋，参考 OGS 强 AI KataGo 的树搜索骨架），
    // EASY 用简单 1 层价值选点（浅读棋，更快更弱）。二者共用同一评估函数与候选生成。
    let best: ScoredMove | null = null;
    let bestGain = -Infinity; // 最佳候选的「纯增益」（不含噪声，用于终局虚手判定）
    const base = this._evalAfter(board.clone(), aiColor, session.komi, 0, 0);

    if (config.refinePly >= 2) {
      // MCTS：UCT 沿有希望的行棋自适应深入（主变可读到 8-15 层），
      // 能看清连串提子/死活/官子，同时保留全部启发式知识（候选 + 评估）。
      const m = this._mctsSearch(board, aiColor, session.koPoint, config, ctx, deadline, session.komi);
      if (m !== null) {
        best = m;
        bestGain = m.score - base;
      }
    } else {
      // EASY：1 层价值选点（保留原行为，更快更弱）
      let bestVal = -Infinity;
      for (const c of genCandidates(board, aiColor, session.koPoint, config.maxCandidates, ctx)) {
        if (Date.now() > deadline) break;
        const sim = board.clone();
        const res = GoRules.tryMove(sim, c.row, c.col, aiColor, session.koPoint);
        if (!res.legal) continue;
        const v = this._evalAfter(sim, aiColor, session.komi, res.captured.length, 0);
        const gain = v - base;
        if (gain > bestGain) bestGain = gain;
        const noisy = gain + (Math.random() - 0.5) * config.noise;
        if (noisy > bestVal) { bestVal = noisy; best = c; }
      }
    }

    // 终局虚手（GNU Go 式：无棋可下就虚手，双方虚手即终局）：
    //   仅在中后盘（全局 ≥ ENDGAME_MIN_STONES）才判定，避免早期评估增益本就趋近 0
    //   导致 AI 提前虚手结束对局。
    //   对方已虚手（consecutivePasses ≥ 1）→ 本手无实质增益（<2 分）就跟手虚手；
    //   对方未虚手 → 本手近乎零价值（<0.5 分）才主动虚手。
    //   若虚手不可用（次数用尽/冷却中）→ 不虚手，继续落增益最高的候选（保持行棋合法）。
    const passCount = session.passCounts.get(aiColor) ?? 0;
    const passCooldown = session.passCooldown.get(aiColor) ?? PASS_COOLDOWN_TURNS;
    const passAvailable = passCount < PASS_LIMIT_PER_GAME && passCooldown >= PASS_COOLDOWN_TURNS;
    // 兵力耗尽保护：己方剩余兵力很少时，若本手无大棋（增益 <10）则主动虚手收束，
    // 避免双方硬拖到兵力用尽后「兵力已用尽 + 虚手次数用尽」双重无子可下的非法边界。
    // 对方已虚手时更积极（≤5 子即跟手终局）。
    const piecesLeft = session.piecesLeft(aiColor);
    if (
      passAvailable &&
      piecesLeft <= (session.consecutivePasses >= 1 ? 5 : 2) &&
      best !== null &&
      bestGain < 10
    ) {
      return { type: "pass", row: -1, col: -1, reason: "兵力将尽，虚手终局" };
    }
    if (
      passAvailable &&
      best !== null &&
      placed >= ENDGAME_MIN_STONES &&
      bestGain < (session.consecutivePasses >= 1 ? ENDGAME_FOLLOW_THRESHOLD : ENDGAME_PASS_THRESHOLD)
    ) {
      return { type: "pass", row: -1, col: -1, reason: "局面已定型，终局虚手" };
    }

    if (best === null) {
      // 读棋超时未评估完任何候选 → 取第一个合法候选（保证有棋可下）
      const cands = genCandidates(board, aiColor, session.koPoint, config.maxCandidates, ctx);
      return this._pickFirstLegal(board, cands, aiColor, session.koPoint);
    }
    return { type: "move", row: best.row, col: best.col, reason: best.reason };
  }

  // MCTS/UCT 深度读棋（KataGo / AlphaZero 树搜索骨架；叶子用启发式评估函数而非随机模拟）。
  //   - UCT 沿「高价值 + 高探索」的子节点优先深入 → 主变能自适应读到 10+ 层，
  //     看清连串提子/死活/官子；不会像固定深度极小极大那样浅尝辄止。
  //   - 叶子值 = 现有 evaluatePosition（围空/死活/连接度）→ 稳定且保留全部传统围棋知识，
  //     规避随机模拟导致的噪声与"乱下"（此前的教训）。
  //   - 时间预算：受 deadline 严格约束，到点即返回访问最多的子节点（稳健主变）。
  private _mctsSearch(
    board: BoardModel,
    aiColor: Color,
    koPoint: Point,
    config: AIConfig,
    ctx: MoveCtx,
    deadline: number,
    komi: number
  ): ScoredMove | null {
    const root: MCTSNode = {
      board: board.clone(),
      toMove: aiColor,
      koPoint,
      parent: null,
      moveInfo: null,
      children: [],
      untried: genCandidates(board, aiColor, koPoint, config.maxCandidates, ctx),
      visits: 0,
      valueSum: 0,
      value: 0,
      prisRoot: 0,
      prisOpp: 0,
    };
    if (root.untried.length === 0) return null;

    const UCT_C = 3.0;                       // 探索常数（Q 量级约 ±80 分，3 分级的探索项合适）
    const MAX_NODES = 2500;                  // 节点上限（防极端局面内存/时间失控；正常由 deadline 兜底）
    const subCtx: MoveCtx = { invasion: null, phase: "midgame", ready: true, quick: true };
    let created = 0;
    while (Date.now() < deadline && created < MAX_NODES) {
      // 1) 选择：沿 UCT 最高分子节点下行，直到可扩展节点或叶子
      let node = root;
      while (node.untried.length === 0 && node.children.length > 0) {
        node = this._selectUCTChild(node, UCT_C);
      }
      // 2) 扩展：展开一个未尝试候选；全非法则视作叶子
      if (node.untried.length > 0) {
        const child = this._expandMCTSNode(node, aiColor, config, subCtx, komi);
        if (child !== null) {
          created++;
          // 3+4) 叶子值（创建时已算好）回溯给路径上所有节点
          this._backpropMCTS(child, child.value);
          continue;
        }
        node.untried = [];
      }
      // 叶子（无可扩展候选）→ 回溯其静态评估
      this._backpropMCTS(node, node.value);
    }

    // 选访问次数最多的子节点（稳健主变；同访问数取静态评估更高者）
    let bestChild: MCTSNode | null = null;
    for (const c of root.children) {
      if (bestChild === null || c.visits > bestChild.visits) bestChild = c;
    }
    if (bestChild === null) return null;
    const mi = bestChild.moveInfo!;
    // score 语义复用 ScoredMove：这里填「落子后局面的静态评估」而非平均回传价值。
    // 终局虚手判定用 bestGain = score - base（落子前后评估差）——平均回传价值含后续
    // 博弈的虚高（提子/围空被算入），会让 AI 高估增益、永不虚手（对局拖到兵力耗尽）。
    // 静态评估差 = 本手即时得分变化，更贴近「这一手到底值几分」。
    return { row: mi.row, col: mi.col, score: bestChild.value, reason: mi.reason };
  }

  // UCT 选择：Q(平均回传价值) + C·√(ln N_parent / (1+N_child))；未访问子节点用静态评估起步
  private _selectUCTChild(node: MCTSNode, C: number): MCTSNode {
    const logN = Math.log(node.visits + 1);
    let best: MCTSNode | null = null;
    let bestVal = -Infinity;
    for (const c of node.children) {
      const q = c.visits > 0 ? c.valueSum / c.visits : c.value;
      const uct = q + C * Math.sqrt(logN / (1 + c.visits));
      if (uct > bestVal) { bestVal = uct; best = c; }
    }
    return best!; // 调用方保证 children 非空
  }

  // 扩展：依次取未尝试候选试落子；非法则试下一个；全部非法返回 null。
  // 子节点候选：更小分支(config.branch) + quick（只做战术候选）→ 深层读棋快而准。
  private _expandMCTSNode(
    parent: MCTSNode,
    aiColor: Color,
    config: AIConfig,
    subCtx: MoveCtx,
    komi: number
  ): MCTSNode | null {
    while (parent.untried.length > 0) {
      const cand = parent.untried.shift()!;
      const sim = parent.board.clone();
      const res = GoRules.tryMove(sim, cand.row, cand.col, parent.toMove, parent.koPoint);
      if (!res.legal) continue;
      const rootMoved = parent.toMove === aiColor;
      const prisRoot = rootMoved ? parent.prisRoot + res.captured.length : parent.prisRoot;
      const prisOpp = rootMoved ? parent.prisOpp : parent.prisOpp + res.captured.length;
      const child: MCTSNode = {
        board: sim,
        toMove: opponent(parent.toMove),
        koPoint: res.koPoint,
        parent,
        moveInfo: { row: cand.row, col: cand.col, reason: cand.reason },
        children: [],
        untried: genCandidates(sim, opponent(parent.toMove), res.koPoint, config.branch, subCtx),
        visits: 0,
        valueSum: 0,
        value: this._evalAfter(sim.clone(), aiColor, komi, prisRoot, prisOpp),
        prisRoot,
        prisOpp,
      };
      parent.children.push(child);
      return child;
    }
    return null;
  }

  // 回溯：把叶子价值累加给路径上所有节点（root 视角，越大越好）
  private _backpropMCTS(node: MCTSNode, value: number): void {
    let cur: MCTSNode | null = node;
    while (cur !== null) {
      cur.visits++;
      cur.valueSum += value;
      cur = cur.parent;
    }
  }

  // 兜底：依次找第一个 tryMove 合法的候选（保证绝不返回非法落子）
  private _pickFirstLegal(board: BoardModel, cands: ScoredMove[], color: Color, ko: Point): AIMove {
    for (const c of cands) {
      const sim = board.clone();
      const res = GoRules.tryMove(sim, c.row, c.col, color, ko);
      if (res.legal) return { type: "move", row: c.row, col: c.col, reason: c.reason };
    }
    return { type: "pass", row: -1, col: -1, reason: "无合法点" };
  }

  // ====== 布局 ======

  // 开局阶段的威胁响应：己方半场（含边境）出现侵入敌子时，先就地围堵/紧气，
  // 而不是继续按布局库下。这是 GNU Go 模式库的核心行为——对侵入己方领地的
  // 敌子必有应对手，绝不会无视。1 气组群由 _tacticalFastPath 负责，这里补 2-3 气。
  private _openingThreatResponse(board: BoardModel, aiColor: Color): AIMove | null {
    const size = board.size;
    const opp = opponent(aiColor);
    const groups = collectGroups(board);
    let best: { row: number; col: number; score: number; reason: string } | null = null;
    for (const g of groups) {
      if (g.color !== opp) continue;
      if (!isInvaderInMyHalf(board, g, aiColor)) continue; // 未侵入己方半场/边境
      if (g.libs.length > 3) continue;                     // 气多暂不构成威胁，继续布局
      const threat = g.stones.length * 3 + (4 - g.libs.length) * 2; // 子多、气少 → 更急
      // 组群是否已被己方棋钉住（贴墙/贴己方龙）——贴墙的侵入者封住气口就是围堵
      let pinned = false;
      for (const s of g.stones) {
        const sr = Math.floor(s / size);
        const sc = s % size;
        for (const [nr, nc] of board.neighbors(sr, sc)) {
          if (board.getAt(nr, nc) === aiColor) { pinned = true; break; }
        }
        if (pinned) break;
      }
      for (const lib of g.libs) {
        const r = Math.floor(lib / size);
        const c = lib % size;
        let ownNbr = 0;
        for (const [nr, nc] of board.neighbors(r, c)) {
          if (board.getAt(nr, nc) === aiColor) ownNbr++;
        }
        if (ownNbr === 0 && !pinned) continue; // 既贴不到己方棋又没被钉住 → 无围堵力度
        const s = threat + ownNbr * 4 + (pinned ? 3 : 0);
        if (best === null || s > best.score) best = { row: r, col: c, score: s, reason: "围堵侵入者" };
      }
    }
    if (best === null) return null;
    const sim = board.clone();
    const res = GoRules.tryMove(sim, best.row, best.col, aiColor, { row: -1, col: -1 });
    if (!res.legal) return null;
    return { type: "move", row: best.row, col: best.col, reason: best.reason };
  }

  // 己方半场占角/拆边要点（黑 row 0-8，白 row 10-18，关于 row 9 镜像）。
  // 布局库 + 噪声 + 发展自由度：每局开局有变化，且不追着对方上一手跑。
  private _openingMove(board: BoardModel, color: Color, noise: number): AIMove | null {
    const size = board.size;
    const grid = board.grid;
    const opp = opponent(color);
    const map = new Map<number, ScoredMove>();

    const add = (idx: number, score: number, reason: string): void => {
      const ex = map.get(idx);
      if (ex === undefined || score > ex.score) {
        map.set(idx, { row: Math.floor(idx / size), col: idx % size, score, reason });
      }
    };

    // 基础占角/拆边要点（黑视角 row，白方镜像）
    // 本游戏得分只在对方半场/边境有效 → 布局偏向边境线（row 7-8）建立前线跳板，
    // 避免中腹列（col 9）散点——那是己方半场深处的无效棋（不得分，还容易引守框架连墙）。
    const base: Array<[number, number, number]> = [
      [3, 3, 120], [3, 15, 120],                               // 角部（最高优先）
      [7, 3, 114], [7, 15, 114],                               // 前线星位（推进跳板）
      [8, 3, 108], [8, 15, 108],                               // 前线贴边境（越境前哨）
      [5, 5, 106], [5, 13, 106],                               // 内角
      [8, 9, 102],                                             // 前线中腹（边境正前）
      [5, 3, 98], [5, 15, 98],                                 // 边部
      [7, 6, 94], [7, 12, 94],                                 // 前线侧翼
      [3, 6, 90], [3, 12, 90],                                 // 三线拆边
      [7, 9, 88],                                              // 前线中腹（次一档）
      [0, 3, 84], [0, 15, 84],                                 // 底线角
      [1, 3, 78], [1, 15, 78],                                 // 底线二线
      [5, 9, 72],                                              // 中腹（少量）
      [8, 6, 70], [8, 12, 70],                                 // 前线补充
      [0, 9, 64],                                              // 底线中腹（少量）
      [6, 6, 58], [6, 12, 58],                                 // 补充发展
      [2, 9, 48], [4, 9, 44],                                  // 中腹最后兜底
    ];
    for (const [r, c, baseScore] of base) {
      const rr = color === Color.BLACK ? r : 18 - r;
      const idx = rr * size + c;
      if (grid[idx] !== Color.EMPTY) continue;
      let s = baseScore;
      // 避开对方棋子（布局发展自由）；贴近己方棋子（发展连接）加分
      let nearOpp = 0;
      let nearOwn = 0;
      for (const [nr, nc] of board.neighbors(rr, c)) {
        const v = grid[nr * size + nc];
        if (v === opp) nearOpp++;
        else if (v === color) nearOwn++;
      }
      if (nearOpp > 0) s -= 70;
      s += nearOwn * 12;
      add(idx, s, "开局占角/拆边");
    }

    // 兜底：己方半场/前线最近边境线的空点
    let fallback: ScoredMove | null = null;
    let bestD = 1e9;
    for (let r = 0; r < size; r++) {
      if (zoneOfRowLocal(r) !== ownZone(color) && r !== BORDER_ROW) continue;
      for (let c = 0; c < size; c++) {
        const idx = r * size + c;
        if (grid[idx] !== Color.EMPTY) continue;
        const d = Math.abs(r - BORDER_ROW);
        if (d < bestD) {
          bestD = d;
          fallback = { row: r, col: c, score: 40, reason: "前线布防" };
        }
      }
    }

    let best: ScoredMove | null = null;
    let bestVal = -Infinity;
    for (const m of map.values()) {
      const v = m.score + (Math.random() - 0.5) * noise * 6;
      if (v > bestVal) { bestVal = v; best = m; }
    }
    if (best === null && fallback !== null) {
      best = fallback;
    }
    if (best === null) return null;
    return { type: "move", row: best.row, col: best.col, reason: best.reason };
  }
}

// ====== 近前线侵消 / 打入 ======
// 预计算对方半场大的「开放空区域」中距边境线 ≤ FRONT_DEPTH 行、有己方依托的边界点。
// 只打近前线点：可依托前线（row 9）的己方势力推进，绝不孤军深入对方腹地。
// 关键：侵入点不要求"贴住对方棋子"——布局后对方半场多半是空（对方子在自己半场），
// 若强制贴敌则永远找不到侵入点，AI 只能在己方半场/边境线徘徊（本游戏主得分 = 围对方半场，
// 必须主动占空，这正是传统围棋的"大场/打入"）。
function _findInvasionPoints(board: BoardModel, color: Color): Point[] {
  const opp = opponent(color);
  const oppZone = enemyZone(color);
  const size = board.size;
  const grid = board.grid;
  const out: Point[] = [];
  const seen = new Uint8Array(size * size);

  for (let r = 0; r < size; r++) {
    if (zoneOfRowLocal(r) !== oppZone) continue;
    for (let c = 0; c < size; c++) {
      const idx = r * size + c;
      if (grid[idx] !== Color.EMPTY || seen[idx]) continue;
      // flood fill 空区域（连通空点，起点在对方半场）
      const stack = [idx];
      seen[idx] = 1;
      const region: number[] = [];
      let wall = false; // 是否有对方棋子邻接（未围死的开放区域才有价值）
      while (stack.length > 0) {
        const i = stack.pop()!;
        region.push(i);
        const rr = Math.floor(i / size);
        const cc = i % size;
        if (rr > 0) {
          const v = grid[i - size];
          if (v === Color.EMPTY) { if (!seen[i - size]) { seen[i - size] = 1; stack.push(i - size); } }
          else if (v === opp) wall = true;
        }
        if (rr < size - 1) {
          const v = grid[i + size];
          if (v === Color.EMPTY) { if (!seen[i + size]) { seen[i + size] = 1; stack.push(i + size); } }
          else if (v === opp) wall = true;
        }
        if (cc > 0) {
          const v = grid[i - 1];
          if (v === Color.EMPTY) { if (!seen[i - 1]) { seen[i - 1] = 1; stack.push(i - 1); } }
          else if (v === opp) wall = true;
        }
        if (cc < size - 1) {
          const v = grid[i + 1];
          if (v === Color.EMPTY) { if (!seen[i + 1]) { seen[i + 1] = 1; stack.push(i + 1); } }
          else if (v === opp) wall = true;
        }
      }
      if (region.length < REDUCTION_MIN_REGION) continue;
      // 仅取区域内距边境线 ≤ FRONT_DEPTH 行、有己方依托的打入点。
      // 依托 = 切比雪夫距离 ≤ INVADE_SUPPORT_DIST 内有己方棋子，或边境线同列 ±3 格内有己方棋。
      // 这样"打进去"总有退路/靠山，绝不孤军深入（GNU Go 侵入也要有支援才下）。
      for (const i of region) {
        const rr = Math.floor(i / size);
        const cc = i % size;
        if (Math.abs(rr - BORDER_ROW) > FRONT_DEPTH) continue;
        let support = false;
        const r0 = Math.max(0, rr - INVADE_SUPPORT_DIST);
        const r1 = Math.min(size - 1, rr + INVADE_SUPPORT_DIST);
        const c0 = Math.max(0, cc - INVADE_SUPPORT_DIST);
        const c1 = Math.min(size - 1, cc + INVADE_SUPPORT_DIST);
        for (let sr = r0; sr <= r1 && !support; sr++) {
          for (let sc = c0; sc <= c1; sc++) {
            if (grid[sr * size + sc] === color) { support = true; break; }
          }
        }
        // 边境线依托：同列 ±3 格内有己方边境棋（从己方前线"搭桥"打过去）
        if (!support) {
          for (let dc = Math.max(0, cc - 3); dc <= Math.min(size - 1, cc + 3) && !support; dc++) {
            if (grid[BORDER_ROW * size + dc] === color) support = true;
          }
        }
        if (!support) continue;
        out.push({ row: rr, col: cc });
      }
    }
  }
  return out;
}

// ====== 候选生成 ======

// 组群行判定工具：某行是否落在 defender 的「防御区」（己方领土/边境）或「攻击区」（对方领土/边境）。
// 用于区分「打吃侵入者（防御得分）」与「普通打吃（无谓追打）」。
function groupHasZoneRow(board: BoardModel, g: GroupInfo, test: (r: number) => boolean): boolean {
  const size = board.size;
  for (const s of g.stones) {
    if (test(Math.floor(s / size))) return true;
  }
  return false;
}

// 对方组群是否侵入我方领土（边境线按敌方地盘看——见 isEnemyGround）
function isInvaderInMyHalf(board: BoardModel, g: GroupInfo, defender: Color): boolean {
  return groupHasZoneRow(board, g, (r) => isOwnGround(r, defender));
}

// 己方组群是否含对方半场/边境的得分棋（救它保住活子分，进攻价值高）
function isScorerInOppHalf(board: BoardModel, g: GroupInfo, owner: Color): boolean {
  return groupHasZoneRow(board, g, (r) => isAttackZone(r, owner));
}

// AI 策略视野：把边境线并入「对方地盘」。
// 本游戏得分只在对方半场/边境有效，边境线是必争前线——AI 眼中的"敌方地盘"
// = 边境线 ∪ 对方半场（己方棋子一上边境即处于暴露状态，须优先保活）。
// 与计分用 isDefenseZone（己方领土∪边境）口径不同：这是决策视野，非计分规则。
function isEnemyGround(row: number, color: Color): boolean {
  return row === BORDER_ROW || zoneOfRowLocal(row) === enemyZone(color);
}

// 己方地盘（决策视野）：仅己方领土，不含边境线。
function isOwnGround(row: number, color: Color): boolean {
  return zoneOfRowLocal(row) === ownZone(color) && row !== BORDER_ROW;
}

// 高威胁棋块威胁度：气越少、子越多、无眼无后援 → 威胁越高。
// 用于候选种子加成与评估惩罚，让 AI 优先处理高危棋块（先救己、先杀敌）。
function groupThreatLevel(board: BoardModel, g: GroupInfo, color: Color): number {
  if (g.libs.length === 0) return 0;
  let t = 0;
  if (g.libs.length === 1) t += 3;
  else if (g.libs.length === 2) t += 2;
  else if (g.libs.length === 3) t += 1;
  if (g.stones.length >= 3) t += 1; // 大棋块价值高
  if (groupEyeCandidates(board, g, color).length === 0 && !groupCanConnect(board, g, color)) t += 2; // 无眼无后援
  return t;
}

// 候选生成（GNU Go 式：战术点 + 龙攻防点 + 影响力大场 + 侵消通道 + 随机兜底）。
// 种子仅用于把候选收窄到 top-N 供搜索评估，最终选点由「落子前后评估差」决定。
// 所有非战术点一律规避自填气（<2 气剔除），并施加「分区纪律 + 被围死点惩罚」。
function genCandidates(
  board: BoardModel,
  toMove: Color,
  koPoint: Point,
  maxN: number,
  ctx: MoveCtx
): ScoredMove[] {
  const groups = collectGroups(board);
  const opp = opponent(toMove);
  const size = board.size;
  const grid = board.grid;
  const map = new Map<number, ScoredMove>();
  const tactical = new Set<number>(); // 战术要点（提/逃/打吃/连断），豁免自填气过滤

  const add = (idx: number, score: number, reason: string): void => {
    if (grid[idx] !== Color.EMPTY) return;
    const ex = map.get(idx);
    if (ex === undefined || score > ex.score) {
      map.set(idx, { row: Math.floor(idx / size), col: idx % size, score, reason });
    }
  };

  // 1) 提子 / 逃出（1 气组群）：立即生效，种子最高；死棋不逃
  for (const g of groups) {
    if (g.libs.length !== 1) continue;
    const idx = g.libs[0];
    const threat = groupThreatLevel(board, g, g.color);
    tactical.add(idx);
    if (g.color === opp) add(idx, SEED.CAPTURE + g.stones.length * 2000 + threat * 800, `提吃${g.stones.length}子`);
    else if (!groupIsDead(board, g, toMove)) add(idx, SEED.SAVE + g.stones.length * 2000 + threat * 800, "逃出");
  }

  // 2) 打吃 / 逃气（2 气组群）—— 依赖龙状态，可围才打、值得才逃
  //    GNU Go 式追打纪律：能围死（groupIsConfined）才追，可逃则 tenuki。
  //    己方半场/边境的侵入者：可围杀 → 高优先追杀；可逃 → 低优先防御压制（不无限追）
  //    对方半场/边境的己方得分棋：救它 = 保活子分（进攻，高优先）；死棋不救
  for (const g of groups) {
    if (g.libs.length !== 2) continue;
    if (g.color === opp) {
      const invader = isInvaderInMyHalf(board, g, toMove);
      if (!groupIsConfined(board, g)) {
        // 可逃 → 一般不值得追打；但侵入己方领土的敌棋必须积极追杀（传统围棋：追杀逃龙），
        // 2 气高威胁追杀最优先，3 气次之
        if (!invader) continue;
        const threat = groupThreatLevel(board, g, toMove);
        const s = SEED.ATARI2 + (g.libs.length === 2 ? 12000 : 6000) + g.stones.length * 500 + threat * 800;
        for (const idx of g.libs) { tactical.add(idx); add(idx, s, "追杀侵入者"); }
        continue;
      }
      if (!ctx.ready && !invader) continue; // 框架未成：不主动打吃对方半场孤子（避免开局乱战）
      const threat = groupThreatLevel(board, g, toMove);
      // 侵入己方领土的敌棋：围杀最优先（用户策略：己方地盘先消灭入侵者）
      const s = (invader ? SEED.ATARI2 + 12000 : SEED.ATARI2) + g.stones.length * 700 + threat * 800;
      for (const idx of g.libs) { tactical.add(idx); add(idx, s, invader ? "堵杀侵入者" : "打吃"); }
    } else {
      if (groupIsDead(board, g, toMove)) continue;  // 死棋不救，不白跑
      const scorer = isScorerInOppHalf(board, g, toMove);
      const threat = groupThreatLevel(board, g, toMove);
      const s = (scorer ? SEED.ESCAPE2 + 8000 : SEED.ESCAPE2) + g.stones.length * 700 + threat * 800;
      for (const idx of g.libs) { tactical.add(idx); add(idx, s, scorer ? "保活子分" : "逃气"); }
    }
  }

  // 3) 分断 / 连络：空点邻接 ≥2 个对方组群 → 分断；≥2 个己方组群 → 连络
  //    分断需依托：己方半场/边境直接分断；对方半场深处必须有己方棋就近支撑，
  //    否则是孤军深入（会被反围）→ 跳过（杜绝无依托的敌后断点）。
  const touches = new Map<number, { own: Set<number>; opp: Set<number> }>();
  for (const g of groups) {
    const key = groupInfoKey(g);
    for (const lib of g.libs) {
      let t = touches.get(lib);
      if (t === undefined) { t = { own: new Set(), opp: new Set() }; touches.set(lib, t); }
      if (g.color === toMove) t.own.add(key);
      else t.opp.add(key);
    }
  }
  for (const [idx, t] of touches) {
    if (grid[idx] !== Color.EMPTY) continue;
    if (t.own.size >= 2) {
      const r = Math.floor(idx / size);
      // 连络分区纪律：己方半场深处的连络 = 自补（不得分、无推进），降权；
      // 边境线/对方半场连络 = 推进势力 + 生存优先（己方棋子已在敌方地盘），加分。
      let s = SEED.CONNECT + (t.own.size - 2) * 1500;
      if (isEnemyGround(r, toMove)) s += 1500;
      if (zoneOfRowLocal(r) === ownZone(toMove) && Math.abs(r - BORDER_ROW) > 3) s = Math.floor(s * 0.25);
      tactical.add(idx);
      add(idx, s, "连络");
    }
    if (t.opp.size >= 2) {
      const r = Math.floor(idx / size);
      const c = idx % size;
      if (isDefenseZone(r, toMove) || hasOwnSupport(board, r, c, toMove, 2)) {
        tactical.add(idx); add(idx, SEED.CUT + (t.opp.size - 2) * 1500, "分断");
      }
    }
  }

  // 4) 龙攻防：攻击弱敌龙（填气/破眼），防守弱己龙（扩气/连络）。
  //    GNU Go 的灵魂——但只攻「有价值的龙」：
  //      - 敌龙在其主场（对方半场/边境）→ 攻它 = 在对方领土建立势力（本游戏主得分来源）
  //      - 敌龙侵入己方半场 → 攻它 = 驱逐侵入者（防守）
  //      - 敌龙在中腹无主地带 → 不追（tenuki，避免无意义追打）
  //    防守同理：只保「框架（己方半场）」与「打入军（对方半场，保活子分）」，死棋不救。
  const myDragons = analyzeDragons(board, toMove);
  const oppDragons = analyzeDragons(board, opp);
  for (const d of oppDragons) {
    if (d.status !== "weak") continue;
    const inOppHalf = isScorerInOppHalf(board, d.g, toMove); // 敌龙在其得分区（对方半场/边境）
    const inMine = isInvaderInMyHalf(board, d.g, toMove);    // 敌龙侵入己方半场
    if (!inOppHalf && !inMine) continue;                     // 中腹孤龙 → tenuki
    if (!ctx.ready && !inMine) continue;                     // 框架未成：不主动攻打对方半场（先立后攻）
    if (inMine) {
      // 侵入我方领土的敌龙：即使未围死也积极围攻（用户策略：消灭入侵者）。
      // 气 ≤3 → 全力围剿；气 >3 → 降级为「围困」占气点（本土作战，成本低收益明确）。
    } else if (!groupIsConfined(board, d.g) && d.value < 3) continue; // 对方半场孤子围不死 → 不攻
    const threat = groupThreatLevel(board, d.g, toMove);
    // 侵入我方领土的敌龙最高优先（己方地盘先围剿）；对方地盘/边境的敌龙次之（攻敌得地）
    // 侵入者气多 → 降级为围困（基础 ATTACK），气少 → 全力围剿（ATTACK+9000）
    const baseScore = (inMine ? (d.g.libs.length <= 3 ? SEED.ATTACK + 9000 : SEED.ATTACK + 2000) : inOppHalf ? SEED.ATTACK + 5000 : SEED.ATTACK) + d.value * 200 + threat * 800;
    const tag = inMine ? (d.g.libs.length <= 3 ? "围剿侵入者" : "围困侵入者") : inOppHalf ? "攻敌龙得地" : "驱逐侵入者";
    for (const lib of d.g.libs) {
      if (grid[lib] !== Color.EMPTY) continue;
      // 攻对方半场龙需就近依托（否则孤军深入被反围）：气点旁须有己方棋，或有己方棋子
      // 在切比雪夫距离 ≤2 内作靠山。侵入己方半场的敌龙则无需依托（就在家门口）。
      if (inOppHalf && !hasOwnSupport(board, Math.floor(lib / size), lib % size, toMove, 2)) continue;
      add(lib, baseScore, tag);
    }
    for (const eye of d.eyeCandidates) {
      if (grid[eye] !== Color.EMPTY) continue;
      if (inOppHalf && !hasOwnSupport(board, Math.floor(eye / size), eye % size, toMove, 2)) continue;
      add(eye, baseScore + 500, inOppHalf ? "破眼得地" : "堵侵入眼");
    }
  }
  for (const d of myDragons) {
    if (d.status !== "weak") continue;
    const inOppHalf = isScorerInOppHalf(board, d.g, toMove); // 己龙打入对方半场 = 活子分，保它
    const inMine = isInvaderInMyHalf(board, d.g, toMove);    // 己龙在己方半场 = 框架，保它
    if (!inOppHalf && !inMine) continue;
    // 守己方半场框架：仅当附近确有对方棋子（有被围/被打的威胁）时才守；
    // 己方半场无威胁的弱龙不补（本游戏得分在对方半场，补自家空=浪费手数）。
    // 防止布局结束后 AI 疯狂在己方半场连墙填子（退化行为）。
    if (inMine && !inOppHalf) {
      const size = board.size;
      const grid = board.grid;
      let threatNear = false;
      outer: for (const s of d.g.stones) {
        const sr = Math.floor(s / size);
        const sc = s % size;
        const r0 = Math.max(0, sr - 2), r1 = Math.min(size - 1, sr + 2);
        const c0 = Math.max(0, sc - 2), c1 = Math.min(size - 1, sc + 2);
        for (let tr = r0; tr <= r1; tr++) {
          for (let tc = c0; tc <= c1; tc++) {
            if (grid[tr * size + tc] === opponent(toMove)) { threatNear = true; break outer; }
          }
        }
      }
      if (!threatNear) continue; // 无威胁 → tenuki，去对方半场占地
    }
    if (!groupIsConfined(board, d.g) && d.value < 3) continue; // 孤子不值得救（省手数，tenuki）
    const threat = groupThreatLevel(board, d.g, toMove);
    // 打入对方地盘/边境的己方龙 = 生存优先（保住活子分/前线据点）
    const baseScore = (inOppHalf ? SEED.DEFEND + 8000 : SEED.DEFEND) + d.value * 200 + threat * 800;
    const tag = inOppHalf ? "保打入军" : "守己框架";
    for (const lib of d.g.libs) {
      if (grid[lib] === Color.EMPTY) add(lib, baseScore, tag);
    }
  }

  // 5) 影响力大场（中盘）：双方影响力都高且接近 → 落子此处能大幅改变领地归属。
  //    统一覆盖：己方半场扩展、边境线争夺、近前线大场——按竞争强度与分区加权，
  //    价值是平滑标量，早期框架未成时边境/敌区影响力够不到 → 自然不去抢（无硬门槛）。
  if (ctx.phase === "midgame") {
    const { my, opp: oppInf } = computeInfluencePair(board, toMove);
    for (let i = 0; i < grid.length; i++) {
      if (grid[i] !== Color.EMPTY || tactical.has(i)) continue;
      const r = Math.floor(i / size);
      const c = i % size;
      const z = zoneOfRowLocal(r);
      // 分区纪律：对方半场深处不直接乱入（侵消走专用通道 _findInvasionPoints）
      if (z === enemyZone(toMove) && Math.abs(r - BORDER_ROW) > FRONT_DEPTH) continue;
      const m = my[i];
      const o = oppInf[i];
      if (m + o <= 0) continue;
      // 竞争价值：双方影响力都高且接近 → 落子改变归属的收益最大
      const contested = m + o;
      const imbalance = Math.abs(m - o);
      let val = (contested - imbalance * 1.3) * 700;
      if (val <= 0) continue;
      // 分区加权（本游戏：围对方半场才得分；边境是前线——但孤子抢边境是"乱"，须连墙推进）
      if (z === ownZone(toMove)) val *= 0.6;
      else if (z === Zone.BORDER) val *= 1.0;
      else val *= 2.0;
      // 连墙偏好（GNU Go 式：先连成墙再推进，散点=坏形）：
      //   邻 2+ 己方棋 → 强加分（延伸已有墙）；邻 1 己方棋 → 小加分；全孤立 → 不奖不罚
      //   关键：只在「推进区」（边境线/对方半场）加连墙分——己方半场深处连墙 = 自补
      //   （本游戏己方半场不得分），加分只会诱导 AI 在自己半场疯狂填子（退化行为）。
      let ownNbr = 0;
      let oppNbr = 0;
      for (const [nr, nc] of board.neighbors(r, c)) {
        const v = grid[nr * size + nc];
        if (v === toMove) ownNbr++;
        else if (v === opp) oppNbr++;
      }
      const isAdvanceZone = z !== ownZone(toMove) || Math.abs(r - BORDER_ROW) <= 3;
      if (isAdvanceZone && ownNbr >= 2) val += ownNbr * 2200;
      else if (isAdvanceZone && ownNbr === 1) val += 500;
      if (oppNbr >= 3) val -= 6000;
      if (val <= 0) continue;
      add(i, SEED.BIG + val, "大场");
    }
  }

  // 6) 围空连墙 / 围空延伸（中盘·推进区）：在对方半场/边境贴己方墙推进。
  //    本游戏得分 = 在对方半场/边境用己方棋围成闭合圈（TerritoryDetector 闭合圈 +2/点，
  //    棋盘边缘算天然墙）。侵入散点（第 7 段）单点打入从不连墙 → 实测 35 次侵入围空仅 +10。
  //    这里给「贴己方棋 ≥1」的推进区空点高种子，让 AI 把墙连起来最终围成圈。
  //    只在推进区生成（对方半场∪边境）——己方半场连墙 = 自补不得分（退化行为，用户曾反馈）。
  if (ctx.phase === "midgame" && ctx.ready) {
    for (let r = 0; r < size; r++) {
      const z = zoneOfRowLocal(r);
      if (z === ownZone(toMove) && r !== BORDER_ROW) continue; // 己方半场不做
      for (let c = 0; c < size; c++) {
        const i = r * size + c;
        if (grid[i] !== Color.EMPTY || tactical.has(i)) continue;
        let ownNbr = 0;
        let oppNbr = 0;
        for (const [nr, nc] of board.neighbors(r, c)) {
          const v = grid[nr * size + nc];
          if (v === toMove) ownNbr++;
          else if (v === opp) oppNbr++;
        }
        if (ownNbr === 0) continue; // 无己方依托 → 交给侵入段
        // 连墙（贴 2+ 己方棋）种子最高；延伸（贴 1）次之；边境线是前线封口，额外加成。
        const s = SEED.INVADE + 6000 + ownNbr * 3000 + (r === BORDER_ROW ? 3000 : 0) - oppNbr * 800;
        add(i, s, ownNbr >= 2 ? "围空连墙" : "围空延伸");
      }
    }
  }

  // 7) 侵消 / 打入：近前线大空边界点（预计算传入，仅根节点；越近前线越高分、贴住对方越高分）
  if (ctx.invasion !== null) {
    for (const p of ctx.invasion) {
      const idx = p.row * size + p.col;
      if (grid[idx] !== Color.EMPTY || tactical.has(idx)) continue;
      const depth = Math.abs(p.row - BORDER_ROW);
      let enemyNbr = 0;
      for (const [nr, nc] of board.neighbors(p.row, p.col)) {
        if (grid[nr * size + nc] === opp) enemyNbr++;
      }
      const s = SEED.INVADE + (FRONT_DEPTH - depth) * 1500 + enemyNbr * 600;
      add(idx, s, "侵消/打入");
    }
  }

  // 8) 随机安全点兜底（保证有候选、多样性；己方半场优先）
  const myRows: number[] = [];
  for (let r = 0; r < size; r++) if (zoneOfRowLocal(r) === ownZone(toMove) || r === BORDER_ROW) myRows.push(r);
  for (let k = 0; k < 14; k++) {
    let r: number;
    if (Math.random() < 0.7 && myRows.length > 0) {
      r = myRows[Math.floor(Math.random() * myRows.length)];
    } else {
      r = Math.floor(Math.random() * size);
    }
    const c = Math.floor(Math.random() * size);
    const idx = r * size + c;
    if (grid[idx] !== Color.EMPTY || tactical.has(idx)) continue;
    add(idx, SEED.RANDOM + Math.random() * 80, "随机");
  }

  const arr = Array.from(map.values());
  arr.sort((a, b) => b.score - a.score);
  const top = arr.slice(0, maxN);

  // 终过滤：非战术点且落子后自填气（<2 气）→ 剔除
  const out: ScoredMove[] = [];
  for (const m of top) {
    const idx = m.row * size + m.col;
    if (!tactical.has(idx) && libsAfterVirtualPlace(board, m.row, m.col, toMove) < 2) continue;
    out.push(m);
  }
  return out;
}

// ====== AI 引擎总控 ======

// 布局阶段 AI 布子偏好点（{row, col}，仅限己方领土：黑行0-8 / 白行10-18）
// 优先级与传统围棋一致：占角 > 占边 > 中腹。严禁把棋盘正中（col 9 中腹）排最前——
// 本游戏得分在对方半场/边境，开局先立己方角部根据地方能推进。原偏好点把 (7,9)/(11,9)
// 中腹排第一，AI 布局阶段总下棋盘正中，观感像乱下。
const DEPLOY_PREF_BLACK: Point[] = [
  { row: 3, col: 3 }, { row: 3, col: 15 }, { row: 5, col: 5 }, { row: 5, col: 13 },
  { row: 7, col: 3 }, { row: 7, col: 15 }, { row: 3, col: 6 }, { row: 3, col: 12 },
  { row: 5, col: 3 }, { row: 5, col: 15 }, { row: 7, col: 6 }, { row: 7, col: 12 },
  { row: 3, col: 9 }, { row: 5, col: 9 }, { row: 7, col: 9 },
];
const DEPLOY_PREF_WHITE: Point[] = [
  { row: 15, col: 3 }, { row: 15, col: 15 }, { row: 13, col: 5 }, { row: 13, col: 13 },
  { row: 11, col: 3 }, { row: 11, col: 15 }, { row: 15, col: 6 }, { row: 15, col: 12 },
  { row: 13, col: 3 }, { row: 13, col: 15 }, { row: 11, col: 6 }, { row: 11, col: 12 },
  { row: 15, col: 9 }, { row: 13, col: 9 }, { row: 11, col: 9 },
];

export class AIEngine {
  readonly color: Color;
  private readonly difficulty: AIDifficulty;
  private readonly searchEngine = new SearchEngine();

  constructor(color: Color, difficulty: AIDifficulty = AIDifficulty.NORMAL) {
    this.color = color;
    this.difficulty = difficulty;
  }

  // 主接口：选择一步棋（布局阶段返回己方领土布子点，正式阶段价值驱动 + 攻防读棋）
  chooseMove(session: GameSession): AIMove {
    if (session.isInDeployPhase()) {
      return this._chooseDeployMove(session);
    }
    const config = getAIConfig(this.difficulty);
    return this.searchEngine.findBestMove(session, this.color, config);
  }

  // 布局阶段：优先偏好点（己方领土中腹/星位），占满后随机兜底
  private _chooseDeployMove(session: GameSession): AIMove {
    const prefs = this.color === Color.WHITE ? DEPLOY_PREF_WHITE : DEPLOY_PREF_BLACK;
    for (const p of prefs) {
      if (session.board.isEmpty(p.row, p.col)) {
        return { type: "move", row: p.row, col: p.col, reason: "布局偏好点" };
      }
    }
    // 兜底：己方领土内随机空点
    const empties: Point[] = [];
    const myZone = ownZone(this.color);
    for (let r = 0; r < session.board.size; r++) {
      if (zoneOfRowLocal(r) !== myZone) continue;
      for (let c = 0; c < session.board.size; c++) {
        if (session.board.isEmpty(r, c)) empties.push({ row: r, col: c });
      }
    }
    if (empties.length > 0) {
      const pick = empties[Math.floor(Math.random() * empties.length)];
      return { type: "move", row: pick.row, col: pick.col, reason: "布局随机布子" };
    }
    return { type: "pass", row: -1, col: -1, reason: "己方领土已满" };
  }
}
