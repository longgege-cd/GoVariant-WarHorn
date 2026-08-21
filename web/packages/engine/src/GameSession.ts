// 对局管理：核心状态机
// 职责：落子/虚手流程、布局阶段、兵力上限、虚手限制、连续虚手终局、终局结算
// 对应 GDScript c:\边境线\scripts\core\GameSession.gd (750行)
//
// MVP 简化：
//   - 不实现 SpecialForces（特种部队关闭）
//   - 不实现全局同形劫争历史（仅基本劫）
//   - 终局劫争简化为 ko_point 净增判定
//   - 保留悔棋接口但简化快照

import {
  Color, opponent, KOMI_DEFAULT, PIECE_LIMIT,
  isDefenseZone, isAttackZone, ownZone, Zone,
  PASS_LIMIT_PER_GAME, PASS_COOLDOWN_TURNS,
  DEPLOY_PHASE_MOVES, FOG_DAWN_PLY,
} from "./Const.js";
import { BoardModel, Point, Group } from "./BoardModel.js";
import { GoRules, MoveResult, NO_KO } from "./GoRules.js";
import { visionCells, visibleGrid, fogCells } from "./FogUtils.js";
import { SiegeDetector } from "./SiegeDetector.js";
import { TerritoryDetector, Enclosure } from "./TerritoryDetector.js";
import {
  ScoreCalculator, CountersMap, makeCounters,
} from "./ScoreCalculator.js";
import type { MoveOutcome, FinalResult, ScoreBreakdown, ScoreSide } from "@warhorn/shared";

export interface GameSessionOptions {
  komi?: number;
  pieceLimit?: number;
  enableDeployPhase?: boolean; // 布局阶段（前4手必须落己方领土）
  fogEnabled?: boolean; // 战争迷雾（可选规则，默认关闭）
}

export class GameSession {
  readonly board: BoardModel;
  komi: number;
  pieceLimit: number;
  enableDeployPhase: boolean;
  fogEnabled: boolean; // 战争迷雾开关
  fogRevealed: Set<number> = new Set(); // 已现形的对方隐藏棋子（索引），网络/渲染可见

  toMove: Color = Color.BLACK;
  ply: number = 0;
  consecutivePasses: number = 0;
  passCounts: Map<Color, number>; // 每方本局虚手次数
  passCooldown: Map<Color, number>; // color -> 己方回合计数（达到 PASS_COOLDOWN_TURNS 即可虚手）
  skipPassLimits: boolean = false; // 回放/审计用

  gameOver: boolean = false;
  stonesPlaced: Map<Color, number>; // 累计普通落子数
  counters: CountersMap;
  lastOutcome: MoveOutcome | FinalResult | null = null;

  koPoint: Point = NO_KO;
  lastFinalResult: FinalResult | null = null;

  // 缓存
  private _cachedScores: { black: ScoreBreakdown; white: ScoreBreakdown } | null = null;
  private _cachedEnclosures: Enclosure[] | null = null;
  private _cachedSiegedGroups: Group[] | null = null;
  private _cacheValid: boolean = false;
  private _useCache: boolean = true;

  // 悔棋栈（简化）
  private _undoStack: GameSnapshot[] = [];
  private _pendingSnap: GameSnapshot | null = null;
  private static readonly MAX_UNDO = 30;

  // 事件回调（替代 GDScript signal）
  onMoveCommitted?: (outcome: MoveOutcome) => void;
  onScoresChanged?: (scores: { black: ScoreBreakdown; white: ScoreBreakdown }) => void;
  onGameEnded?: (result: FinalResult) => void;
  emitSignals: boolean = true;

  constructor(opts: GameSessionOptions = {}) {
    this.board = new BoardModel();
    this.komi = opts.komi ?? KOMI_DEFAULT;
    this.pieceLimit = opts.pieceLimit ?? PIECE_LIMIT;
    this.enableDeployPhase = opts.enableDeployPhase ?? true;
    this.fogEnabled = opts.fogEnabled ?? false;
    this.passCounts = new Map([[Color.BLACK, 0], [Color.WHITE, 0]]);
    this.passCooldown = new Map([[Color.BLACK, PASS_COOLDOWN_TURNS], [Color.WHITE, PASS_COOLDOWN_TURNS]]);
    this.stonesPlaced = new Map([[Color.BLACK, 0], [Color.WHITE, 0]]);
    this.counters = makeCounters();
    this._resetState();
  }

  private _resetState(): void {
    this.toMove = Color.BLACK;
    this.ply = 0;
    this.consecutivePasses = 0;
    this.passCounts.set(Color.BLACK, 0);
    this.passCounts.set(Color.WHITE, 0);
    this.passCooldown.set(Color.BLACK, PASS_COOLDOWN_TURNS);
    this.passCooldown.set(Color.WHITE, PASS_COOLDOWN_TURNS);
    this.gameOver = false;
    this.stonesPlaced.set(Color.BLACK, 0);
    this.stonesPlaced.set(Color.WHITE, 0);
    this.counters = makeCounters();
    this.koPoint = NO_KO;
    this.lastOutcome = null;
    this.lastFinalResult = null;
    this.fogRevealed.clear();
    this._undoStack = [];
    this._pendingSnap = null;
    this._invalidateCache();
  }

  newGame(): void {
    this.board.grid.fill(Color.EMPTY);
    this._resetState();
  }

  // ====== 缓存 ======
  private _invalidateCache(): void {
    this._cacheValid = false;
    this._cachedScores = null;
    this._cachedEnclosures = null;
    this._cachedSiegedGroups = null;
  }

  private _ensureCache(): void {
    if (!this._useCache || this._cacheValid) return;
    const da = SiegeDetector.solveDeadAlive(this.board);
    this._cachedSiegedGroups = da.sieged;
    this._cachedEnclosures = TerritoryDetector.enclosures(this.board);
    this._cachedScores = ScoreCalculator.compute(
      this.board, this.counters, this._cachedSiegedGroups, this._cachedEnclosures
    );
    this._cacheValid = true;
  }

  scores(): { black: ScoreBreakdown; white: ScoreBreakdown } {
    if (this._useCache) {
      this._ensureCache();
      return this._cachedScores!;
    }
    return ScoreCalculator.compute(this.board, this.counters);
  }

  enclosures(): Enclosure[] {
    if (this._useCache) {
      this._ensureCache();
      return this._cachedEnclosures!;
    }
    return TerritoryDetector.enclosures(this.board);
  }

  siegedGroups(): Group[] {
    if (this._useCache) {
      this._ensureCache();
      return this._cachedSiegedGroups!;
    }
    return SiegeDetector.solveDeadAlive(this.board).sieged;
  }

  // ====== 兵力 ======
  piecesLeft(color: Color): number {
    return Math.max(0, this.pieceLimit - (this.stonesPlaced.get(color) ?? 0));
  }

  canPlace(color: Color): boolean {
    return !this.gameOver && this.piecesLeft(color) > 0;
  }

  // ====== 布局阶段 ======
  isInDeployPhase(): boolean {
    if (!this.enableDeployPhase) return false;
    return this.ply < DEPLOY_PHASE_MOVES;
  }

  // 布局阶段：必须落己方领土（row 0..8 for BLACK, row 10..18 for WHITE）
  private _isDeployMoveLegal(row: number, col: number, color: Color): boolean {
    const zone = ownZone(color);
    const rowZone = row < 9 ? Zone.BLACK : row === 9 ? Zone.BORDER : Zone.WHITE;
    return rowZone === zone;
  }

  // ====== 落子 ======
  playMove(color: Color, row: number, col: number): MoveOutcome {
    const outcome: MoveOutcome = {
      ok: false,
      moverColor: color,
    };

    if (this.gameOver) {
      outcome.reason = "对局已结束";
      return outcome;
    }
    if (this.toMove !== color) {
      outcome.reason = "非该方行棋";
      return outcome;
    }
    if (!this.canPlace(color)) {
      outcome.reason = "兵力已用尽";
      return outcome;
    }
    if (!this.board.inBounds(row, col)) {
      outcome.reason = "越界";
      return outcome;
    }
    if (this.isInDeployPhase() && !this._isDeployMoveLegal(row, col, color)) {
      outcome.reason = "布局阶段必须落己方领土";
      return outcome;
    }

    // 取行棋前快照（遭遇战/正常落子均在此之后变更棋盘）
    this._beginUndoSnapshot();

    // 战争迷雾遭遇战：落点被对方隐藏棋子占据（mover 迷雾下不可见）
    if (!this.board.isEmpty(row, col)) {
      if (this.isFogActive() && this._resolveEncounter(color, row, col, outcome)) {
        // 已现形并弹子/吞子，完成整手
        this._commitFogMove(outcome, color);
        return outcome;
      }
      outcome.reason = "该点已有棋子";
      return outcome;
    }

    const res = GoRules.tryMove(this.board, row, col, color, this.koPoint);
    if (!res.legal) {
      outcome.ok = false;
      outcome.reason = res.reason;
      return outcome;
    }

    outcome.ok = true;
    outcome.placed = { row, col };
    outcome.captures = res.captured;
    outcome.capturedColor = res.capturedColor;
    this.koPoint = res.koPoint;

    // 处理被提子（计数 + 歼灭分）
    this._processCaptures(res, color);

    // 计数普通落子
    this.stonesPlaced.set(color, (this.stonesPlaced.get(color) ?? 0) + 1);

    this._commitTurn(outcome, color, true);
    return outcome;
  }

  // ====== 虚手 ======
  doPass(color: Color): MoveOutcome {
    const outcome: MoveOutcome = {
      ok: false,
      moverColor: color,
    };

    if (this.gameOver) {
      outcome.reason = "对局已结束";
      return outcome;
    }
    if (this.toMove !== color) {
      outcome.reason = "非该方行棋";
      return outcome;
    }

    // 棋子用尽：自动获得虚手权——不消耗次数、不受冷却限制（可无限虚手直至终局）
    const exhausted = this.piecesLeft(color) <= 0;

    // 虚手次数限制（每方每局 2 次）；棋子用尽时豁免
    if (!this.skipPassLimits && !exhausted && (this.passCounts.get(color) ?? 0) >= PASS_LIMIT_PER_GAME) {
      outcome.ok = false;
      outcome.reason = `虚手次数已用尽（每方每局 ${PASS_LIMIT_PER_GAME} 次）`;
      return outcome;
    }

    // 虚手冷却（自上次虚手后需 2 个己方实际行棋回合）；棋子用尽时豁免
    if (!this.skipPassLimits && !exhausted && (this.passCooldown.get(color) ?? PASS_COOLDOWN_TURNS) < PASS_COOLDOWN_TURNS) {
      outcome.ok = false;
      const left = PASS_COOLDOWN_TURNS - (this.passCooldown.get(color) ?? 0);
      outcome.reason = `虚手冷却中（还需 ${left} 个己方回合）`;
      return outcome;
    }

    this._beginUndoSnapshot();
    this.consecutivePasses += 1;
    if (!exhausted) {
      this.passCounts.set(color, (this.passCounts.get(color) ?? 0) + 1);
      this.passCooldown.set(color, 0);
    }

    outcome.ok = true;
    outcome.passed = true;
    outcome.placed = { row: -1, col: -1 };
    this.koPoint = NO_KO; // 虚手不产生劫

    // 终局判定
    let endReason = "";
    if (this.consecutivePasses >= 2) {
      const blackExhausted = this.piecesLeft(Color.BLACK) <= 0;
      const whiteExhausted = this.piecesLeft(Color.WHITE) <= 0;
      if (blackExhausted || whiteExhausted) {
        endReason = "一方兵力用尽且双方连续虚手";
      } else if (this._bothCannotMove()) {
        endReason = "双方均无法落子";
      } else {
        endReason = "双方连续虚手";
      }
    }

    if (endReason !== "") {
      this._endGame(endReason);
      outcome.gameOver = true;
      outcome.result = this.lastFinalResult ?? undefined;
      this._emitMove(outcome);
      return outcome;
    }

    this._commitTurn(outcome, color, false);
    return outcome;
  }

  // ====== 认输 ======
  resign(color: Color): MoveOutcome {
    const outcome: MoveOutcome = { ok: false, moverColor: color };
    if (this.gameOver) {
      outcome.reason = "对局已结束";
      return outcome;
    }
    const winner = opponent(color);
    const result = this._buildFinalResult(`${color === Color.BLACK ? "黑" : "白"}方认输`);
    result.winner = winner === Color.BLACK ? "黑方胜" : "白方胜";
    result.winnerColor = winner;
    this.lastFinalResult = result;
    this.gameOver = true;
    outcome.ok = true;
    outcome.gameOver = true;
    outcome.result = result;
    if (this.emitSignals) this.onGameEnded?.(result);
    return outcome;
  }

  // ====== 内部 ======
  private _processCaptures(res: MoveResult, moverColor: Color): void {
    const capturedColor = res.capturedColor;
    if (capturedColor === Color.EMPTY || res.captured.length === 0) return;
    const counter = this.counters.get(capturedColor) ?? { annihilate: 0, normalLost: 0, specialLost: 0 };
    counter.normalLost += res.captured.length;
    this.counters.set(capturedColor, counter);

    // 歼灭分：提吃发生在「提子方」的防御区（己境/边境）
    const moverCounter = this.counters.get(moverColor) ?? { annihilate: 0, normalLost: 0, specialLost: 0 };
    for (const cap of res.captured) {
      if (isDefenseZone(cap.row, moverColor)) {
        moverCounter.annihilate += 1;
      }
    }
    this.counters.set(moverColor, moverCounter);
  }

  // 遭遇战整手收尾：标记成功并转账，随即提交（含黎明检测）
  private _commitFogMove(outcome: MoveOutcome, color: Color): void {
    outcome.ok = true;
    if (!outcome.placed) outcome.placed = { row: -1, col: -1 };
    this._commitTurn(outcome, color, true);
  }

  private _commitTurn(outcome: MoveOutcome, color: Color, didPlace: boolean): void {
    if (!outcome.passed) {
      this.consecutivePasses = 0;
      const prev = this.passCooldown.get(color) ?? 0;
      this.passCooldown.set(color, Math.min(prev + 1, PASS_COOLDOWN_TURNS));
    }
    this.ply += 1;
    outcome.ply = this.ply;
    // 第 FOG_DAWN_PLY 手黎明：迷雾消散，全盘可见
    if (this.fogEnabled && this.ply === FOG_DAWN_PLY && !outcome.dawn) {
      outcome.dawn = true;
      this.fogRevealed.clear();
    }
    this.toMove = opponent(color);
    this.lastOutcome = outcome; // 记录最后一手（供 UI 标记/悔棋对比基准）

    // 悔棋栈
    if (this._pendingSnap) {
      this._undoStack.push(this._pendingSnap);
      this._pendingSnap = null;
      if (this._undoStack.length > GameSession.MAX_UNDO) this._undoStack.shift();
    }
    this._invalidateCache();
    this._emitMove(outcome);
  }

  private _emitMove(outcome: MoveOutcome): void {
    if (!this.emitSignals) return;
    this.onMoveCommitted?.(outcome);
    this.onScoresChanged?.(this.scores());
  }

  private _bothCannotMove(): boolean {
    if (GoRules.hasAnyLegalMove(this.board, Color.BLACK, this.koPoint)) return false;
    if (GoRules.hasAnyLegalMove(this.board, Color.WHITE, this.koPoint)) return false;
    return true;
  }

  hasLegalMove(color: Color): boolean {
    if (!this.canPlace(color)) return false;
    return GoRules.hasAnyLegalMove(this.board, color, this.koPoint);
  }

  // ====== 战争迷雾（可选规则） ======
  // 迷雾从布局阶段起生效，第30手（总手数）黎明后全盘可见
  isFogActive(): boolean {
    return this.fogEnabled && this.ply < FOG_DAWN_PLY;
  }

  // color 方的可见单元格（己方棋子 + 曼哈顿距离≤2）
  visionCellsOf(color: Color): Set<number> {
    return visionCells(color, this.board);
  }

  // color 方视角的可见网格（隐藏视野外对方棋子）
  visibleGridOf(color: Color): Uint8Array {
    return visibleGrid(this.board.grid, color, this.board, this.isFogActive(), this.fogRevealed);
  }

  // color 方视角的迷雾覆盖区域
  fogCellsOf(color: Color): Set<number> {
    return fogCells(this.board, color, this.isFogActive(), this.fogRevealed);
  }

  // 遭遇战落子：落点被对方隐藏棋子占据（mover 迷雾下不可见）。
  // 规则书 v7.3：对方显形，mover 落子弹至周围可落子点；无可用点则被消灭(-1战损，棋子不保留)。
  private _resolveEncounter(color: Color, row: number, col: number, outcome: MoveOutcome): boolean {
    const enemy = opponent(color);
    if (this.board.getAt(row, col) !== enemy) return false;
    if (this.fogRevealed.has(row * this.board.size + col)) return false; // 已现形则按正常路径拒绝
    // 该点必须在 mover 视野外（真·隐藏）才触发遭遇战
    if (this.visionCellsOf(color).has(row * this.board.size + col)) return false;

    // 1. 对方隐藏子现形
    this.fogRevealed.add(row * this.board.size + col);
    (outcome.revealed ??= []).push({ row, col });

    // 2. 弹子：周围八格优先选可落子且更靠近己方棋子的位置
    const candidates = this._bounceCandidates(color, row, col);
    let landed: Point | null = null;
    if (candidates.length > 0) {
      landed = candidates[0];
      const res = GoRules.tryMove(this.board, landed.row, landed.col, color, this.koPoint);
      if (res.legal) {
        outcome.placed = { row: landed.row, col: landed.col };
        outcome.captures = res.captured;
        outcome.capturedColor = res.capturedColor;
        this.koPoint = res.koPoint;
        this._processCaptures(res, color);
        this.stonesPlaced.set(color, (this.stonesPlaced.get(color) ?? 0) + 1);
      } else {
        landed = null;
      }
    }

    // 3. 弹子失败（或被八格均不可落）：棋子被消灭
    if (!landed) {
      const counter = this.counters.get(color) ?? { annihilate: 0, normalLost: 0, specialLost: 0 };
      counter.normalLost += 1;
      this.counters.set(color, counter);
      this.stonesPlaced.set(color, (this.stonesPlaced.get(color) ?? 0) + 1);
    }

    outcome.encounter = true;
    return true;
  }

  // 遭遇战弹子候选：周围八格中空且合法，优先靠近己方棋子（能形成活形）
  private _bounceCandidates(color: Color, row: number, col: number): Point[] {
    const size = this.board.size;
    const list: Point[] = [];
    for (let dr = -1; dr <= 1; dr++) {
      for (let dc = -1; dc <= 1; dc++) {
        if (dr === 0 && dc === 0) continue;
        const nr = row + dr;
        const nc = col + dc;
        if (nr < 0 || nr >= size || nc < 0 || nc >= size) continue;
        if (GoRules.isLegal(this.board, nr, nc, color, this.koPoint)) list.push({ row: nr, col: nc });
      }
    }
    // 优先选择与己方棋子相邻的位置（更易形成活形、不被反吃）
    const nearOwn = (p: Point): boolean => {
      for (const [nr, nc] of this.board.neighbors(p.row, p.col)) {
        if (this.board.getAt(nr, nc) === color) return true;
      }
      return false;
    };
    list.sort((a, b) => (nearOwn(b) ? 1 : 0) - (nearOwn(a) ? 1 : 0));
    return list;
  }

  private _endGame(reason: string): void {
    this.gameOver = true;
    const result = this._buildFinalResult(reason);
    this.lastFinalResult = result;
    if (this.emitSignals) this.onGameEnded?.(result);
  }

  // 终局结算（含简化的终局劫争处理）
  private _buildFinalResult(reason: string): FinalResult {
    // 简化：终局若有 ko_point，直接判定谁提劫净增更大
    this._resolveKoAtEndgame();

    const res = ScoreCalculator.computeFinal(this.board, this.counters, this.komi);
    res.reason = reason;
    res.ply = this.ply;
    return res;
  }

  // 终局劫争处理（简化版）：若有 ko_point，模拟双方提劫，取净增较大者
  private _resolveKoAtEndgame(): void {
    if (this.koPoint.row < 0 || this.koPoint.col < 0) return;

    const savedBoard = this.board.clone();
    const savedCounters = this.counters;
    const savedKo = this.koPoint;

    // 模拟黑方提劫
    this.counters = new Map(savedCounters);
    const blackNet = this._simulateKoWin(Color.BLACK);

    // 还原 → 模拟白方提劫
    this.board.grid = new Uint8Array(savedBoard.grid);
    this.counters = new Map(savedCounters);
    const whiteNet = this._simulateKoWin(Color.WHITE);

    // 还原 → 应用净增较大者
    this.board.grid = new Uint8Array(savedBoard.grid);
    this.counters = new Map(savedCounters);
    if (blackNet > whiteNet) this._applyKoWin(Color.BLACK);
    else if (whiteNet > blackNet) this._applyKoWin(Color.WHITE);

    this.koPoint = NO_KO;
    this._invalidateCache();
    void savedKo;
  }

  private _simulateKoWin(winner: Color): number {
    const before = ScoreCalculator.compute(this.board, this.counters);
    const beforeTotal = winner === Color.BLACK
      ? this._totalOf(before.black)
      : this._totalOf(before.white);
    this._applyKoWin(winner);
    const after = ScoreCalculator.compute(this.board, this.counters);
    const afterTotal = winner === Color.BLACK
      ? this._totalOf(after.black)
      : this._totalOf(after.white);
    return afterTotal - beforeTotal;
  }

  private _applyKoWin(winner: Color): void {
    const res = GoRules.tryMove(this.board, this.koPoint.row, this.koPoint.col, winner, NO_KO);
    if (res.legal) {
      this._processCaptures(res, winner);
    }
  }

  private _totalOf(b: ScoreBreakdown): number {
    return b.occupationTerritory + b.occupationEfficiency + b.defenseAnnihilate + b.defenseSiege + b.casualtyLoss + b.casualtySpecial;
  }

  // ====== 悔棋 ======
  canUndo(): boolean {
    return this._undoStack.length > 0 && !this.gameOver;
  }

  undo(): MoveOutcome {
    const outcome: MoveOutcome = { ok: false, moverColor: this.toMove };
    if (!this.canUndo()) {
      outcome.reason = "无法悔棋";
      return outcome;
    }
    const snap = this._undoStack.pop()!;
    this._restoreSnapshot(snap);
    outcome.ok = true;
    outcome.undid = true;
    return outcome;
  }

  // ====== 快照 ======
  private _beginUndoSnapshot(): void {
    this._pendingSnap = this._takeSnapshot();
  }

  private _takeSnapshot(): GameSnapshot {
    return {
      grid: new Uint8Array(this.board.grid),
      toMove: this.toMove,
      ply: this.ply,
      consecutivePasses: this.consecutivePasses,
      passCounts: new Map(this.passCounts),
      passCooldown: new Map(this.passCooldown),
      gameOver: this.gameOver,
      stonesPlaced: new Map(this.stonesPlaced),
      counters: new Map(
        Array.from(this.counters.entries()).map(([k, v]) => [k, { ...v }])
      ),
      koPoint: { ...this.koPoint },
      lastOutcome: this.lastOutcome,
      fogEnabled: this.fogEnabled,
      fogRevealed: new Set(this.fogRevealed),
    };
  }

  private _restoreSnapshot(snap: GameSnapshot): void {
    this.board.grid = new Uint8Array(snap.grid);
    this.toMove = snap.toMove;
    this.ply = snap.ply;
    this.consecutivePasses = snap.consecutivePasses;
    this.passCounts = new Map(snap.passCounts);
    this.passCooldown = new Map(snap.passCooldown);
    this.gameOver = snap.gameOver;
    this.stonesPlaced = new Map(snap.stonesPlaced);
    this.counters = new Map(
      Array.from(snap.counters.entries()).map(([k, v]) => [k, { ...v }])
    );
    this.koPoint = { ...snap.koPoint };
    this.lastOutcome = snap.lastOutcome;
    this.fogEnabled = snap.fogEnabled;
    this.fogRevealed = new Set(snap.fogRevealed);
    this._invalidateCache();
  }

  // ====== 克隆（供 AI 搜索用，MVP 暂不用但保留） ======
  clone(): GameSession {
    const s = new GameSession({
      komi: this.komi,
      pieceLimit: this.pieceLimit,
      enableDeployPhase: this.enableDeployPhase,
      fogEnabled: this.fogEnabled,
    });
    s.board.grid = new Uint8Array(this.board.grid);
    s.toMove = this.toMove;
    s.ply = this.ply;
    s.consecutivePasses = this.consecutivePasses;
    s.passCounts = new Map(this.passCounts);
    s.passCooldown = new Map(this.passCooldown);
    s.gameOver = this.gameOver;
    s.stonesPlaced = new Map(this.stonesPlaced);
    s.counters = new Map(
      Array.from(this.counters.entries()).map(([k, v]) => [k, { ...v }])
    );
    s.koPoint = { ...this.koPoint };
    s.fogRevealed = new Set(this.fogRevealed);
    s._useCache = false; // 克隆禁用缓存避免频繁失效
    return s;
  }
}

interface GameSnapshot {
  grid: Uint8Array;
  toMove: Color;
  ply: number;
  consecutivePasses: number;
  passCounts: Map<Color, number>;
  passCooldown: Map<Color, number>;
  gameOver: boolean;
  stonesPlaced: Map<Color, number>;
  counters: CountersMap;
  koPoint: Point;
  lastOutcome: MoveOutcome | FinalResult | null;
  fogEnabled: boolean;
  fogRevealed: Set<number>;
}
