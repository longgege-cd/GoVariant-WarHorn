// 游戏房间：权威规则引擎集成（GameSession）、落子/虚手/认输处理、计时器、断线判负、终局结算
// 规划文档 §3：权威规则引擎在服务器运行，客户端只做渲染
//   - 计时：费舍尔制（基础 10 分钟 + 每手加 10 秒），服务器统一计时
//   - 断线处理：立即判负（MVP 不做重连）
//   - 对局结束：连续虚手 / 认输 / 超时 / 断线 / 兵力用尽

import type { Server } from "socket.io";
import {
  Color,
  GameSession,
  opponent,
  BOARD_SIZE,
  DEPLOY_PHASE_MOVES,
} from "@warhorn/engine";
import {
  ServerEvent,
  PlayerColor,
  type SerializedBoard,
  type MoveOutcome,
  type FinalResult,
  type ScoreSide,
  type ScoreBreakdown,
  type GameStartPayload,
  type GameUpdatePayload,
  type TimeUpdatePayload,
  type GameOverPayload,
} from "@warhorn/shared";
import { ServerTimer, type TimerSnapshot } from "./Timer.js";
import type { EndCategory, GameMetrics } from "./Store.js";

interface RoomPlayer {
  socketId: string;
  name: string;
  color: Color;
}

// 一局对局的参数快照（由 Config 提供，随对局记录落盘）
export interface RoomSettings {
  komi: number;
  pieceLimit: number;
  timerBaseSec: number;
  timerIncrementSec: number; // 已弃用：读秒制裁去每手加时（恒为0，兼容）
  byoPeriodSec: number; // 每次读秒秒数
  byoCount: number; // 读秒次数
  deployTimerSec: number;
}

export interface GameRoomCallbacks {
  // 对局结束回调：index 用于清理房间 + 重置玩家状态 + 记录战绩（含平衡指标）
  onGameOver: (
    roomId: string,
    playerSocketIds: string[],
    result: FinalResult,
    metrics: GameMetrics
  ) => void;
}

export class GameRoom {
  readonly roomId: string;
  private readonly _io: Server;
  private readonly _cb: GameRoomCallbacks;
  private readonly _settings: RoomSettings;
  private readonly _session: GameSession;
  private readonly _timer: ServerTimer;
  private readonly _black: RoomPlayer;
  private readonly _white: RoomPlayer;
  // socketId -> Color（便于快速定位行棋方）
  private readonly _socketToColor: Map<string, Color> = new Map();
  private _ended: boolean = false;
  private _startedAt: number = 0;
  private _endCategory: EndCategory = "pass";


  // 玩家信息只读暴露（持久化用）
  get blackInfo(): { socketId: string; name: string; color: Color } {
    return this._black;
  }
  get whiteInfo(): { socketId: string; name: string; color: Color } {
    return this._white;
  }
  get ended(): boolean {
    return this._ended;
  }

  constructor(
    roomId: string,
    io: Server,
    cb: GameRoomCallbacks,
    black: { socketId: string; name: string },
    white: { socketId: string; name: string },
    settings: RoomSettings
  ) {
    this.roomId = roomId;
    this._io = io;
    this._cb = cb;
    this._settings = settings;

    this._black = { socketId: black.socketId, name: black.name, color: Color.BLACK };
    this._white = { socketId: white.socketId, name: white.name, color: Color.WHITE };
    this._socketToColor.set(black.socketId, Color.BLACK);
    this._socketToColor.set(white.socketId, Color.WHITE);

    // 权威规则引擎：开启布局阶段，参数来自配置（贴目/兵力）
    this._session = new GameSession({
      komi: settings.komi,
      pieceLimit: settings.pieceLimit,
      enableDeployPhase: true,
    });
    this._session.newGame();

    this._timer = new ServerTimer(
      {
        onTick: (snap: TimerSnapshot) => this._broadcastTime(snap),
        onTimeout: (loser: Color) => this._handleTimeout(loser),
      },
      {
        baseTime: settings.timerBaseSec,
        byoPeriod: settings.byoPeriodSec,
        byoCount: settings.byoCount,
        deployTime: settings.deployTimerSec,
      }
    );
  }

  // ====== 对局启动 ======

  start(): void {
    this._startedAt = Date.now();
    const base: GameStartPayload = {
      roomId: this.roomId,
      blackName: this._black.name,
      whiteName: this._white.name,
      ownColor: PlayerColor.BLACK,
      initialState: this._serializeBoard(),
      baseTimeSec: this._settings.timerBaseSec,
      incrementSec: this._settings.timerIncrementSec,
      byoPeriodSec: this._settings.byoPeriodSec,
      byoCount: this._settings.byoCount,
      komi: this._settings.komi,
      pieceLimit: this._settings.pieceLimit,
    };
    // 双方 ownColor 不同，分别发送
    this._io
      .to(this._black.socketId)
      .emit(ServerEvent.GAME_START, { ...base, ownColor: PlayerColor.BLACK });
    this._io
      .to(this._white.socketId)
      .emit(ServerEvent.GAME_START, { ...base, ownColor: PlayerColor.WHITE });

    // BLACK 先手，启动计时器（switchTo(BLACK) 不会给任何人加时）
    this._timer.start(Color.BLACK);
  }

  // ====== 客户端事件处理 ======

  hasSocket(socketId: string): boolean {
    return this._socketToColor.has(socketId);
  }

  handlePlace(socketId: string, row: number, col: number): void {
    if (this._ended) return;
    const color = this._socketToColor.get(socketId);
    if (color === undefined) {
      this._emitError(socketId, "你不在此房间");
      return;
    }
    // 权威引擎验证落子
    const outcome = this._session.playMove(color, row, col);
    if (!outcome.ok) {
      this._emitError(socketId, outcome.reason ?? "非法落子");
      return;
    }
    this._afterMove(outcome);
  }

  handlePass(socketId: string): void {
    if (this._ended) return;
    const color = this._socketToColor.get(socketId);
    if (color === undefined) {
      this._emitError(socketId, "你不在此房间");
      return;
    }
    const outcome = this._session.doPass(color);
    if (!outcome.ok) {
      this._emitError(socketId, outcome.reason ?? "非法虚手");
      return;
    }
    this._afterMove(outcome);
  }

  handleResign(socketId: string): void {
    if (this._ended) return;
    const color = this._socketToColor.get(socketId);
    if (color === undefined) {
      this._emitError(socketId, "你不在此房间");
      return;
    }
    const outcome = this._session.resign(color);
    if (!outcome.ok || !outcome.result) {
      this._emitError(socketId, outcome.reason ?? "无法认输");
      return;
    }
    // resign 已在引擎内设置 gameOver，这里直接进入终局流程
    this._endCategory = "resign";
    this._endGame(outcome.result);
  }

  // 断线判负：断线方立即判负，对方胜
  handleDisconnect(socketId: string): void {
    if (this._ended) return;
    const color = this._socketToColor.get(socketId);
    if (color === undefined) return;

    this._endCategory = "disconnect";
    // 用 resign 生成终局结果（winner = opponent(color)），覆盖原因为"断线判负"
    const outcome = this._session.resign(color);
    if (!outcome.ok || !outcome.result) {
      // 引擎已结束（不应发生，_ended 已守护），兜底直接结束
      this._endGame(this._buildForfeitResult(color, "断线判负"));
      return;
    }
    outcome.result.reason = `${color === Color.BLACK ? "黑" : "白"}方断线判负`;
    this._endGame(outcome.result);
  }

  cleanup(): void {
    this._timer.stop();
  }

  // ====== 内部 ======

  // 落子/虚手后的统一处理：切换计时器、广播 update、必要时终局
  private _afterMove(outcome: MoveOutcome): void {
    if (outcome.gameOver) {
      this._timer.stop();
    } else {
      // 布局→正式阶段过渡：重置双方计时器为完整基础时间
      const wasDeploy = outcome.ply !== undefined && outcome.ply <= DEPLOY_PHASE_MOVES;
      if (wasDeploy && !this._session.isInDeployPhase()) {
        this._timer.resetToBaseTime();
      }
      // 切换行棋方：正式阶段加 increment（费舍尔制），布局阶段不加
      this._timer.switchTo(this._session.toMove);
    }

    this._broadcastUpdate(outcome);

    if (outcome.gameOver && outcome.result) {
      this._endGame(outcome.result);
    }
  }

  private _handleTimeout(loser: Color): void {
    if (this._ended) return;
    this._endCategory = "timeout";
    // 超时方判负
    const outcome = this._session.resign(loser);
    if (!outcome.ok || !outcome.result) {
      this._endGame(this._buildForfeitResult(loser, "超时判负"));
      return;
    }
    outcome.result.reason = `${loser === Color.BLACK ? "黑" : "白"}方超时判负`;
    this._endGame(outcome.result);
  }

  private _endGame(result: FinalResult): void {
    if (this._ended) return;
    this._ended = true;
    this._timer.stop();

    const payload: GameOverPayload = {
      winner: result.winnerColor,
      reason: result.reason,
      finalResult: result,
    };
    this._io.to(this._black.socketId).emit(ServerEvent.GAME_OVER, payload);
    this._io.to(this._white.socketId).emit(ServerEvent.GAME_OVER, payload);

    this._cb.onGameOver(
      this.roomId,
      [this._black.socketId, this._white.socketId],
      result,
      this._collectMetrics(result)
    );
  }

  // 采集终局平衡指标（随对局记录落盘，供平衡调参分析）
  private _collectMetrics(result: FinalResult): GameMetrics {
    const countersBlack = this._session.counters.get(Color.BLACK);
    const countersWhite = this._session.counters.get(Color.WHITE);
    return {
      endCategory: this._endCategory,
      durationSec: Math.max(0, Math.round((Date.now() - this._startedAt) / 1000)),
      // 黑方相对分差（正=黑方领先，用于分差分布/贴目评估）
      scoreDiff: result.black.final - result.white.final,
      stonesBlack: this._session.stonesPlaced.get(Color.BLACK) ?? 0,
      stonesWhite: this._session.stonesPlaced.get(Color.WHITE) ?? 0,
      passBlack: this._session.passCounts.get(Color.BLACK) ?? 0,
      passWhite: this._session.passCounts.get(Color.WHITE) ?? 0,
      // 提吃数 = 对方被提子数（normalLost 口径）
      captureBlack: countersWhite?.normalLost ?? 0,
      captureWhite: countersBlack?.normalLost ?? 0,
      breakdownBlack: result.black.breakdown,
      breakdownWhite: result.white.breakdown,
    };
  }

  // 超时/断线的兜底结果（当引擎已无法生成时使用）
  private _buildForfeitResult(loser: Color, reason: string): FinalResult {
    const winner = opponent(loser);
    const scores = this._session.scores();
    const blackSide = this._scoreSide(scores.black, true);
    const whiteSide = this._scoreSide(scores.white, false);
    return {
      black: blackSide,
      white: whiteSide,
      winner: winner === Color.BLACK ? "黑方胜" : "白方胜",
      winnerColor: winner,
      reason: `${loser === Color.BLACK ? "黑" : "白"}方${reason}`,
      ply: this._session.ply,
    };
  }

  // ====== 广播 ======

  private _broadcastUpdate(outcome: MoveOutcome): void {
    const scores = this._session.scores();
    const payload: GameUpdatePayload = {
      outcome,
      board: this._serializeBoard(),
      currentTurn: this._session.toMove,
      timers: this._timer.snapshot(),
      scores: {
        black: this._scoreSide(scores.black, true),
        white: this._scoreSide(scores.white, false),
      },
      stonesPlaced: {
        black: this._session.stonesPlaced.get(Color.BLACK) ?? 0,
        white: this._session.stonesPlaced.get(Color.WHITE) ?? 0,
      },
    };
    this._io.to(this._black.socketId).emit(ServerEvent.GAME_UPDATE, payload);
    this._io.to(this._white.socketId).emit(ServerEvent.GAME_UPDATE, payload);
  }

  private _broadcastTime(snap: TimerSnapshot): void {
    const payload: TimeUpdatePayload = { black: snap.black, white: snap.white };
    this._io.to(this._black.socketId).emit(ServerEvent.TIME_UPDATE, payload);
    this._io.to(this._white.socketId).emit(ServerEvent.TIME_UPDATE, payload);
  }

  private _emitError(socketId: string, message: string): void {
    this._io.to(socketId).emit(ServerEvent.ERROR, { message });
  }

  // ====== 工具 ======

  private _serializeBoard(): SerializedBoard {
    return {
      size: BOARD_SIZE,
      grid: this._session.board.serialize(),
    };
  }

  // 由 ScoreBreakdown 构造 ScoreSide（盘中实时分数：total - komi）
  private _scoreSide(breakdown: ScoreBreakdown, isBlack: boolean): ScoreSide {
    const total =
      breakdown.occupationTerritory +
      breakdown.occupationEfficiency +
      breakdown.defenseAnnihilate +
      breakdown.defenseSiege +
      breakdown.casualtyLoss +
      breakdown.casualtySpecial;
    const komi = isBlack ? this._session.komi : 0;
    return { breakdown, total, komi, final: total - komi };
  }
}
