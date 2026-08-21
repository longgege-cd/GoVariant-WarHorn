// 死活题闯关界面：30 关难度递增（真实死活题，含正解树），按正解序列判题
// 判定口径 =「正解序列匹配」：玩家按正解逐手落子，答错判错不落子需重试，走完完整正解才过关
// 交互：答对才可进入上一/下一题；无「跳过」；支持重来 / 提示；边玩边匹配对手

import { Color, LifeDeathPuzzle, buildPuzzleBoard, isCorrectNext, puzzleSolved, nextHintMoves } from "@warhorn/engine";
import { BoardModel } from "@warhorn/engine";
import { BoardCanvas } from "../BoardCanvas.js";
import { t, tpl } from "../i18n.js";

interface PuzzleCallbacks {
  playerName: string;
  onBack: () => void;
  /** 匹配对手按钮回调（由 main.ts 注入），返回取消匹配的函数 */
  attachMatch?: (playerName: string) => { disconnect: () => void };
}

export class LifeDeathGameScreen {
  readonly el: HTMLElement;
  private puzzles: LifeDeathPuzzle[];
  private idx: number = 0;
  private placed: Array<[number, number]> = []; // 玩家本关已落下的正确子
  private boardCanvas: BoardCanvas;
  private solved = false;

  // DOM
  private statusEl!: HTMLElement;
  private goalEl!: HTMLElement;
  private hintOverlay!: HTMLElement;
  private prevBtn!: HTMLButtonElement;
  private nextBtn!: HTMLButtonElement;
  private restartBtn!: HTMLButtonElement;
  private hintBtn!: HTMLButtonElement;

  constructor(puzzles: LifeDeathPuzzle[], private callbacks: PuzzleCallbacks) {
    this.puzzles = puzzles;
    this.boardCanvas = new BoardCanvas({ cellSize: 30, padding: 26 });
    this.el = this._build();
    this._bindBoard();
    this._render();
  }

  destroy(): void {
    this.boardCanvas.destroy();
  }

  private _build(): HTMLElement {
    const root = document.createElement("div");
    root.className = "screen game-screen";
    root.innerHTML = `
      <div class="side-panel side-left" id="pzl-info">
        <div class="pzl-progress-card">
          <div class="pzl-progress-label">${t("puzzle.progress")}</div>
          <div class="pzl-progress-value" id="pzl-progress"></div>
        </div>
        <div class="pzl-type-card">
          <div class="pzl-type" id="pzl-type">${t("puzzle.type")}</div>
          <div class="pzl-diff" id="pzl-diff"></div>
        </div>
        <div class="pzl-goal" id="pzl-goal"></div>
      </div>
      <div class="game-main">
        <div class="game-topbar">
          <span class="topbar-title" id="pzl-title"></span>
          <span class="topbar-status" id="status"></span>
        </div>
        <div class="board-wrapper">
          <div class="board-container" id="board-container">
            <div class="pzl-hint-overlay" id="pzl-hint"></div>
          </div>
        </div>
        <div class="game-controls">
          <button class="btn" id="btn-prev">${t("puzzle.prev")}</button>
          <button class="btn" id="btn-restart">${t("puzzle.restart")}</button>
          <button class="btn" id="btn-hint">${t("puzzle.hint")}</button>
          <button class="btn primary" id="btn-next">${t("puzzle.next")}</button>
        </div>
        <div class="pzl-match-row">
          <button class="btn match-opponent-btn" id="pzl-match">${t("matchOpponent")}</button>
          <span class="match-status-card hidden" id="pzl-match-status">${t("matchingWait")}</span>
        </div>
      </div>
      <div class="side-panel side-right">
        <div class="back-btn-row">
          <button class="btn" id="btn-back">${t("back")}</button>
        </div>
      </div>
    `;
    const bc = root.querySelector("#board-container") as HTMLElement;
    bc.insertBefore(this.boardCanvas.canvas, bc.firstChild);
    bc.style.position = "relative";

    this.statusEl = root.querySelector("#status")!;
    this.goalEl = root.querySelector("#pzl-goal")!;
    this.hintOverlay = root.querySelector("#pzl-hint") as HTMLElement;
    this.prevBtn = root.querySelector("#btn-prev") as HTMLButtonElement;
    this.nextBtn = root.querySelector("#btn-next") as HTMLButtonElement;
    this.restartBtn = root.querySelector("#btn-restart") as HTMLButtonElement;
    this.hintBtn = root.querySelector("#btn-hint") as HTMLButtonElement;

    root.querySelector("#btn-prev")!.addEventListener("click", () => this._goto(this.idx - 1));
    root.querySelector("#btn-next")!.addEventListener("click", () => this._goto(this.idx + 1));
    root.querySelector("#btn-restart")!.addEventListener("click", () => this._restart());
    root.querySelector("#btn-hint")!.addEventListener("click", () => this._showHint());
    root.querySelector("#btn-back")!.addEventListener("click", () => this._onBack());

    // 匹配对手（边玩边匹配）
    const matchBtn = root.querySelector("#pzl-match") as HTMLButtonElement;
    const matchStatus = root.querySelector("#pzl-match-status") as HTMLElement;
    let matching = false;
    let cancelMatch: { disconnect: () => void } | null = null;
    matchBtn.addEventListener("click", () => {
      if (matching) {
        cancelMatch?.disconnect();
        cancelMatch = null;
        matching = false;
        matchStatus.classList.add("hidden");
        matchBtn.textContent = t("matchOpponent");
        return;
      }
      if (this.callbacks.attachMatch) {
        matching = true;
        matchStatus.classList.remove("hidden");
        matchBtn.textContent = t("matchingCancel");
        cancelMatch = this.callbacks.attachMatch(this.callbacks.playerName);
        // 匹配成功/失败/断线后 UI 复位由 main.ts 回调处理
      } else {
        matchStatus.textContent = t("connFailed");
        matchStatus.classList.remove("hidden");
      }
    });

    return root;
  }

  private _onBack(): void {
    if (confirm(t("backMenu"))) {
      this.callbacks.onBack();
    }
  }

  private _bindBoard(): void {
    this.boardCanvas.onCellClick = (row, col) => this._onCellClick(row, col);
  }

  private _onCellClick(row: number, col: number): void {
    if (this.solved) return;
    if (this._occupied(row, col)) return;
    const p = this._puzzle();
    // 答对下一步 → 保留该子
    if (isCorrectNext(p, this.placed, [row, col])) {
      this.statusEl.classList.remove("wrong");
      this.statusEl.classList.remove("solved");
      this.placed.push([row, col]);
      this._render();
      if (puzzleSolved(p, this.placed)) {
        this.solved = true;
        this.statusEl.textContent = t("puzzle.solved");
        this.statusEl.classList.add("solved");
        this.hintOverlay.innerHTML = "";
        this._renderButtons();
      } else {
        this.statusEl.textContent = tpl("puzzle.turn");
      }
    } else {
      // 答错 → 不落子，提示重试
      this.statusEl.textContent = t("puzzle.wrong");
      this.statusEl.classList.remove("solved");
      this.statusEl.classList.add("wrong");
    }
  }

  private _occupied(row: number, col: number): boolean {
    return this._board().grid[row * 19 + col] !== Color.EMPTY;
  }

  private _puzzle(): LifeDeathPuzzle {
    return this.puzzles[this.idx];
  }

  private _board(): BoardModel {
    const b = buildPuzzleBoard(this._puzzle());
    for (const [r, c] of this.placed) b.setAt(r, c, this._puzzle().solver);
    return b;
  }

  private _showHint(): void {
    const p = this._puzzle();
    const hints = nextHintMoves(p, this.placed);
    if (hints.length === 0) {
      this.statusEl.textContent = t("puzzle.noHint");
      return;
    }
    const cs = 30, pad = 26;
    this.hintOverlay.innerHTML = "";
    for (const [r, c] of hints) {
      const dot = document.createElement("div");
      dot.className = "pzl-hint-dot solved-hint";
      dot.style.left = pad + c * cs + "px";
      dot.style.top = pad + r * cs + "px";
      this.hintOverlay.appendChild(dot);
    }
    this.statusEl.textContent = tpl("puzzle.hintCount", hints.length);
  }

  private _restart(): void {
    this.placed = [];
    this.solved = false;
    this.hintOverlay.innerHTML = "";
    this._render();
  }

  private _goto(i: number): void {
    if (i < 0 || i >= this.puzzles.length) return;
    if (!this.solved) return; // 答对才能进入上/下一题
    this.idx = i;
    this.placed = [];
    this.solved = false;
    this.hintOverlay.innerHTML = "";
    this._render();
  }

  private _renderButtons(): void {
    this.prevBtn.disabled = this.idx <= 0 || !this.solved;
    this.nextBtn.disabled = this.idx >= this.puzzles.length - 1 || !this.solved;
    this.hintBtn.disabled = this.solved;
    this.restartBtn.disabled = this.placed.length === 0 && !this.solved;
  }

  private _render(): void {
    const p = this._puzzle();
    // 标题
    const titleEl = this.el.querySelector("#pzl-title")!;
    titleEl.textContent = tpl("puzzle.title", p.id, this.puzzles.length);
    // 进度
    this.el.querySelector("#pzl-progress")!.textContent = `${p.id}/${this.puzzles.length}`;
    // 难度 + 来源
    const diffKey = p.level === 1 ? "ai.easy" : p.level === 2 ? "ai.normal" : p.level === 3 ? "ai.hard" : "ai.master";
    this.el.querySelector("#pzl-diff")!.textContent = `${t("puzzle.diff")}：${t(diffKey)}（${p.source}）`;
    // 执子颜色
    const colorZh = p.solver === Color.BLACK ? t("mover.black") : t("mover.white");
    this.el.querySelector("#pzl-type")!.textContent = colorZh;
    this.goalEl.textContent = tpl("puzzle.goal", colorZh);
    // 状态
    if (!this.solved && this.placed.length === 0) {
      this.statusEl.textContent = tpl("puzzle.turn");
      this.statusEl.classList.remove("wrong", "solved");
    }

    // 棋盘更新
    const b = this._board();
    const lastMove = this.placed.length > 0 ? { row: this.placed[this.placed.length - 1][0], col: this.placed[this.placed.length - 1][1] } : null;
    this.boardCanvas.updateState(
      b.grid,
      lastMove,
      [],
      [],
      p.solver,
      undefined,
      false
    );

    this._renderButtons();
  }
}