// 在线对局界面：通过 SocketClient 驱动，服务器为权威规则源
// 得分板按原项目 ScorePanel.gd 5模块结构实现

import {
  Color, BOARD_SIZE, DEPLOY_PHASE_MOVES,
  TerritoryDetector, SiegeDetector, BoardModel,
} from "@warhorn/engine";
import type { Enclosure, Group } from "@warhorn/engine";
import type {
  MoveOutcome, FinalResult, ScoreSide, ScoreBreakdown,
  GameStartPayload, GameUpdatePayload,
  ColorTimer,
  TimersState,
  GameOverPayload, TimeUpdatePayload,
} from "@warhorn/shared";
import { BoardCanvas } from "../BoardCanvas.js";
import type { SocketClient } from "../net/SocketClient.js";
import { t, tpl, tThemeName } from "../i18n.js";
import { ScorePanel, type ScoreLogEntry } from "../components/ScorePanel.js";

export class OnlineGameScreen {
  readonly el: HTMLElement;
  private readonly client: SocketClient;
  private readonly ownColor: Color;
  private readonly blackName: string;
  private readonly whiteName: string;

  private board: BoardModel;
  private boardCanvas: BoardCanvas;

  private readonly komi: number;
  private readonly pieceLimit: number;
  private currentTurn: Color = Color.BLACK;
  private timers: TimersState = { black: this._emptyTimer(), white: this._emptyTimer() };
  private timerMax: number = 600;
  private stonesPlaced: { black: number; white: number } = { black: 0, white: 0 };
  private cachedScores: { black: ScoreSide; white: ScoreSide } | null = null;
  private lastMove: { row: number; col: number } | null = null;
  private currentPly: number = 0;
  private gameOver: boolean = false;

  private logEntries: ScoreLogEntry[] = [];

  private blackPanel: ScorePanel;
  private whitePanel: ScorePanel;

  private statusEl!: HTMLElement;
  private deployBannerEl!: HTMLElement;
  private passBtn!: HTMLButtonElement;
  private resignBtn!: HTMLButtonElement;

  private _unbinds: Array<() => void> = [];

  constructor(client: SocketClient, payload: GameStartPayload) {
    this.client = client;
    this.ownColor = payload.ownColor as Color;
    this.blackName = payload.blackName;
    this.whiteName = payload.whiteName;
    this.board = new BoardModel(payload.initialState.size);
    this.board.grid = new Uint8Array(payload.initialState.grid);
    this.timerMax = payload.baseTimeSec;
    // 按开局参数初始化读秒制计时（服务器每秒广播覆盖）
    this.timers = {
      black: this._mkTimer(payload.baseTimeSec, payload.byoPeriodSec, payload.byoCount),
      white: this._mkTimer(payload.baseTimeSec, payload.byoPeriodSec, payload.byoCount),
    };
    this.komi = payload.komi;
    this.pieceLimit = payload.pieceLimit;

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
    this.el = this._build();
    this._bindBoard();
    this._bindSocketEvents();
    this._refresh();
  }

  destroy(): void {
    for (const unbind of this._unbinds) unbind();
    this._unbinds = [];
    this.boardCanvas.destroy();
    this.blackPanel.destroy();
    this.whitePanel.destroy();
  }

  private _build(): HTMLElement {
    const root = document.createElement("div");
    root.className = "screen game-screen";
    const topRole = this.ownColor === Color.BLACK ? t("black") : t("white");
    root.innerHTML = `
      <div class="side-panel side-left" id="panel-black"></div>
      <div class="game-main">
        <div class="game-topbar">
          <span class="topbar-title">${tpl("title.online", topRole, this.komi, this.pieceLimit)}</span>
          <span class="topbar-status" id="status"></span>
        </div>
        <div class="board-wrapper">
          <div class="board-container" id="board-container"></div>
          <div class="deploy-banner" id="deploy-banner">${t("deployBanner")}</div>
        </div>
        <div class="game-controls">
          <button class="btn" id="btn-pass">${t("pass")}</button>
          <button class="btn btn-danger" id="btn-resign">${t("resign")}</button>
          <button class="btn" id="btn-lobby">${t("backLobbyBtn")}</button>
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
    this.resignBtn = root.querySelector("#btn-resign")!;

    root.querySelector("#btn-pass")!.addEventListener("click", () => this._onPass());
    root.querySelector("#btn-resign")!.addEventListener("click", () => this._onResign());
    root.querySelector("#btn-lobby")!.addEventListener("click", () => this._onBackToLobby());

    return root;
  }

  private _bindBoard(): void {
    this.boardCanvas.onCellClick = (row, col) => this._onCellClick(row, col);
  }

  private _bindSocketEvents(): void {
    const prevUpdate = this.client.onGameUpdate;
    const prevOver = this.client.onGameOver;
    const prevTime = this.client.onTimeUpdate;
    const prevError = this.client.onError;

    this.client.onGameUpdate = (p: GameUpdatePayload) => this._onGameUpdate(p);
    this.client.onGameOver = (p: GameOverPayload) => this._onGameOver(p);
    this.client.onTimeUpdate = (p: TimeUpdatePayload) => this._onTimeUpdate(p);
    this.client.onError = (p) => this._showToast(p.message);

    this._unbinds.push(() => {
      this.client.onGameUpdate = prevUpdate;
      this.client.onGameOver = prevOver;
      this.client.onTimeUpdate = prevTime;
      this.client.onError = prevError;
    });
  }

  private _isMyTurn(): boolean {
    return !this.gameOver && this.currentTurn === this.ownColor;
  }

  private _onCellClick(row: number, col: number): void {
    if (!this._isMyTurn()) {
      if (!this.gameOver) this._showToast(t("waitOpponent"));
      return;
    }
    this.client.placeMove(row, col);
  }

  private _onPass(): void {
    if (!this._isMyTurn()) {
      if (!this.gameOver) this._showToast(t("waitOpponentMove"));
      return;
    }
    this.client.pass();
  }

  private _onResign(): void {
    if (this.gameOver) return;
    if (!confirm(t("resignConfirmOnline"))) return;
    this.client.resign();
  }

  private _onBackToLobby(): void {
    if (!this.gameOver) {
      if (!confirm(t("backLobby"))) return;
      this.client.resign();
    }
    window.location.reload();
  }

  private _emptyTimer(): ColorTimer {
    return { main: 0, inByoyomi: false, byoRemaining: 0, byoCur: 0 };
  }

  private _mkTimer(main: number, byoPeriod: number, byoCount: number): ColorTimer {
    return { main, inByoyomi: false, byoRemaining: byoCount, byoCur: byoPeriod };
  }

  private _onGameUpdate(p: GameUpdatePayload): void {
    // 更新前：计算旧状态（用于特效对比）
    const prevEncs = TerritoryDetector.enclosures(this.board);
    const prevSieged = this._siegedSet(SiegeDetector.solveDeadAlive(this.board).sieged);

    this.board = BoardModel.deserialize(p.board.size, p.board.grid);
    this.currentTurn = p.currentTurn as Color;
    this.timers = { black: p.timers.black, white: p.timers.white };
    this.cachedScores = p.scores;

    const o = p.outcome;
    if (o.ply !== undefined) this.currentPly = o.ply;

    // 虚手提示
    if (o.passed) {
      const mover = (o.moverColor ?? this.currentTurn) as Color;
      this._showToast(tpl("passed", t(mover === Color.BLACK ? "mover.black" : "mover.white")), 1500);
    }

    if (o.passed || !o.placed || o.placed.row < 0) {
      this.lastMove = null;
    } else {
      this.lastMove = { row: o.placed.row, col: o.placed.col };
    }

    if (!o.undid) {
      // 兵力计数（普通落子）
      if (!o.passed && o.placed && o.placed.row >= 0 && o.moverColor !== undefined) {
        const side = o.moverColor === Color.BLACK ? "black" : "white";
        this.stonesPlaced[side] += 1;
      }
      // 落子/布局落子脉冲特效
      if (!o.passed && o.placed && o.placed.row >= 0) {
        const isDeploy = o.ply !== undefined ? o.ply <= DEPLOY_PHASE_MOVES : this.currentPly <= DEPLOY_PHASE_MOVES;
        if (isDeploy) this.boardCanvas.playDeployPlace(o.placed, o.moverColor as Color);
        else this.boardCanvas.playMove(o.placed, o.moverColor as Color);
      }
      // 提子特效（上升渐大淡出 + 震波扩散）
      if (o.captures && o.captures.length > 0) {
        const capturedColor =
          o.moverColor === Color.BLACK ? Color.WHITE : Color.BLACK;
        this.boardCanvas.playCapture(o.captures, capturedColor);
      }
      // 围空/围困变化特效
      this._triggerBoardStateEffects(prevEncs, prevSieged);
      this._appendLogEntry(o, p.scores);
    }

    this._refresh(p.scores);

    // 布局→正式对局过渡：播放开局动画
    const wasDeploy = o.ply !== undefined ? o.ply <= DEPLOY_PHASE_MOVES : false;
    if (wasDeploy && this.currentPly >= DEPLOY_PHASE_MOVES) {
      this.boardCanvas.setDeployPhase(false);
      this.boardCanvas.playOpeningAnimation();
      this._showToast(t("battleStart"), 2000);
    }
  }

  private _siegedSet(groups: Group[]): Set<number> {
    const s = new Set<number>();
    for (const g of groups) {
      for (const st of g.stones) s.add(st.row * BOARD_SIZE + st.col);
    }
    return s;
  }

  // 对比围空/围困变化触发特效（参考原项目 GameScreen 逻辑）
  private _triggerBoardStateEffects(prevEncs: Enclosure[], prevSieged: Set<number>): void {
    const toPoints = (idxs: number[]) =>
      idxs.map((i) => ({ row: Math.floor(i / BOARD_SIZE), col: i % BOARD_SIZE }));
    const newEncs = TerritoryDetector.enclosures(this.board);
    for (const c of [Color.BLACK, Color.WHITE]) {
      const prevPts = new Set(
        prevEncs.filter((e) => e.color === c).flatMap((e) => e.points.map((p) => p.row * BOARD_SIZE + p.col))
      );
      const newPts = new Set(
        newEncs.filter((e) => e.color === c).flatMap((e) => e.points.map((p) => p.row * BOARD_SIZE + p.col))
      );
      const gained = [...newPts].filter((i) => !prevPts.has(i));
      const lost = [...prevPts].filter((i) => !newPts.has(i));
      if (gained.length > 0) this.boardCanvas.playTerritoryFormed(toPoints(gained), c);
      if (lost.length > 0) this.boardCanvas.playTerritoryLost(toPoints(lost), c);
    }
    const newSieged = this._siegedSet(SiegeDetector.solveDeadAlive(this.board).sieged);
    const siegeGained = [...newSieged].filter((i) => !prevSieged.has(i));
    const siegeLost = [...prevSieged].filter((i) => !newSieged.has(i));
    if (siegeGained.length > 0) this.boardCanvas.playSiege(toPoints(siegeGained));
    if (siegeLost.length > 0) this.boardCanvas.playSiegeBroken(toPoints(siegeLost));
  }

  private _onGameOver(p: GameOverPayload): void {
    this.gameOver = true;
    this._refresh(p.finalResult ? { black: p.finalResult.black, white: p.finalResult.white } : undefined);
    this._showResultModal(p.finalResult, p.reason);
  }

  private _onTimeUpdate(p: TimeUpdatePayload): void {
    this.timers = { black: p.black, white: p.white };
    // 用缓存的 scores 刷新计时条显示
    this._refresh(this.cachedScores ?? undefined);
  }

  private _appendLogEntry(o: MoveOutcome, scores: { black: ScoreSide; white: ScoreSide }): void {
    const moverColor = (o.moverColor ?? this.currentTurn) as number;
    const mySide = moverColor === Color.BLACK ? "black" : "white";
    const myScore = scores[mySide].total;
    const prevEntry = [...this.logEntries].reverse().find((e) => e.color === moverColor);
    const scoreBefore = prevEntry ? prevEntry.scoreAfter : 0;

    const action: ScoreLogEntry["action"] = o.passed ? "pass" : "move";
    this.logEntries.push({
      ply: o.ply ?? this.currentPly,
      color: moverColor,
      action,
      pos: o.placed && o.placed.row >= 0 ? o.placed : undefined,
      captures: o.captures?.length ?? 0,
      scoreBefore,
      scoreAfter: myScore,
    });
  }

  private _refresh(scores?: { black: ScoreSide; white: ScoreSide }): void {
    const enclosures = TerritoryDetector.enclosures(this.board);
    const sieged = SiegeDetector.solveDeadAlive(this.board).sieged;
    this.boardCanvas.updateState(
      this.board.grid,
      this.lastMove,
      enclosures,
      sieged,
      this.currentTurn
    );

    if (scores) {
      const isActive = (c: Color) => this.currentTurn === c && !this.gameOver;
      this._updatePanel(this.blackPanel, "black", scores.black.total, scores.black.breakdown, isActive(Color.BLACK), scores.white.total);
      this._updatePanel(this.whitePanel, "white", scores.white.total, scores.white.breakdown, isActive(Color.WHITE), scores.black.total);
      this.blackPanel.setLogEntries(this.logEntries);
      this.whitePanel.setLogEntries(this.logEntries);
    }

    if (this.gameOver) {
      this.statusEl.textContent = t("gameEnded");
      this.deployBannerEl.style.display = "none";
    } else if (this.currentPly < DEPLOY_PHASE_MOVES) {
      const mover = t(this.currentTurn === Color.BLACK ? "mover.black" : "mover.white");
      const left = DEPLOY_PHASE_MOVES - this.currentPly;
      const me = this.currentTurn === this.ownColor ? t("youMark") : "";
      const deploySec = this.timers[this.currentTurn === Color.BLACK ? "black" : "white"].main;
      this.statusEl.textContent = tpl("deployLeft", mover, left);
      this.deployBannerEl.style.display = "block";
      this.deployBannerEl.textContent = tpl("deployTurn", mover, me, deploySec);
    } else {
      const mover = t(this.currentTurn === Color.BLACK ? "mover.black" : "mover.white");
      const me = this.currentTurn === this.ownColor ? t("youMark") : t("oppMark");
      this.statusEl.textContent = tpl("turnOnline", mover, me);
      this.deployBannerEl.style.display = "none";
    }

    this.passBtn.disabled = !this._isMyTurn();
    this.resignBtn.disabled = this.gameOver;
  }

  private _updatePanel(panel: ScorePanel, side: "black" | "white", total: number, b: ScoreBreakdown, isActive: boolean, opponentTotal: number): void {
    const tsp = this.timers[side];
    panel.update({
      breakdown: b,
      total,
      opponentTotal,
      isActive,
      timerSec: tsp.main,
      timerMax: this.timerMax,
      inByoyomi: tsp.inByoyomi,
      byoRemaining: tsp.byoRemaining,
      byoCur: tsp.byoCur,
      isLowTime: tsp.main <= 10 && isActive,
      gameOver: this.gameOver,
      piecesLeft: Math.max(0, this.pieceLimit - this.stonesPlaced[side]),
      pieceLimit: this.pieceLimit,
      roleName: side === "black" ? this.blackName : this.whiteName,
    });
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

  private _showResultModal(result: FinalResult, reason: string): void {
    const modal = document.createElement("div");
    modal.className = "modal-overlay";
    const winnerClass = result.winnerColor === Color.BLACK ? "black-win" : "white-win";
    const winnerName = result.winnerColor === Color.BLACK ? t("black") : t("white");
    const iWon = result.winnerColor === this.ownColor;
    modal.innerHTML = `
      <div class="modal result-modal">
        <h2>${t("result.title")}</h2>
        <div class="winner ${winnerClass}">${tpl("win", winnerName)}${iWon ? t("youWin") : ""}</div>
        <div class="reason">${this._escape(this._localizeReason(reason))}</div>
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
          <button class="btn btn-primary" id="modal-lobby">${t("backLobbyBtn")}</button>
        </div>
      </div>
    `;
    document.body.appendChild(modal);
    modal.querySelector("#modal-lobby")!.addEventListener("click", () => {
      modal.remove();
      window.location.reload();
    });
  }

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
