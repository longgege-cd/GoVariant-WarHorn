// 大厅管理：玩家加入/离开、在线人数广播、玩家状态管理
// 规划文档 §2：临时身份（输入名字即玩），大厅显示在线人数、匹配状态

import type { Server } from "socket.io";
import {
  ServerEvent,
  type Player,
  type PlayerStatus,
  type LobbyUpdatePayload,
} from "@warhorn/shared";

export class Lobby {
  // socketId -> Player
  private readonly _players: Map<string, Player> = new Map();
  private readonly _io: Server;

  constructor(io: Server) {
    this._io = io;
  }

  // 玩家加入大厅（临时身份：仅记录名字）
  addPlayer(socketId: string, name: string): Player {
    const player: Player = {
      id: socketId,
      name,
      status: "lobby",
    };
    this._players.set(socketId, player);
    this.broadcastUpdate();
    return player;
  }

  removePlayer(socketId: string): Player | undefined {
    const player = this._players.get(socketId);
    this._players.delete(socketId);
    this.broadcastUpdate();
    return player;
  }

  getPlayer(socketId: string): Player | undefined {
    return this._players.get(socketId);
  }

  // 玩家必须先加入大厅才可设置状态
  setStatus(socketId: string, status: PlayerStatus, roomId?: string): void {
    const player = this._players.get(socketId);
    if (!player) return;
    player.status = status;
    player.roomId = roomId;
  }

  getOnlineCount(): number {
    return this._players.size;
  }

  getMatchingCount(): number {
    let n = 0;
    for (const p of this._players.values()) {
      if (p.status === "matching") n++;
    }
    return n;
  }

  // 全量玩家快照（持久化用）
  getPlayersSnapshot(): Player[] {
    return [...this._players.values()].map((p) => ({ ...p }));
  }

  // 广播大厅状态（在线人数、匹配中人数）给所有人
  broadcastUpdate(): void {
    const payload: LobbyUpdatePayload = {
      onlineCount: this.getOnlineCount(),
      matchingCount: this.getMatchingCount(),
    };
    this._io.emit(ServerEvent.LOBBY_UPDATE, payload);
  }
}
