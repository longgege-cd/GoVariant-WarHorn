// 对局界面：棋盘 + 双方得分板 + 控制按钮 + 终局结算
// 支持 M1 本地对战（黑白交替，同一台机器）
// 得分板按原项目 ScorePanel.gd 5模块结构实现

import {
  GameSession, Color, opponent, BOARD_SIZE,
  TIMER_BASE_SEC, BYO_PERIOD_SEC, BYO_COUNT,
  PASS_LIMIT_PER_GAME,
  DEPLOY_TIMER_SEC, DEPLOY_PHASE_MOVES,
  KOMI_DEFAULT, PIECE_LIMIT,
  AIEngine, AIDifficulty,
} from "@warhorn/engine";
import type { MoveOutcome, FinalResult, ScoreBreakdown } from "@warhorn/shared";
import { BoardCanvas } from "../BoardCanvas.js";
import { ScorePanel, type ScoreLogEntry } from "../components/ScorePanel.js";
import type { Enclosure, Group } from "@warhorn/engine";
import { t, tpl, tThemeName } from "../i18n.js";

// 读秒制计时状态（围棋比赛：主时 + 读秒N次，读秒连续倒数、落子不重置）
interface SideTimer {
  main: number; // 剩余主时间（秒）
  inByoyomi: boolean; // 是否在读秒
  byoRemaining: number; // 剩余读秒次数
  byoCur: number; // 当前读秒剩余（秒）
}

export class GameScreen {
  readonly el: HTMLElement;
  private session: GameSession;
  private boardCanvas: BoardCanvas;
  private timer: { black: SideTimer; white: SideTimer };
  private deployTimer: { black: number; white: number };
  private timerActive: Color;
  private timerInterval: number | null = null;
  private logEntries: ScoreLogEntry[] = [];
  private gameOver: boolean = false;

  // 特效状态缓存（落子前快照，用于对比围空/围困变化）
  private prevEnclosures: Enclosure[] = [];
  private prevSieged: Set<number> = new Set();

  // 得分板组件
  private blackPanel: ScorePanel;
  private whitePanel: ScorePanel;

  // 简易历史显示（侧边栏）
  private statusEl!: HTMLElement;
  private deployBannerEl!: HTMLElement;
  private passBtn!: HTMLButtonElement;
  private undoBtn!: HTMLButtonElement;
  private resignBtn!: HTMLButtonElement;

  // AI 对手
  private aiColor: Color | null = null;
  private aiEngine: AIEngine | null = null;
  private aiDifficulty: AIDifficulty = AIDifficulty.NORMAL;
  private aiTimeout: number | null = null;

  constructor(
    blackName: string = t("name.default.black"),
    whiteName: string = t("name.default.white"),
    aiColor: Color | null = null,
    aiDifficulty: AIDifficulty = AIDifficulty.NORMAL,
    fogEnabled: boolean = false
  ) {
    this.aiColor = aiColor;
    this.aiDifficulty = aiDifficulty;
    if (aiColor !== null) {
      this.aiEngine = new AIEngine(aiColor, aiDifficulty);
    }
    this.session = new GameSession({
      komi: KOMI_DEFAULT,
      pieceLimit: PIECE_LIMIT,
      enableDeployPhase: true,
      fogEnabled: fogEnabled === true,
    });
    this.timer = { black: this._freshTimer(), white: this._freshTimer() };
    this.deployTimer = { black: DEPLOY_TIMER_SEC, white: DEPLOY_TIMER_SEC };
    this.timerActive = Color.BLACK;

    this.boardCanvas = new BoardCanvas({ cellSize: 30, padding: 26 });
    this.boardCanvas.setDeployPhase(true);
    this.boardCanvas.onInfluenceToggle = (shown) => {
      this._showToast(shown ? t("influence.on") : t("influence.off"));
    };
    this.boardCanvas.onThemeToggle = (name) => {
      this._showToast(tpl("theme.switched", tThemeName(name)));
    };
    this.blackPanel = new ScorePanel("black");
    this.whitePanel = new ScorePanel("white");
    this.el = this._build(blackName, whiteName);
    this._bindBoard();
    this._startTimer();
    this._cacheBoardState();
    this._refresh();
  }

  destroy(): void {
    this._stopTimer();
    if (this.aiTimeout !== null) clearTimeout(this.aiTimeout);
    this.boardCanvas.destroy();
    this.blackPanel.destroy();
    this.whitePanel.destroy();
  }

  private _build(blackName: string, whiteName: string): HTMLElement {
    const root = document.createElement("div");
    root.className = "screen game-screen";
    const topTitle = this.aiColor !== null ? t("title.ai") : t("title.local");
    root.innerHTML = `
      <div class="side-panel side-left" id="panel-black"></div>
      <div class="game-main">
        <div class="game-topbar">
          <span class="topbar-title">${topTitle}</span>
          <span class="topbar-status" id="status"></span>
        </div>
        <div class="board-wrapper">
          <div class="board-container" id="board-container"></div>
          <div class="deploy-banner" id="deploy-banner">${t("deployBanner")}</div>
        </div>
        <div class="game-controls">
          <button class="btn" id="btn-undo">${t("undo")}</button>
          <button class="btn" id="btn-pass">${t("pass")}</button>
          <button class="btn btn-danger" id="btn-resign">${t("resign")}</button>
          <button class="btn" id="btn-new">${t("newGame")}</button>
        </div>
      </div>
      <div class="side-panel side-right" id="panel-white"></div>
    `;
    root.querySelector("#board-container")!.appendChild(this.boardCanvas.canvas);
    root.querySelector("#panel-black")!.appendChild(this.blackPanel.el);
    root.querySelector("#panel-white")!.appendChild(this.whitePanel.el);

    this.statusEl = root.querySelector("#status")!;
    this.deployBannerEl = root.querySelector("#deploy-banner")!;
    this.passBtn = root.querySelector("#btn-pass")!;
    this.undoBtn = root.querySelector("#btn-undo")!;
    this.resignBtn = root.querySelector("#btn-resign")!;

    root.querySelector("#btn-undo")!.addEventListener("click", () => this._onUndo());
    root.querySelector("#btn-pass")!.addEventListener("click", () => this._onPass());
    root.querySelector("#btn-resign")!.addEventListener("click", () => this._onResign());
    root.querySelector("#btn-new")!.addEventListener("click", () => this._onNewGame());

    return root;
  }

  private _bindBoard(): void {
    this.boardCanvas.onCellClick = (row, col) => this._onCellClick(row, col);
  }

  private _onCellClick(row: number, col: number): void {
    if (this.gameOver) return;
    if (this._isAiTurn()) {
      this._showToast(t("aiThinking"));
      return;
    }
    const color = this.session.toMove;
    const outcome = this.session.playMove(color, row, col);
    if (!outcome.ok) {
      this._showToast(outcome.reason ?? t("moveFail"));
      return;
    }
    this._onMoveCommitted(outcome);
  }

  private _onPass(): void {
    if (this.gameOver) return;
    if (this._isAiTurn()) {
      this._showToast(t("aiThinking"));
      return;
    }
    const color = this.session.toMove;
    const outcome = this.session.doPass(color);
    if (!outcome.ok) {
      this._showToast(outcome.reason ?? t("passFail"));
      return;
    }
    this._onMoveCommitted(outcome);
  }

  private _onUndo(): void {
    if (this.gameOver) return;
    if (this._isAiTurn()) {
      this._showToast(t("undoBlocked"));
      return;
    }
    const outcome = this.session.undo();
    if (!outcome.ok) {
      this._showToast(outcome.reason ?? t("undoFail"));
      return;
    }
    if (this.logEntries.length > 0) this.logEntries.pop();
    this._cacheBoardState(); // 悔棋后重设特效对比基准（不播放特效）
    this._refresh();
    this._maybeScheduleAI(); // 悔棋后若轮到 AI，则让其重新行棋
  }

  private _onResign(): void {
    if (this.gameOver) return;
    if (this._isAiTurn()) {
      this._showToast(t("aiThinking"));
      return;
    }
    const color = this.session.toMove;
    if (!confirm(tpl("resignConfirm", t(color === Color.BLACK ? "mover.black" : "mover.white")))) return;
    const outcome = this.session.resign(color);
    if (outcome.result) {
      this._endGame(outcome.result);
    }
  }

  private _onNewGame(): void {
    if (!confirm(t("newConfirm"))) return;
    this.session.newGame();
    this.timer.black = this._freshTimer();
    this.timer.white = this._freshTimer();
    this.deployTimer.black = DEPLOY_TIMER_SEC;
    this.deployTimer.white = DEPLOY_TIMER_SEC;
    this.timerActive = Color.BLACK;
    this.logEntries = [];
    this.gameOver = false;
    this.boardCanvas.setDeployPhase(true);
    this._cacheBoardState();
    this._startTimer();
    this._refresh();
    this._maybeScheduleAI(); // AI 执黑时开局先手
  }

  private _onMoveCommitted(outcome: MoveOutcome): void {
    // 虚手提示
    if (outcome.passed) {
      const mover = (outcome.moverColor ?? this.session.toMove) as Color;
      this._showToast(tpl("passed", t(mover === Color.BLACK ? "mover.black" : "mover.white")), 1500);
    }

    // 战争迷雾：遭遇战 / 黎明提示
    if (outcome.encounter) {
      if (outcome.placed && outcome.placed.row >= 0) {
        this._showToast(t("fog.encounterBounce"), 2500);
      } else {
        this._showToast(t("fog.encounterDestroy"), 2500);
      }
    }
    if (outcome.dawn) {
      this._showToast(t("fog.dawn"), 3000);
    }

    // 检测布局→正式对局过渡
    const wasDeploy = outcome.ply !== undefined && outcome.ply <= DEPLOY_PHASE_MOVES;

    // 落子/布局落子脉冲特效
    if (!outcome.passed && outcome.placed) {
      if (wasDeploy) {
        this.boardCanvas.playDeployPlace(outcome.placed, outcome.moverColor as Color);
      } else {
        this.boardCanvas.playMove(outcome.placed, outcome.moverColor as Color);
      }
    }

    // 提子特效（上升渐大淡出 + 震波扩散）
    if (outcome.captures && outcome.captures.length > 0) {
      // 被吃棋子 = 落子方的对色
      const capturedColor =
        outcome.moverColor === Color.BLACK ? Color.WHITE : Color.BLACK;
      this.boardCanvas.playCapture(outcome.captures, capturedColor);
    }

    // 围空/围困变化特效
    this._triggerBoardStateEffects();

    // 切换计时方（读秒制裁去每手加时，不再累加时间）
    if (!this.gameOver) this.timerActive = this.session.toMove;

    // 记录得分日志（按方记录本方总分变化）
    this._appendLogEntry(outcome);

    this._refresh();

    // 布局→正式对局过渡：播放开局动画
    if (wasDeploy && !this.session.isInDeployPhase()) {
      this.boardCanvas.setDeployPhase(false);
      this.boardCanvas.playOpeningAnimation();
      this._showToast(t("battleStart"), 2000);
    }

    // 终局
    if (outcome.gameOver && outcome.result) {
      this._endGame(outcome.result);
      return;
    }

    // 轮到 AI 则调度其行棋
    this._maybeScheduleAI();
  }

  // 缓存当前围空/围困状态（特效对比基准）
  private _cacheBoardState(): void {
    this.prevEnclosures = this.session.enclosures();
    const sieged = this.session.siegedGroups();
    this.prevSieged = new Set();
    for (const g of sieged) {
      for (const s of g.stones) this.prevSieged.add(s.row * BOARD_SIZE + s.col);
    }
  }

  // 对比落子前后围空/围困变化，触发对应特效（参考原项目 GameScreen._on_scores_updated 逻辑）
  private _triggerBoardStateEffects(): void {
    // 战争迷雾下不播放围空/围困特效，避免泄露视野外信息（仅更新基准）
    if (this.session.isFogActive()) {
      this._cacheBoardState();
      return;
    }
    const toPoints = (idxs: number[]) =>
      idxs.map((i) => ({ row: Math.floor(i / BOARD_SIZE), col: i % BOARD_SIZE }));
    const newEncs = this.session.enclosures();
    // 围空变化：新增 → formed；消失 → lost
    for (const c of [Color.BLACK, Color.WHITE]) {
      const prevPts = new Set(
        this.prevEnclosures.filter((e) => e.color === c).flatMap((e) => e.points.map((p) => p.row * BOARD_SIZE + p.col))
      );
      const newPts = new Set(
        newEncs.filter((e) => e.color === c).flatMap((e) => e.points.map((p) => p.row * BOARD_SIZE + p.col))
      );
      const gained = [...newPts].filter((i) => !prevPts.has(i));
      const lost = [...prevPts].filter((i) => !newPts.has(i));
      if (gained.length > 0) this.boardCanvas.playTerritoryFormed(toPoints(gained), c);
      if (lost.length > 0) this.boardCanvas.playTerritoryLost(toPoints(lost), c);
    }
    // 围困变化：新增 → siege；解除 → siege_broken
    const newSieged = this.session.siegedGroups();
    const newSet = new Set<number>();
    for (const g of newSieged) {
      for (const s of g.stones) newSet.add(s.row * BOARD_SIZE + s.col);
    }
    const siegeGained = [...newSet].filter((i) => !this.prevSieged.has(i));
    const siegeLost = [...this.prevSieged].filter((i) => !newSet.has(i));
    if (siegeGained.length > 0) this.boardCanvas.playSiege(toPoints(siegeGained));
    if (siegeLost.length > 0) this.boardCanvas.playSiegeBroken(toPoints(siegeLost));

    // 更新缓存
    this._cacheBoardState();
  }

  private _appendLogEntry(outcome: MoveOutcome): void {
    const moverColor = (outcome.moverColor ?? this.session.toMove) as number;
    const scores = this.session.scores();
    const mySide = moverColor === Color.BLACK ? "black" : "white";
    const myScore = this._calcTotal(scores[mySide]);
    // 上一手本方总分（用于显示 0→1(+1)）
    const prevEntry = [...this.logEntries].reverse().find((e) => e.color === moverColor);
    const scoreBefore = prevEntry ? prevEntry.scoreAfter : 0;

    const action: ScoreLogEntry["action"] = outcome.passed ? "pass" : "move";
    const entry: ScoreLogEntry = {
      ply: outcome.ply ?? this.session.ply,
      color: moverColor,
      action,
      pos: outcome.placed && outcome.placed.row >= 0 ? outcome.placed : undefined,
      captures: outcome.captures?.length ?? 0,
      scoreBefore,
      scoreAfter: myScore,
    };
    this.logEntries.push(entry);
  }

  private _refresh(): void {
    // 战争迷雾：以当前行棋方视角过滤可见信息；迷雾下隐藏围空/围困渲染避免信息泄露
    const fogActive = this.session.isFogActive();
    const viewColor = this.session.toMove;
    const boardGrid = fogActive ? this.session.visibleGridOf(viewColor) : this.session.board.grid;
    const fogCells = fogActive ? this.session.fogCellsOf(viewColor) : undefined;
    const viewEnclosures = fogActive ? [] : this.session.enclosures();
    const viewSieged = fogActive ? [] : this.session.siegedGroups();

    // 棋盘
    this.boardCanvas.updateState(
      boardGrid,
      this._getLastMove(),
      viewEnclosures,
      viewSieged,
      this.session.toMove,
      fogCells,
      fogActive
    );

    // 得分板
    const scores = this.session.scores();
    const isActive = (c: Color) => this.session.toMove === c && !this.gameOver;
    const bt = this._calcTotal(scores.black);
    const wt = this._calcTotal(scores.white);
    this._updatePanel(this.blackPanel, "black", bt, scores.black, isActive(Color.BLACK), wt);
    this._updatePanel(this.whitePanel, "white", wt, scores.white, isActive(Color.WHITE), bt);

    // 日志推送给双方得分板（按方过滤）
    this.blackPanel.setLogEntries(this.logEntries);
    this.whitePanel.setLogEntries(this.logEntries);

    // 状态栏 + 布局横幅
    const aiTurn = this._isAiTurn();
    const moverKey = this.session.toMove === Color.BLACK ? "mover.black" : "mover.white";
    const mover = t(moverKey);
    if (this.gameOver) {
      this.statusEl.textContent = t("gameEnded");
      this.deployBannerEl.style.display = "none";
    } else if (this.session.isInDeployPhase()) {
      const left = DEPLOY_PHASE_MOVES - this.session.ply;
      const deploySec = this.deployTimer[this.session.toMove === Color.BLACK ? "black" : "white"];
      this.statusEl.textContent = aiTurn
        ? tpl("aiDeployLeft", left)
        : tpl("deployLeft", mover, left);
      this.deployBannerEl.style.display = "block";
      this.deployBannerEl.textContent = aiTurn
        ? tpl("aiDeployTurn", deploySec)
        : tpl("deployTurn", mover, "", deploySec);
    } else {
      const exhausted = this.session.piecesLeft(this.session.toMove) <= 0;
      if (exhausted) {
        // 棋子用尽：虚手不限次、无冷却
        this.statusEl.textContent = aiTurn ? t("aiThinking") : tpl("turnExhausted", mover);
      } else {
        const passLeft = PASS_LIMIT_PER_GAME - (this.session.passCounts.get(this.session.toMove) ?? 0);
        this.statusEl.textContent = aiTurn
          ? t("aiThinking")
          : tpl("turn", mover, this.session.piecesLeft(this.session.toMove), passLeft);
      }
      this.deployBannerEl.style.display = "none";
    }

    // 按钮状态
    this.passBtn.disabled = this.gameOver || aiTurn;
    this.undoBtn.disabled = !this.session.canUndo() || aiTurn;
    this.resignBtn.disabled = this.gameOver || aiTurn;
  }

  private _updatePanel(panel: ScorePanel, side: "black" | "white", total: number, b: ScoreBreakdown, isActive: boolean, opponentTotal: number): void {
    const inDeploy = this.session.isInDeployPhase();
    const timerSec = inDeploy ? this.deployTimer[side] : this.timer[side].main;
    const timerMax = inDeploy ? DEPLOY_TIMER_SEC : TIMER_BASE_SEC;
    const tsp = this.timer[side];
    panel.update({
      breakdown: b,
      total,
      opponentTotal,
      isActive,
      timerSec,
      timerMax,
      inByoyomi: !inDeploy && tsp.inByoyomi,
      byoRemaining: tsp.byoRemaining,
      byoCur: tsp.byoCur,
      isLowTime: (inDeploy ? this.deployTimer[side] : tsp.main) <= 10 && isActive,
      gameOver: this.gameOver,
      piecesLeft: this.session.piecesLeft(side === "black" ? Color.BLACK : Color.WHITE),
      pieceLimit: this.session.pieceLimit,
      roleName: "",
    });
  }

  private _getLastMove(): { row: number; col: number } | null {
    const o = this.session.lastOutcome as MoveOutcome | null;
    if (o && o.placed && o.placed.row >= 0) return o.placed;
    return null;
  }

  // ====== 计时器 ======
  private _startTimer(): void {
    this._stopTimer();
    this.timerInterval = window.setInterval(() => this._tickTimer(), 1000);
  }

  private _stopTimer(): void {
    if (this.timerInterval !== null) {
      clearInterval(this.timerInterval);
      this.timerInterval = null;
    }
  }

  private _tickTimer(): void {
    if (this.gameOver) return;
    const side = this.timerActive === Color.BLACK ? "black" : "white";

    // 布局阶段：扣布局计时器
    if (this.session.isInDeployPhase()) {
      const dt = this.deployTimer[side];
      if (dt <= 0) {
        // 布局时间耗尽：自动在己方领土内随机布子
        this._autoDeploy(this.timerActive);
        return;
      }
      this.deployTimer[side] = dt - 1;
    } else {
      // 正式阶段：读秒制（主时耗尽进读秒，读秒连续倒数、落子不重置，读秒用尽判负）
      const st = this.timer[side];
      if (!st.inByoyomi) {
        st.main -= 1;
        if (st.main <= 0) {
          st.main = 0;
          if (BYO_COUNT > 0) {
            // 主时耗尽 → 进入读秒，不立即判负
            st.inByoyomi = true;
            st.byoRemaining = BYO_COUNT;
            st.byoCur = BYO_PERIOD_SEC;
          } else {
            this._timeoutLoss();
            return;
          }
        }
      } else {
        st.byoCur -= 1;
        if (st.byoCur <= 0) {
          st.byoCur = BYO_PERIOD_SEC;
          st.byoRemaining -= 1;
          if (st.byoRemaining < 0) {
            st.byoCur = 0;
            st.byoRemaining = 0;
            this._timeoutLoss();
            return;
          }
        }
      }
    }

    // 仅更新计时显示（不重渲染全盘）
    const scores = this.session.scores();
    const isActive = (c: Color) => this.session.toMove === c && !this.gameOver;
    const bt = this._calcTotal(scores.black);
    const wt = this._calcTotal(scores.white);
    this._updatePanel(this.blackPanel, "black", bt, scores.black, isActive(Color.BLACK), wt);
    this._updatePanel(this.whitePanel, "white", wt, scores.white, isActive(Color.WHITE), bt);
  }

  // 读秒用尽超时判负
  private _timeoutLoss(): void {
    if (this.gameOver) return;
    const winner = opponent(this.timerActive);
    const result = this.session.resign(this.timerActive).result;
    if (result) {
      result.winner = tpl("win", t(winner === Color.BLACK ? "black" : "white"));
      result.winnerColor = winner;
      result.reason = "超时判负";
      this._endGame(result);
    }
  }

  private _freshTimer(): SideTimer {
    return {
      main: TIMER_BASE_SEC,
      inByoyomi: false,
      byoRemaining: BYO_COUNT,
      byoCur: BYO_PERIOD_SEC,
    };
  }

  // 布局阶段时间耗尽：AI 方由其引擎决策，人类方随机落子
  private _autoDeploy(color: Color): void {
    if (color === this.aiColor) {
      this._maybeScheduleAI();
      return;
    }
    const rowStart = color === Color.BLACK ? 0 : 10;
    const rowEnd = color === Color.BLACK ? 9 : 19;
    const empties: { row: number; col: number }[] = [];
    for (let r = rowStart; r < rowEnd; r++) {
      for (let c = 0; c < BOARD_SIZE; c++) {
        if (this.session.board.isEmpty(r, c)) {
          empties.push({ row: r, col: c });
        }
      }
    }
    if (empties.length === 0) return;
    const pick = empties[Math.floor(Math.random() * empties.length)];
    const outcome = this.session.playMove(color, pick.row, pick.col);
    if (outcome.ok) {
      const sideName = color === Color.BLACK ? t("mover.black") : t("mover.white");
      this._showToast(tpl("autoDeploy", sideName), 2000);
      this._onMoveCommitted(outcome);
    }
  }

  private _calcTotal(b: ScoreBreakdown): number {
    return b.occupationTerritory + b.occupationEfficiency + b.defenseAnnihilate + b.defenseSiege + b.casualtyLoss + b.casualtySpecial;
  }

  // ====== 终局 ======
  private _endGame(result: FinalResult): void {
    this.gameOver = true;
    this._stopTimer();
    this._refresh();
    this._showResultModal(result);
  }

  private _showResultModal(result: FinalResult): void {
    const modal = document.createElement("div");
    modal.className = "modal-overlay";
    const winnerClass = result.winnerColor === Color.BLACK ? "black-win" : "white-win";
    const winnerName = result.winnerColor === Color.BLACK ? t("black") : t("white");
    modal.innerHTML = `
      <div class="modal result-modal">
        <h2>${t("result.title")}</h2>
        <div class="winner ${winnerClass}">${tpl("win", winnerName)}</div>
        <div class="reason">${this._escape(this._localizeReason(result.reason))}</div>
        <table class="result-table">
          <thead>
            <tr><th>${t("result.item")}</th><th>${t("black")}</th><th>${t("white")}</th></tr>
          </thead>
          <tbody>
            <tr><td class="label">${t("result.territory")}</td><td>${result.black.breakdown.occupationTerritory}</td><td>${result.white.breakdown.occupationTerritory}</td></tr>
            <tr><td class="label">${t("result.efficiency")}</td><td>${result.black.breakdown.occupationEfficiency}</td><td>${result.white.breakdown.occupationEfficiency}</td></tr>
            <tr><td class="label">${t("result.annihilate")}</td><td>${result.black.breakdown.defenseAnnihilate}</td><td>${result.white.breakdown.defenseAnnihilate}</td></tr>
            <tr><td class="label">${t("result.siege")}</td><td>${result.black.breakdown.defenseSiege}</td><td>${result.white.breakdown.defenseSiege}</td></tr>
            <tr><td class="label">${t("result.casualty")}</td><td>${result.black.breakdown.casualtyLoss + result.black.breakdown.casualtySpecial}</td><td>${result.white.breakdown.casualtyLoss + result.white.breakdown.casualtySpecial}</td></tr>
            <tr><td class="label">${t("result.komi")}</td><td>-${result.black.komi}</td><td>0</td></tr>
            <tr><td class="label">${t("finalScore")}</td><td class="final">${result.black.final}</td><td class="final">${result.white.final}</td></tr>
          </tbody>
        </table>
        <div class="modal-actions">
          <button class="btn btn-primary" id="modal-new">${t("result.new")}</button>
          <button class="btn" id="modal-close">${t("close")}</button>
        </div>
      </div>
    `;
    document.body.appendChild(modal);
    modal.querySelector("#modal-new")!.addEventListener("click", () => {
      modal.remove();
      this._onNewGame();
    });
    modal.querySelector("#modal-close")!.addEventListener("click", () => {
      modal.remove();
    });
  }

  // ====== AI 对手 ======
  private _isAiTurn(): boolean {
    return this.aiColor !== null && !this.gameOver && this.session.toMove === this.aiColor;
  }

  private _maybeScheduleAI(): void {
    if (this.aiTimeout !== null) return;
    if (!this._isAiTurn()) return;
    this.aiTimeout = window.setTimeout(() => {
      this.aiTimeout = null;
      this._runAI();
    }, 50);
  }

  private _runAI(): void {
    if (!this._isAiTurn()) return;
    this.statusEl.textContent = t("aiThinking");
    // 先让"思考中"状态渲染一帧，再执行耗时的搜索
    this.aiTimeout = window.setTimeout(() => {
      this.aiTimeout = null;
      this._computeAIMove();
    }, 16);
  }

  // 终局原因本地化（engine 原因中文，英文环境映射已知值）
  private _localizeReason(r: string): string {
    if (r.includes("认输")) return tpl("reason.resign", t(r.includes("黑") ? "black" : "white"));
    if (r.includes("兵力用尽")) return t("reason.piecesExhausted");
    if (r.includes("均无法落子")) return t("reason.bothStuck");
    if (r.includes("超时")) return t("timeoutLoss");
    if (r.includes("虚手")) return t("passEnd");
    if (r.includes("结束")) return t("gameEnded");
    return r;
  }

  private _computeAIMove(): void {
    if (!this._isAiTurn() || !this.aiEngine) return;
    const color = this.aiColor as Color;
    const move = this.aiEngine.chooseMove(this.session);
    if (!this._isAiTurn()) return; // 思考期间被悔棋/新局打断
    const outcome =
      move.type === "pass"
        ? this.session.doPass(color)
        : this.session.playMove(color, move.row, move.col);
    if (!outcome.ok) {
      this._fallbackAIMove(color);
      return;
    }
    this._onMoveCommitted(outcome);
  }

  // AI 首选落子被拒（劫/已占点等）时兜底：扫描合法空点，无则虚手
  private _fallbackAIMove(color: Color): void {
    const b = this.session.board;
    for (let r = 0; r < b.size; r++) {
      for (let c = 0; c < b.size; c++) {
        if (!b.isEmpty(r, c)) continue;
        const outcome = this.session.playMove(color, r, c);
        if (outcome.ok) {
          this._onMoveCommitted(outcome);
          return;
        }
      }
    }
    const pass = this.session.doPass(color);
    if (pass.ok) this._onMoveCommitted(pass);
  }

  // ====== 工具 ======
  private _showToast(msg: string, duration: number = 2000): void {
    const toast = document.createElement("div");
    toast.className = "toast";
    toast.textContent = msg;
    document.body.appendChild(toast);
    setTimeout(() => toast.remove(), duration);
  }

  private _escape(s: string): string {
    const div = document.createElement("div");
    div.textContent = s;
    return div.innerHTML;
  }
}
