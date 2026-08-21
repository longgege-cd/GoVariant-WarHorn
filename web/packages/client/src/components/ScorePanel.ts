// 得分板组件：单方分数明细 + 兵力 + 行棋方高亮 + 得分日志
//
// 设计（移植自 Godot 项目 ScorePanel.gd，适配 WEB DOM/CSS）：
//   5 个竖向模块：
//     模块0：水平计时条（行棋方流光 + 低时间呼吸灯 + 时间数字）
//     模块1：身份名片（头像+名称+兵力）
//     模块2：总分焦点（大字居中 + 变化闪烁）
//     模块3：得分构成分数条（占领/防御/战损 三条进度条）
//     模块4：得分日志（折叠/展开标题 + 滚动列表，默认展开）
//   日志格式：`  1. 落子   K10     0→1(+1)`
//   得分变化着色：正=亮金，负=战争红
//   行棋方高亮：呼吸边框 + 背景叠加

import type { ScoreSide, ScoreBreakdown } from "@warhorn/shared";
import { t, tpl } from "../i18n.js";

export type PanelSide = "black" | "white";

// 得分日志条目（双方共用，ScorePanel 按 side 过滤）
export interface ScoreLogEntry {
  ply: number;
  color: number; // 1=BLACK, 2=WHITE
  action: "move" | "pass" | "deploy" | "bounce";
  pos?: { row: number; col: number };
  captures: number;
  scoreBefore: number; // 本方该手前总分
  scoreAfter: number; // 本方该手后总分
}

interface PanelState {
  breakdown: ScoreBreakdown;
  total: number;
  opponentTotal: number; // 对方总分（领先/落后状态判定）
  isActive: boolean;
  timerSec: number;
  timerMax: number; // 用于进度条比例
  inByoyomi: boolean; // 是否在读秒
  byoRemaining: number; // 剩余读秒次数
  byoCur: number; // 当前读秒剩余（秒）
  isLowTime: boolean;
  gameOver: boolean;
  piecesLeft: number;
  pieceLimit: number;
  roleName: string;
}

const COLS = "ABCDEFGHJKLMNOPQRST";
const BOARD_SIZE = 19;

export class ScorePanel {
  readonly el: HTMLElement;
  private readonly side: PanelSide;
  private sideNum: number; // 1=BLACK, 2=WHITE

  // DOM 引用
  private timerBarFill!: HTMLElement;
  private timerText!: HTMLElement;
  private avatarEl!: HTMLElement;
  private nameEl!: HTMLElement;
  private piecesEl!: HTMLElement;
  private totalEl!: HTMLElement;
  private totalFlashEl!: HTMLElement;
  private barOccFill!: HTMLElement;
  private barOccVal!: HTMLElement;
  private barDefFill!: HTMLElement;
  private barDefVal!: HTMLElement;
  private barCasFill!: HTMLElement;
  private barCasVal!: HTMLElement;
  private logTitleBtn!: HTMLButtonElement;
  private logListEl!: HTMLElement;
  private logScrollEl!: HTMLElement;

  // 状态
  private logEntries: ScoreLogEntry[] = [];
  private logExpanded = true;
  private displayTotal = 0; // 数字滚动动画当前值
  private targetTotal = 0; // 总分目标值（独立存储，避免动画循环自读自写导致目标值漂移）
  private flashAmount = 0; // 总分闪烁强度 0~1
  private flashColor = "transparent";
  private animFrame: number | null = null;
  private _destroyed = false;

  constructor(side: PanelSide) {
    this.side = side;
    this.sideNum = side === "black" ? 1 : 2;
    this.el = this._build();
    this._startAnimLoop();
  }

  destroy(): void {
    this._destroyed = true;
    if (this.animFrame !== null) cancelAnimationFrame(this.animFrame);
  }

  private _build(): HTMLElement {
    const root = document.createElement("div");
    root.className = `score-panel score-panel-${this.side}`;
    root.innerHTML = `
      <div class="sp-timer-bar">
        <div class="sp-timer-fill"></div>
        <div class="sp-timer-text">10:00</div>
      </div>
      <div class="sp-section sp-identity">
        <div class="sp-avatar"></div>
        <div class="sp-id-text">
          <div class="sp-name">${t(this.side === "black" ? "black" : "white")}</div>
          <div class="sp-pieces">${tpl("pieces", 120, 120)}</div>
        </div>
      </div>
      <div class="sp-sep"></div>
      <div class="sp-section sp-total-section">
        <div class="sp-total-label">${t("total")}</div>
        <div class="sp-total-wrap">
          <span class="sp-total">0</span>
          <span class="sp-total-flash"></span>
        </div>
      </div>
      <div class="sp-sep"></div>
      <div class="sp-section sp-bars">
        <div class="sp-bar-row">
          <span class="sp-bar-name" title="${t("occupation")}"><svg class="ic-occ" viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"><path d="M8 1.6 L5.2 4.8 L8 3.9 L10.8 4.8 Z"/><line x1="8" y1="3.6" x2="8" y2="13"/><line x1="6.3" y1="13" x2="9.7" y2="13"/></svg></span>
          <div class="sp-bar-track"><div class="sp-bar-fill sp-bar-occ"></div></div>
          <span class="sp-bar-val sp-val-occ">0</span>
        </div>
        <div class="sp-bar-row">
          <span class="sp-bar-name" title="${t("defense")}"><svg class="ic-def" viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"><path d="M8 1.5 L13.5 3.2 V8 C13.5 11.4 11.2 13.7 8 14.5 C4.8 13.7 2.5 11.4 2.5 8 V3.2 Z"/></svg></span>
          <div class="sp-bar-track"><div class="sp-bar-fill sp-bar-def"></div></div>
          <span class="sp-bar-val sp-val-def">0</span>
        </div>
        <div class="sp-bar-row">
          <span class="sp-bar-name" title="${t("casualty")}"><svg class="ic-cas" viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round"><path d="M8 1.8 C8 1.8 3 7.4 3 10.4 A5 5 0 0 0 13 10.4 C13 7.4 8 1.8 8 1.8 Z"/></svg></span>
          <div class="sp-bar-track"><div class="sp-bar-fill sp-bar-cas"></div></div>
          <span class="sp-bar-val sp-val-cas">0</span>
        </div>
      </div>
      <div class="sp-sep"></div>
      <div class="sp-section sp-log">
        <button class="sp-log-title">▾ ${t("scoreLog")}</button>
        <div class="sp-log-scroll">
          <div class="sp-log-list"></div>
        </div>
      </div>
    `;

    this.timerBarFill = root.querySelector(".sp-timer-fill")!;
    this.timerText = root.querySelector(".sp-timer-text")!;
    this.avatarEl = root.querySelector(".sp-avatar")!;
    this.nameEl = root.querySelector(".sp-name")!;
    this.piecesEl = root.querySelector(".sp-pieces")!;
    this.totalEl = root.querySelector(".sp-total")!;
    this.totalFlashEl = root.querySelector(".sp-total-flash")!;
    this.barOccFill = root.querySelector(".sp-bar-occ")!;
    this.barOccVal = root.querySelector(".sp-val-occ")!;
    this.barDefFill = root.querySelector(".sp-bar-def")!;
    this.barDefVal = root.querySelector(".sp-val-def")!;
    this.barCasFill = root.querySelector(".sp-bar-cas")!;
    this.barCasVal = root.querySelector(".sp-val-cas")!;
    this.logTitleBtn = root.querySelector(".sp-log-title")!;
    this.logListEl = root.querySelector(".sp-log-list")!;
    this.logScrollEl = root.querySelector(".sp-log-scroll")!;

    this.logTitleBtn.addEventListener("click", () => this._toggleLog());

    return root;
  }

  /** 更新分数/计时/状态 */
  update(state: PanelState): void {
    const b = state.breakdown;
    const occ = b.occupationTerritory + b.occupationEfficiency;
    const def = b.defenseAnnihilate + b.defenseSiege;
    const cas = Math.abs(b.casualtyLoss + b.casualtySpecial);

    // 总分闪烁判定
    const newTotal = state.total;
    const delta = newTotal - this.displayTotal;
    if (Math.abs(delta) >= 1) {
      this.flashAmount = 1.0;
      this.flashColor = this._determineFlashColor(b, delta);
    }

    // 总分目标值存入 targetTotal，由动画循环逼近写入 totalEl
    this.targetTotal = newTotal;

    // 领先/落后状态：领先≥5 → 彩虹色；落后≥5 → 呼吸
    const lead = state.total - state.opponentTotal;
    this.totalEl.classList.toggle("rainbow", lead >= 5);
    this.totalEl.classList.toggle("breathe", lead <= -5);

    // 身份名片
    this.nameEl.textContent = state.roleName || t(this.side === "black" ? "black" : "white");
    this.piecesEl.textContent = tpl("pieces", state.piecesLeft, state.pieceLimit);

    // 分数条（基准：占领80, 防御40, 战损30）
    this._setBar(this.barOccFill, this.barOccVal, occ, 80, false);
    this._setBar(this.barDefFill, this.barDefVal, def, 40, false);
    this._setBar(this.barCasFill, this.barCasVal, cas, 30, true); // 战损显示负数

    // 计时条：读秒阶段显示读秒次数+当前剩余（进度全满/高亮），否则显示主时进度
    if (state.inByoyomi) {
      this.timerBarFill.style.width = "100%";
      this.timerText.textContent = `${t("byo")}${state.byoRemaining} ${this._formatTime(state.byoCur)}`;
      this.timerBarFill.classList.add("low");
      this.timerText.classList.add("low");
    } else {
      const ratio = state.timerMax > 0 ? Math.max(0, Math.min(1, state.timerSec / state.timerMax)) : 0;
      this.timerBarFill.style.width = `${ratio * 100}%`;
      this.timerText.textContent = this._formatTime(state.timerSec);
      this.timerText.classList.toggle("low", state.isLowTime);
    }
    this.timerBarFill.classList.toggle("low", state.inByoyomi || state.isLowTime);
    this.timerBarFill.classList.toggle("active", state.isActive);

    // 行棋方高亮
    this.el.classList.toggle("active", state.isActive);
    this.el.classList.toggle("game-over", state.gameOver);
  }

  /** 注入完整日志（双方所有条目，自动按 side 过滤） */
  setLogEntries(allEntries: ScoreLogEntry[]): void {
    this.logEntries = allEntries.filter((e) => e.color === this.sideNum);
    this._refreshLogView();
  }

  private _setBar(fill: HTMLElement, valEl: HTMLElement, value: number, max: number, isNegative: boolean): void {
    const ratio = Math.min(1, value / max);
    fill.style.width = `${ratio * 100}%`;
    if (isNegative && value > 0) {
      valEl.textContent = `-${value}`;
    } else {
      valEl.textContent = String(value);
    }
    valEl.classList.toggle("zero", value === 0);
  }

  private _determineFlashColor(b: ScoreBreakdown, delta: number): string {
    if (delta > 0) {
      const defDelta = b.defenseAnnihilate + b.defenseSiege;
      if (defDelta > 0) return "var(--sp-gold-bright)"; // 防御分 → 亮金
      return "var(--sp-warm-gold)"; // 占领分 → 暖金
    }
    if (delta < 0) return "var(--sp-red-war)"; // 战损 → 红
    return "transparent";
  }

  private _toggleLog(): void {
    this.logExpanded = !this.logExpanded;
    this._refreshLogView();
  }

  private _refreshLogView(): void {
    // 标题：▾/▸ + "得分日志" + 最新摘要
    let title = `${this.logExpanded ? "▾" : "▸"} ${t("scoreLog")}`;
    if (this.logEntries.length > 0) {
      const last = this.logEntries[this.logEntries.length - 1];
      const delta = last.scoreAfter - last.scoreBefore;
      const sign = delta >= 0 ? "+" : "";
      title += `  [#${last.ply} ${last.scoreAfter} (${sign}${delta})]`;
    }
    this.logTitleBtn.textContent = title;
    this.logScrollEl.style.display = this.logExpanded ? "block" : "none";
    if (!this.logExpanded) return;

    if (this.logEntries.length === 0) {
      this.logListEl.innerHTML = `<div class="sp-log-empty">${t("noLog")}</div>`;
      return;
    }
    const html = this.logEntries.map((e) => this._formatLogEntry(e)).join("");
    this.logListEl.innerHTML = html;
    // 滚动到底部
    this.logScrollEl.scrollTop = this.logScrollEl.scrollHeight;
  }

  private _formatLogEntry(e: ScoreLogEntry): string {
    const actionLabel = this._actionLabel(e.action);
    const posStr = this._posLabel(e);
    const capStr = e.captures > 0 ? tpl("log.capture", e.captures) : "  ";
    const delta = e.scoreAfter - e.scoreBefore;
    const sign = delta >= 0 ? "+" : "";
    const scoreStr = `${e.scoreBefore}→${e.scoreAfter}(${sign}${delta})`;
    const text = `${String(e.ply).padStart(3, " ")}. ${actionLabel.padEnd(4, " ")} ${posStr.padEnd(4, " ")} ${capStr.padEnd(4, " ")} ${scoreStr}`;
    let colorClass = "sp-log-neutral";
    if (delta > 0) colorClass = "sp-log-pos";
    else if (delta < 0) colorClass = "sp-log-neg";
    return `<div class="sp-log-item ${colorClass}">${this._escape(text)}</div>`;
  }

  private _actionLabel(action: ScoreLogEntry["action"]): string {
    switch (action) {
      case "pass": return t("log.pass");
      case "deploy": return t("log.deploy");
      case "bounce": return t("log.bounce");
      default: return t("log.move");
    }
  }

  private _posLabel(e: ScoreLogEntry): string {
    if (!e.pos || e.pos.row < 0) return "—";
    return `${COLS[e.pos.col]}${BOARD_SIZE - e.pos.row}`;
  }

  private _formatTime(sec: number): string {
    const s = Math.max(0, Math.floor(sec));
    const m = Math.floor(s / 60);
    const r = s % 60;
    return `${String(m).padStart(2, "0")}:${String(r).padStart(2, "0")}`;
  }

  // 数字滚动 + 闪烁衰减动画
  private _startAnimLoop(): void {
    const loop = () => {
      if (this._destroyed) return;
      // 数字滚动：displayTotal 逼近 targetTotal（独立存储，不从 DOM 回读）
      const target = this.targetTotal;
      if (Math.abs(this.displayTotal - target) > 0.5) {
        this.displayTotal += (target - this.displayTotal) * 0.25;
        this.totalEl.textContent = String(Math.round(this.displayTotal));
      } else {
        this.displayTotal = target;
        this.totalEl.textContent = String(target);
      }
      // 闪烁衰减
      if (this.flashAmount > 0) {
        this.flashAmount = Math.max(0, this.flashAmount - 0.04);
        this.totalFlashEl.style.opacity = String(this.flashAmount);
        this.totalFlashEl.style.color = this.flashColor;
        this.totalEl.style.transform = `scale(${1 + this.flashAmount * 0.12})`;
      } else if (this.totalEl.style.transform !== "") {
        this.totalEl.style.transform = "";
      }
      this.animFrame = requestAnimationFrame(loop);
    };
    this.animFrame = requestAnimationFrame(loop);
  }

  private _escape(s: string): string {
    const div = document.createElement("div");
    div.textContent = s;
    return div.innerHTML;
  }
}
