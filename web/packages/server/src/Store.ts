// 轻量 JSON 持久化：活跃状态（玩家/队列/房间）+ 对局记录
//
// 防膨胀设计（对应需求"json文件不能过大"）：
//   - 活跃状态只存"结构摘要"（不存棋盘/落子历史），且对局结束/玩家离开即移除
//   - 对局记录固定上限 GAME_RECORD_LIMIT 局，超出丢弃最旧
//   - 写盘前检查文件大小上限，超限拒写并告警
//   - 原子写（tmp + rename）避免写坏文件
//   - 活跃状态采用防抖合并写盘，避免高频 IO
//
// 说明：WebSocket 会话无法在服务器重启后恢复（玩家 socket 已断），
//   因此活跃状态落盘定位为"崩溃审计 + 启动清理"，对局记录才是真正的玩家数据。

import {
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { PlayerColor, PlayerStatus, ScoreBreakdown } from "@warhorn/shared";

// ====== 数据类型 ======

export interface SavedPlayer {
  id: string;
  name: string;
  status: PlayerStatus;
  roomId?: string;
}

export interface SavedPendingMatch {
  roomId: string;
  aId: string;
  bId: string;
  colorA: PlayerColor;
  colorB: PlayerColor;
  confirmedA: boolean;
  confirmedB: boolean;
}

export interface SavedRoom {
  id: string;
  blackId: string;
  blackName: string;
  whiteId: string;
  whiteName: string;
  ended: boolean;
}

export interface SavedState {
  savedAt: number;
  players: SavedPlayer[];
  queue: string[]; // socketId（等待队列）
  pending: SavedPendingMatch[]; // 等待确认的匹配
  rooms: SavedRoom[];
}

// 终局原因分类（用于平衡统计）
export type EndCategory = "pass" | "resign" | "timeout" | "disconnect";

// 终局采集指标（GameRoom 在 _endGame 时收集，随对局记录落盘）
export interface GameMetrics {
  endCategory: EndCategory;
  durationSec: number; // 对局总时长（秒）
  scoreDiff: number; // finalBlack - finalWhite（黑方相对，用于分差分布）
  stonesBlack: number; // 黑方已用兵力
  stonesWhite: number;
  passBlack: number;
  passWhite: number;
  captureBlack: number; // 黑方提吃对方子数
  captureWhite: number;
  breakdownBlack: ScoreBreakdown;
  breakdownWhite: ScoreBreakdown;
}

// 对局记录（战绩 + 平衡采集）
export interface GameRecord {
  id: string;
  black: string;
  white: string;
  winner: string;
  winnerColor: PlayerColor;
  reason: string;
  ply: number;
  finalBlack: number;
  finalWhite: number;
  endedAt: number;
  // ====== 平衡调参采集（公测）======
  komi: number; // 本局贴目快照
  pieceLimit: number; // 本局兵力上限快照
  timerBaseSec: number; // 本局计时快照
  timerIncrementSec: number;
  endCategory: EndCategory;
  durationSec: number;
  scoreDiff: number;
  stonesBlack: number;
  stonesWhite: number;
  passBlack: number;
  passWhite: number;
  captureBlack: number;
  captureWhite: number;
  breakdownBlack: ScoreBreakdown;
  breakdownWhite: ScoreBreakdown;
}

interface GamesFile {
  games: GameRecord[];
}

// ====== 常量 ======

/** 对局记录上限（防膨胀：只保留最近 N 局） */
export const GAME_RECORD_LIMIT = 100;
/** 单个 JSON 文件大小上限（字节，超过拒写并告警） */
const MAX_FILE_BYTES = 2 * 1024 * 1024;
/** 活跃状态防抖写盘间隔（毫秒） */
const FLUSH_DEBOUNCE_MS = 500;

// ====== Store ======

export class Store {
  private readonly dataDir: string;
  private readonly statePath: string;
  private readonly gamesPath: string;
  private _pendingState: SavedState | null = null;
  private _flushTimer: NodeJS.Timeout | null = null;

  constructor(dataDir?: string) {
    // 默认落盘到 server 包内 data/ 目录
    this.dataDir = dataDir ?? join(dirname(fileURLToPath(import.meta.url)), "..", "data");
    mkdirSync(this.dataDir, { recursive: true });
    this.statePath = join(this.dataDir, "state.json");
    this.gamesPath = join(this.dataDir, "games.json");
  }

  // ====== 读取 ======

  loadState(): SavedState | null {
    return this._readJson<SavedState>(this.statePath);
  }

  loadGames(): GameRecord[] {
    const file = this._readJson<GamesFile>(this.gamesPath);
    return file?.games ?? [];
  }

  // ====== 写入 ======

  /** 保存活跃状态（防抖合并写盘） */
  scheduleStateSave(state: SavedState): void {
    this._pendingState = state;
    if (this._flushTimer) return;
    this._flushTimer = setTimeout(() => {
      this._flushTimer = null;
      const snap = this._pendingState;
      this._pendingState = null;
      if (snap) this._writeAtomic(this.statePath, snap);
    }, FLUSH_DEBOUNCE_MS);
  }

  /** 立即写盘（服务器退出前调用） */
  flushStateSync(): void {
    if (this._flushTimer) {
      clearTimeout(this._flushTimer);
      this._flushTimer = null;
    }
    if (this._pendingState) {
      this._writeAtomic(this.statePath, this._pendingState);
      this._pendingState = null;
    }
  }

  /** 追加对局记录（固定上限，超出丢弃最旧） */
  appendGame(record: GameRecord): void {
    const games = this.loadGames();
    games.push(record);
    if (games.length > GAME_RECORD_LIMIT) {
      games.splice(0, games.length - GAME_RECORD_LIMIT);
    }
    this._writeAtomic(this.gamesPath, { games });
  }

  // ====== 内部 ======

  private _readJson<T>(path: string): T | null {
    try {
      if (!existsSync(path)) return null;
      const raw = readFileSync(path, "utf8");
      return JSON.parse(raw) as T;
    } catch (err) {
      console.warn(`[store] 读取失败（已忽略）: ${path}`, err instanceof Error ? err.message : err);
      return null;
    }
  }

  private _writeAtomic(path: string, data: unknown): boolean {
    try {
      const json = JSON.stringify(data);
      // 大小上限保护：文件已超限则拒写，防止磁盘被撑满
      if (existsSync(path) && statSync(path).size > MAX_FILE_BYTES) {
        console.warn(`[store] ${path} 超过 ${MAX_FILE_BYTES} 字节上限，拒绝写入`);
        return false;
      }
      const tmp = `${path}.tmp`;
      writeFileSync(tmp, json, "utf8");
      renameSync(tmp, path);
      return true;
    } catch (err) {
      console.warn(`[store] 写入失败: ${path}`, err instanceof Error ? err.message : err);
      return false;
    }
  }
}
