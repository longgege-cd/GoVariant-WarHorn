// 计时系统：围棋比赛读秒制（byo-yomi）
// 主限时纯倒计时，耗尽后进入读秒 N 次；读秒连续倒数（落子不重置、不加时），读秒用尽判负。
// 对应桌面端 TimerSystem 读秒规则；替代原费舍尔(基础+每手加时)制，避免对局计时越走越多。

import { Color } from "./Const.js";

export interface TimerConfig {
  baseTime: number; // 主限时（秒），-1 = 无限（不进入读秒）
  byoPeriod: number; // 每次读秒秒数
  byoCount: number; // 读秒次数
}

export interface TimerState {
  main: number; // 剩余主时间
  inByoyomi: boolean; // 是否在读秒
  byoRemaining: number; // 剩余读秒次数
  byoCur: number; // 当前读秒剩余（秒）
}

interface PerColor {
  main: number;
  inByoyomi: boolean;
  byoRemaining: number;
  byoCur: number;
}

export class TimerSystem {
  private _config: TimerConfig;
  private _states: Map<Color, PerColor> = new Map();
  private _active: Color | null = null; // 当前行棋方
  private _paused: boolean = false;
  private _infinite: boolean;

  // 事件回调
  onTimeOut?: (color: Color) => void;
  onTimeChanged?: (color: Color) => void;

  constructor(config: TimerConfig) {
    this._config = config;
    this._infinite = config.baseTime === -1;
    this._states.set(Color.BLACK, this._fresh());
    this._states.set(Color.WHITE, this._fresh());
  }

  private _fresh(): PerColor {
    return {
      main: this._config.baseTime,
      inByoyomi: false,
      byoRemaining: this._config.byoCount,
      byoCur: this._config.byoPeriod,
    };
  }

  reset(config?: TimerConfig): void {
    if (config) {
      this._config = config;
      this._infinite = config.baseTime === -1;
    }
    this._states.set(Color.BLACK, this._fresh());
    this._states.set(Color.WHITE, this._fresh());
    this._active = null;
    this._paused = false;
  }

  // 切换行棋方：读秒制裁去每手加时，仅切换 active
  switchTo(color: Color): void {
    this._active = color;
  }

  // 每帧调用（dt 秒）
  tick(dt: number): void {
    if (this._paused || this._active === null) return;
    const st = this._states.get(this._active);
    if (!st) return;
    if (this._infinite) return; // 无限时间专用位（-1）
    if (!st.inByoyomi) {
      st.main -= dt;
      if (st.main <= 0) {
        st.main = 0;
        if (this._config.byoCount > 0) {
          // 主时耗尽 → 进入读秒（首个完整周期从 byoPeriod 起算），不立即判负
          st.inByoyomi = true;
          st.byoRemaining = this._config.byoCount;
          st.byoCur = this._config.byoPeriod;
          this.onTimeChanged?.(this._active);
        } else {
          this.onTimeOut?.(this._active);
        }
      } else {
        this.onTimeChanged?.(this._active);
      }
      return;
    }
    // 读秒阶段：连续倒数，不因落子重置
    st.byoCur -= dt;
    if (st.byoCur <= 0) {
      st.byoCur = this._config.byoPeriod;
      st.byoRemaining = st.byoRemaining - 1;
      if (st.byoRemaining < 0) {
        st.byoCur = 0;
        st.byoRemaining = 0;
        this.onTimeOut?.(this._active);
        return;
      }
    }
    this.onTimeChanged?.(this._active);
  }

  pause(): void { this._paused = true; }
  resume(): void { this._paused = false; }

  // 直接设置某方主时间并刷新读秒（布局→正式切换时重置）
  setTime(color: Color, time: number): void {
    const st = this._states.get(color);
    if (!st) return;
    st.main = time;
    st.inByoyomi = false;
    st.byoRemaining = this._config.byoCount;
    st.byoCur = this._config.byoPeriod;
  }

  getTime(color: Color): TimerState {
    const st = this._states.get(color) ?? this._fresh();
    return {
      main: Math.max(0, st.main),
      inByoyomi: st.inByoyomi,
      byoRemaining: Math.max(0, st.byoRemaining),
      byoCur: Math.max(0, st.byoCur),
    };
  }

  getProgress(color: Color): number {
    const st = this._states.get(color);
    if (!st || this._config.baseTime <= 0) return -1;
    return Math.max(0, Math.min(1, st.main / this._config.baseTime));
  }
}