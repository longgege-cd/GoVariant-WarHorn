// 匹配队列：等待玩家列表、自动配对、匹配确认机制（10秒倒计时）
// 规划文档 §2：自动寻找等待中的对手，匹配确认 10 秒倒计时
// 规则：一方放弃/超时 → 另一方回到等待队列头部；放弃方回大厅

import type { Server } from "socket.io";
import { randomUUID } from "node:crypto";
import {
  ServerEvent,
  PlayerColor,
  type PlayerStatus,
  type MatchFoundPayload,
} from "@warhorn/shared";
import { MATCH_CONFIRM_TIMEOUT_SEC } from "@warhorn/engine";

export interface WaitingEntry {
  socketId: string;
  name: string;
}

interface PendingMatch {
  roomId: string; // 同时作为 matchId，确认后即游戏房间 id
  a: WaitingEntry;
  b: WaitingEntry;
  colorA: PlayerColor; // 玩家 A 的颜色（BLACK 或 WHITE，随机分配）
  colorB: PlayerColor;
  confirmedA: boolean;
  confirmedB: boolean;
  timer: NodeJS.Timeout | null;
}

export interface MatchQueueCallbacks {
  // 双方均确认 → 创建游戏房间，返回 roomId
  createRoom: (
    a: WaitingEntry,
    b: WaitingEntry,
    colorA: PlayerColor,
    colorB: PlayerColor,
    roomId: string
  ) => void;
  // 更新玩家状态（lobby/matching/playing）
  setPlayerStatus: (socketId: string, status: PlayerStatus) => void;
}

export class MatchQueue {
  private readonly _queue: WaitingEntry[] = [];
  // roomId -> PendingMatch
  private readonly _pending: Map<string, PendingMatch> = new Map();
  private readonly _io: Server;
  private readonly _cb: MatchQueueCallbacks;

  constructor(io: Server, cb: MatchQueueCallbacks) {
    this._io = io;
    this._cb = cb;
  }

  // 入队（尾部）
  enqueue(socketId: string, name: string): void {
    if (this._isInQueue(socketId) || this._isInPending(socketId)) return;
    this._queue.push({ socketId, name });
    this._tryMatch();
  }

  // 重新入队（头部）—— 被对方放弃匹配拖累的玩家
  enqueueToFront(socketId: string, name: string): void {
    if (this._isInQueue(socketId) || this._isInPending(socketId)) return;
    this._queue.unshift({ socketId, name });
    this._tryMatch();
  }

  // 玩家确认匹配
  confirm(socketId: string): void {
    const pending = this._findPendingBySocket(socketId);
    if (!pending) return;

    if (socketId === pending.a.socketId) {
      pending.confirmedA = true;
    } else if (socketId === pending.b.socketId) {
      pending.confirmedB = true;
    } else {
      return;
    }

    // 双方均确认 → 创建房间
    if (pending.confirmedA && pending.confirmedB) {
      this._clearTimer(pending);
      this._pending.delete(pending.roomId);
      this._cb.createRoom(
        pending.a,
        pending.b,
        pending.colorA,
        pending.colorB,
        pending.roomId
      );
      this._cb.setPlayerStatus(pending.a.socketId, "playing");
      this._cb.setPlayerStatus(pending.b.socketId, "playing");
    }
  }

  // 玩家主动放弃匹配
  decline(socketId: string): void {
    const pending = this._findPendingBySocket(socketId);
    if (!pending) return;
    this._cancelMatch(pending, socketId);
  }

  // 玩家断线：从队列移除 + 取消其所在 pending（对方作为受害者重新入队）
  handleDisconnect(socketId: string): void {
    const idx = this._queue.findIndex((e) => e.socketId === socketId);
    if (idx >= 0) this._queue.splice(idx, 1);
    const pending = this._findPendingBySocket(socketId);
    if (pending) {
      this._cancelMatch(pending, socketId);
    }
  }

  // ====== 状态只读暴露（持久化用）======

  getQueueSnapshot(): WaitingEntry[] {
    return [...this._queue];
  }

  getPendingSnapshot(): Array<{
    roomId: string;
    aId: string;
    bId: string;
    colorA: PlayerColor;
    colorB: PlayerColor;
    confirmedA: boolean;
    confirmedB: boolean;
  }> {
    return [...this._pending.values()].map((p) => ({
      roomId: p.roomId,
      aId: p.a.socketId,
      bId: p.b.socketId,
      colorA: p.colorA,
      colorB: p.colorB,
      confirmedA: p.confirmedA,
      confirmedB: p.confirmedB,
    }));
  }

  // ====== 内部 ======

  private _tryMatch(): void {
    while (this._queue.length >= 2) {
      const a = this._queue.shift()!;
      const b = this._queue.shift()!;
      this._createPendingMatch(a, b);
    }
  }

  private _createPendingMatch(a: WaitingEntry, b: WaitingEntry): void {
    const roomId = randomUUID();
    // 随机分配黑白
    const blackFirst = Math.random() < 0.5;
    const colorA = blackFirst ? PlayerColor.BLACK : PlayerColor.WHITE;
    const colorB = blackFirst ? PlayerColor.WHITE : PlayerColor.BLACK;

    const pending: PendingMatch = {
      roomId,
      a,
      b,
      colorA,
      colorB,
      confirmedA: false,
      confirmedB: false,
      timer: null,
    };

    pending.timer = setTimeout(() => {
      this._handleTimeout(roomId);
    }, MATCH_CONFIRM_TIMEOUT_SEC * 1000);

    this._pending.set(roomId, pending);

    const payloadA: MatchFoundPayload = {
      roomId,
      opponentName: b.name,
      ownColor: colorA,
      confirmTimeoutSec: MATCH_CONFIRM_TIMEOUT_SEC,
    };
    const payloadB: MatchFoundPayload = {
      roomId,
      opponentName: a.name,
      ownColor: colorB,
      confirmTimeoutSec: MATCH_CONFIRM_TIMEOUT_SEC,
    };
    console.log(`[match] paired "${a.name}"(${a.socketId}) vs "${b.name}"(${b.socketId})`);
    this._io.to(a.socketId).emit(ServerEvent.MATCH_FOUND, payloadA);
    this._io.to(b.socketId).emit(ServerEvent.MATCH_FOUND, payloadB);
  }

  // 取消匹配（decline 或单方超时）
  private _cancelMatch(pending: PendingMatch, declinerSocketId: string): void {
    this._clearTimer(pending);
    this._pending.delete(pending.roomId);

    const aIsDecliner = declinerSocketId === pending.a.socketId;
    const other = aIsDecliner ? pending.b : pending.a;
    const otherConfirmed = aIsDecliner ? pending.confirmedB : pending.confirmedA;

    // 通知双方匹配已取消
    this._io.to(pending.a.socketId).emit(ServerEvent.MATCH_CANCELLED, {
      reason: "对方放弃匹配",
    });
    this._io.to(pending.b.socketId).emit(ServerEvent.MATCH_CANCELLED, {
      reason: "对方放弃匹配",
    });

    // 放弃方 → 回大厅
    this._cb.setPlayerStatus(declinerSocketId, "lobby");

    // 受害方（已确认但被对方拖累）→ 重新入队头部继续匹配
    if (otherConfirmed) {
      this.enqueueToFront(other.socketId, other.name);
    } else {
      // 对方也没确认 → 回大厅
      this._cb.setPlayerStatus(other.socketId, "lobby");
    }
  }

  private _handleTimeout(roomId: string): void {
    const pending = this._pending.get(roomId);
    if (!pending) return;

    // 双方都没确认 → 双方均视为放弃，回大厅
    if (!pending.confirmedA && !pending.confirmedB) {
      this._clearTimer(pending);
      this._pending.delete(roomId);
      this._io.to(pending.a.socketId).emit(ServerEvent.MATCH_CANCELLED, {
        reason: "确认超时",
      });
      this._io.to(pending.b.socketId).emit(ServerEvent.MATCH_CANCELLED, {
        reason: "确认超时",
      });
      this._cb.setPlayerStatus(pending.a.socketId, "lobby");
      this._cb.setPlayerStatus(pending.b.socketId, "lobby");
      return;
    }

    // 单方未确认 → 该方视为放弃，另一方重新入队
    const declinerSocketId = !pending.confirmedA
      ? pending.a.socketId
      : pending.b.socketId;
    this._cancelMatch(pending, declinerSocketId);
  }

  private _findPendingBySocket(socketId: string): PendingMatch | undefined {
    for (const p of this._pending.values()) {
      if (p.a.socketId === socketId || p.b.socketId === socketId) return p;
    }
    return undefined;
  }

  private _isInQueue(socketId: string): boolean {
    return this._queue.some((e) => e.socketId === socketId);
  }

  private _isInPending(socketId: string): boolean {
    return this._findPendingBySocket(socketId) !== undefined;
  }

  private _clearTimer(pending: PendingMatch): void {
    if (pending.timer !== null) {
      clearTimeout(pending.timer);
      pending.timer = null;
    }
  }
}
