// 读秒制计时器：服务器端统一计时（围棋比赛：主限时 + 读秒N次，读秒连续倒数、落子不重置）
// 规划文档 §3：主时耗尽进读秒，读秒用尽判负；替代原费舍尔制（基础+每手加时），避免对局计时越走越多

import {
  Color,
  TimerSystem,
  type TimerState,
  TIMER_BASE_SEC,
  BYO_PERIOD_SEC,
  BYO_COUNT,
  DEPLOY_TIMER_SEC,
} from "@warhorn/engine";
import type { ColorTimer } from "@warhorn/shared";

export interface TimerSnapshot {
  black: ColorTimer;
  white: ColorTimer;
}

export interface ServerTimerOptions {
  baseTime?: number;
  byoPeriod?: number;
  byoCount?: number;
  deployTime?: number;
}

export interface ServerTimerCallbacks {
  // 每秒 tick 时回调（用于广播 time:update）
  onTick: (snapshot: TimerSnapshot) => void;
  // 当某方时间耗尽时回调（用于超时判负）
  onTimeout: (loserColor: Color) => void;
}

export class ServerTimer {
  private readonly _sys: TimerSystem;
  private readonly _callbacks: ServerTimerCallbacks;
  private readonly _baseTime: number;
  private readonly _deployTime: number;
  private _interval: NodeJS.Timeout | null = null;
  private _started: boolean = false;

  constructor(callbacks: ServerTimerCallbacks, opts: ServerTimerOptions = {}) {
    this._baseTime = opts.baseTime ?? TIMER_BASE_SEC;
    this._deployTime = opts.deployTime ?? DEPLOY_TIMER_SEC;
    this._sys = new TimerSystem({
      baseTime: this._baseTime,
      byoPeriod: opts.byoPeriod ?? BYO_PERIOD_SEC,
      byoCount: opts.byoCount ?? BYO_COUNT,
    });
    this._callbacks = callbacks;

    // 引擎在时间耗尽时触发 onTimeOut
    this._sys.onTimeOut = (color: Color) => {
      this.stop();
      this._callbacks.onTimeout(color);
    };
  }

  // 开始计时，initialColor 先手行棋
  start(initialColor: Color = Color.BLACK): void {
    if (this._started) return;
    this._started = true;
    // 布局阶段：双方各 deployTime 秒
    this._sys.setTime(Color.BLACK, this._deployTime);
    this._sys.setTime(Color.WHITE, this._deployTime);
    // 设置先手为活跃方（_active 初始为 null，switchTo 不会给任何人加时）
    this._sys.switchTo(initialColor);
    this._interval = setInterval(() => {
      this._sys.tick(1);
      if (!this._started) return;
      this._callbacks.onTick(this.snapshot());
    }, 1000);
  }

  // 布局阶段→正式阶段过渡：双方重置为完整基础时间
  resetToBaseTime(): void {
    this._sys.setTime(Color.BLACK, this._baseTime);
    this._sys.setTime(Color.WHITE, this._baseTime);
  }

  // 切换行棋方：落子/虚手后调用（读秒制裁去每手加时，仅切换 active）
  switchTo(color: Color): void {
    this._sys.switchTo(color);
  }

  pause(): void {
    this._sys.pause();
  }

  resume(): void {
    this._sys.resume();
  }

  snapshot(): TimerSnapshot {
    return {
      black: this._toShared(this._sys.getTime(Color.BLACK)),
      white: this._toShared(this._sys.getTime(Color.WHITE)),
    };
  }

  private _toShared(st: TimerState): ColorTimer {
    return {
      main: Math.max(0, st.main),
      inByoyomi: st.inByoyomi,
      byoRemaining: Math.max(0, st.byoRemaining),
      byoCur: Math.max(0, st.byoCur),
    };
  }

  stop(): void {
    if (this._interval !== null) {
      clearInterval(this._interval);
      this._interval = null;
    }
    this._started = false;
  }
}
