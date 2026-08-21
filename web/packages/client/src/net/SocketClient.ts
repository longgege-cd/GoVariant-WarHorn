// Socket.io 客户端封装：连接服务器、发送事件、接收事件
// M2/M3 在线对战用，M1 本地对战不需要

import { io, type Socket } from "socket.io-client";
import {
  ClientEvent, ServerEvent,
  type LobbyUpdatePayload, type MatchFoundPayload,
  type GameStartPayload, type GameUpdatePayload,
  type GameOverPayload, type TimeUpdatePayload,
  type ErrorPayload, type GameConfig,
} from "@warhorn/shared";

export class SocketClient {
  private socket: Socket | null = null;
  private serverUrl: string;

  // 事件回调
  onLobbyUpdate?: (payload: LobbyUpdatePayload) => void;
  onMatchFound?: (payload: MatchFoundPayload) => void;
  onMatchCancelled?: () => void;
  onGameStart?: (payload: GameStartPayload) => void;
  onGameUpdate?: (payload: GameUpdatePayload) => void;
  onGameOver?: (payload: GameOverPayload) => void;
  onTimeUpdate?: (payload: TimeUpdatePayload) => void;
  onError?: (payload: ErrorPayload) => void;
  onDisconnect?: () => void;

  constructor(serverUrl: string = "http://localhost:3000") {
    this.serverUrl = serverUrl;
  }

  connect(): Promise<void> {
    return new Promise((resolve, reject) => {
      this.socket = io(this.serverUrl, {
        transports: ["websocket"],
        timeout: 5000,
      });

      this.socket.on("connect", () => {
        this._bindEvents();
        resolve();
      });

      this.socket.on("connect_error", (err: Error) => {
        reject(err);
      });

      this.socket.on("disconnect", () => {
        this.onDisconnect?.();
      });
    });
  }

  private _bindEvents(): void {
    if (!this.socket) return;

    this.socket.on(ServerEvent.LOBBY_UPDATE, (p: LobbyUpdatePayload) => this.onLobbyUpdate?.(p));
    this.socket.on(ServerEvent.MATCH_FOUND, (p: MatchFoundPayload) => this.onMatchFound?.(p));
    this.socket.on(ServerEvent.MATCH_CANCELLED, () => this.onMatchCancelled?.());
    this.socket.on(ServerEvent.GAME_START, (p: GameStartPayload) => this.onGameStart?.(p));
    this.socket.on(ServerEvent.GAME_UPDATE, (p: GameUpdatePayload) => this.onGameUpdate?.(p));
    this.socket.on(ServerEvent.GAME_OVER, (p: GameOverPayload) => this.onGameOver?.(p));
    this.socket.on(ServerEvent.TIME_UPDATE, (p: TimeUpdatePayload) => this.onTimeUpdate?.(p));
    this.socket.on(ServerEvent.ERROR, (p: ErrorPayload) => this.onError?.(p));
  }

  joinLobby(name: string): void {
    this.socket?.emit(ClientEvent.LOBBY_JOIN, { name });
  }

  // 获取服务器当前生效的游戏设置（大厅展示用，走 HTTP，不依赖 socket 连接）
  async fetchConfig(): Promise<GameConfig> {
    const res = await fetch(`${this.serverUrl}/api/config`);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return (await res.json()) as GameConfig;
  }

  requestMatch(): void {
    this.socket?.emit(ClientEvent.MATCH_REQUEST);
  }

  confirmMatch(): void {
    this.socket?.emit(ClientEvent.MATCH_CONFIRM);
  }

  declineMatch(): void {
    this.socket?.emit(ClientEvent.MATCH_DECLINE);
  }

  startPractice(): void {
    this.socket?.emit(ClientEvent.PRACTICE_START);
  }

  endPractice(): void {
    this.socket?.emit(ClientEvent.PRACTICE_END);
  }

  placeMove(row: number, col: number): void {
    this.socket?.emit(ClientEvent.MOVE_PLACE, { row, col });
  }

  pass(): void {
    this.socket?.emit(ClientEvent.MOVE_PASS);
  }

  resign(): void {
    this.socket?.emit(ClientEvent.RESIGN);
  }

  disconnect(): void {
    this.socket?.disconnect();
    this.socket = null;
  }
}
