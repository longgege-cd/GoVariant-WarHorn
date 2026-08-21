// 服务器入口：Express + Socket.io 初始化、CORS、监听 3000 端口
// 事件路由：lobby:join / match:* / practice:* / move:* / resign / disconnect
//
// 架构：
//   - Lobby：玩家在线状态
//   - MatchQueue：匹配配对与确认
//   - Map<roomId, GameRoom>：活跃对局
// 组件间通过回调解耦，避免循环依赖

// 支持 .env 文件配置：加载 packages/server/.env（显式路径，与运行目录无关）
// dotenv 默认不覆盖已存在的环境变量 → 真实环境变量优先级高于 .env 文件
import dotenv from "dotenv";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { existsSync } from "node:fs";
dotenv.config({ path: resolve(dirname(fileURLToPath(import.meta.url)), "..", ".env") });

import express from "express";
import http from "node:http";
import cors from "cors";
import { Server } from "socket.io";
import {
  ClientEvent,
  ServerEvent,
  PlayerColor,
  type PlayerStatus,
  type FinalResult,
} from "@warhorn/shared";
import { Lobby } from "./Lobby.js";
import { MatchQueue, type WaitingEntry } from "./MatchQueue.js";
import { GameRoom } from "./GameRoom.js";
import { Store, GAME_RECORD_LIMIT, type SavedState, type GameMetrics } from "./Store.js";
import { loadConfig } from "./Config.js";
import { computeStats } from "./Stats.js";

const PORT = Number(process.env.PORT ?? 3000);
const CORS_ORIGIN = process.env.CORS_ORIGIN ?? "*";
const MAX_NAME_LENGTH = 20;

// 运行配置（可调平衡参数，环境变量覆盖，见 Config.ts）
const config = loadConfig();
console.log(
  `[config] komi=${config.komi} pieceLimit=${config.pieceLimit} ` +
    `timer=${config.timerBaseSec}s+${config.timerIncrementSec}s deploy=${config.deployTimerSec}s`
);

// ====== HTTP 服务器 ======

const app = express();
app.use(cors({ origin: CORS_ORIGIN }));
app.use(express.json());

// 单服务部署：若存在前端构建产物（client/dist），由后端一并托管静态资源
// 开发环境（未构建前端）时 `/` 仍返回 JSON 服务信息。
const clientDist = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..", "client", "dist");
const indexHtml = resolve(clientDist, "index.html");

if (existsSync(indexHtml)) {
  app.use(express.static(clientDist));
  app.get("/", (_req, res) => res.sendFile(indexHtml));
  // SPA 回退：非 API 的 GET 请求统一返回 index.html（刷新页面不 404）
  app.use((req, res, next) => {
    if (
      req.method === "GET" &&
      !req.path.startsWith("/api") &&
      !req.path.startsWith("/admin") &&
      !req.path.startsWith("/socket.io")
    ) {
      return res.sendFile(indexHtml);
    }
    next();
  });
} else {
  app.get("/", (_req, res) => {
    res.json({ ok: true, service: "warhorn-server", version: "0.1.0" });
  });
}

app.get("/health", (_req, res) => {
  res.json({ ok: true });
});

// 平衡调参统计接口：对 games.json 做聚合分析
// 可选鉴权：设置了 WARHORN_ADMIN_TOKEN 时需携带 x-admin-token 请求头
app.get("/admin/stats", (req, res) => {
  if (config.adminToken && req.get("x-admin-token") !== config.adminToken) {
    res.status(401).json({ error: "unauthorized" });
    return;
  }
  res.json(computeStats(store.loadGames()));
});

// 游戏设置接口：大厅展示当前生效的平衡参数（不含 adminToken）
app.get("/api/config", (_req, res) => {
  res.json({
    komi: config.komi,
    pieceLimit: config.pieceLimit,
    timerBaseSec: config.timerBaseSec,
    timerIncrementSec: config.timerIncrementSec,
    byoPeriodSec: config.byoPeriodSec,
    byoCount: config.byoCount,
    deployTimerSec: config.deployTimerSec,
  });
});

const httpServer = http.createServer(app);

// ====== Socket.io 服务器 ======

const io = new Server(httpServer, {
  cors: { origin: CORS_ORIGIN, methods: ["GET", "POST"] },
});

// ====== 核心组件 ======

const lobby = new Lobby(io);
const rooms = new Map<string, GameRoom>();
const store = new Store();

// ====== 持久化 ======

// 收集当前活跃状态（结构摘要，不含棋盘/落子历史 → 文件有界）
function collectState(): SavedState {
  return {
    savedAt: Date.now(),
    players: lobby.getPlayersSnapshot(),
    queue: matchQueue.getQueueSnapshot().map((e) => e.socketId),
    pending: matchQueue.getPendingSnapshot(),
    rooms: [...rooms.values()].map((r) => ({
      id: r.roomId,
      blackId: r.blackInfo.socketId,
      blackName: r.blackInfo.name,
      whiteId: r.whiteInfo.socketId,
      whiteName: r.whiteInfo.name,
      ended: r.ended,
    })),
  };
}

// 调度活跃状态落盘（防抖合并，500ms 内多次变化只写一次）
function persist(): void {
  store.scheduleStateSave(collectState());
}

// 对局结束：清理房间 + 双方回大厅 + 记录战绩（含平衡采集）
function handleGameOver(
  roomId: string,
  playerSocketIds: string[],
  result: FinalResult,
  metrics: GameMetrics
): void {
  const room = rooms.get(roomId);
  let blackName = "";
  let whiteName = "";
  if (room) {
    blackName = room.blackInfo.name;
    whiteName = room.whiteInfo.name;
    room.cleanup();
    rooms.delete(roomId);
  }
  // 记录对局战绩 + 平衡指标（固定上限，防膨胀）
  store.appendGame({
    id: roomId,
    black: blackName,
    white: whiteName,
    winner: result.winner,
    winnerColor: result.winnerColor,
    reason: result.reason,
    ply: result.ply,
    finalBlack: result.black.final,
    finalWhite: result.white.final,
    endedAt: Date.now(),
    // 参数快照（本局实际使用的规则参数）
    komi: config.komi,
    pieceLimit: config.pieceLimit,
    timerBaseSec: config.timerBaseSec,
    timerIncrementSec: config.timerIncrementSec,
    // 终局采集指标
    endCategory: metrics.endCategory,
    durationSec: metrics.durationSec,
    scoreDiff: metrics.scoreDiff,
    stonesBlack: metrics.stonesBlack,
    stonesWhite: metrics.stonesWhite,
    passBlack: metrics.passBlack,
    passWhite: metrics.passWhite,
    captureBlack: metrics.captureBlack,
    captureWhite: metrics.captureWhite,
    breakdownBlack: metrics.breakdownBlack,
    breakdownWhite: metrics.breakdownWhite,
  });
  for (const sid of playerSocketIds) {
    lobby.setStatus(sid, "lobby");
  }
  lobby.broadcastUpdate();
  persist();
}

const matchQueue = new MatchQueue(io, {
  // 双方确认 → 创建游戏房间（黑白由 MatchQueue 随机分配）
  createRoom: (
    a: WaitingEntry,
    b: WaitingEntry,
    colorA: PlayerColor,
    _colorB: PlayerColor,
    roomId: string
  ) => {
    const black = colorA === PlayerColor.BLACK ? a : b;
    const white = colorA === PlayerColor.BLACK ? b : a;
    const room = new GameRoom(
      roomId,
      io,
      { onGameOver: handleGameOver },
      { socketId: black.socketId, name: black.name },
      { socketId: white.socketId, name: white.name },
      // 参数快照：使用当前服务器配置（公测可调）
      {
        komi: config.komi,
        pieceLimit: config.pieceLimit,
        timerBaseSec: config.timerBaseSec,
        timerIncrementSec: config.timerIncrementSec,
        byoPeriodSec: config.byoPeriodSec,
        byoCount: config.byoCount,
        deployTimerSec: config.deployTimerSec,
      }
    );
    rooms.set(roomId, room);
    lobby.setStatus(black.socketId, "playing", roomId);
    lobby.setStatus(white.socketId, "playing", roomId);
    room.start();
    persist();
  },
  setPlayerStatus: (socketId: string, status: PlayerStatus) => {
    lobby.setStatus(socketId, status);
    lobby.broadcastUpdate();
    persist();
  },
});

// 根据 socketId 查找其所在房间
function findRoomBySocket(socketId: string): GameRoom | undefined {
  for (const room of rooms.values()) {
    if (room.hasSocket(socketId)) return room;
  }
  return undefined;
}

function emitError(socketId: string, message: string, code?: string): void {
  io.to(socketId).emit(ServerEvent.ERROR, { message, code });
}

// ====== 事件路由 ======

io.on("connection", (socket) => {
  // 临时身份：输入名字即玩
  // payload 兼容两种格式：纯字符串 "{name}" 或对象 { name: string }
  socket.on(ClientEvent.LOBBY_JOIN, (payload: unknown) => {
    const rawName =
      typeof payload === "string"
        ? payload
        : typeof payload === "object" && payload !== null &&
          typeof (payload as { name?: unknown }).name === "string"
          ? (payload as { name: string }).name
          : "";
    const name = rawName.trim();
    if (!name) {
      emitError(socket.id, "名字不能为空");
      return;
    }
    if (name.length > MAX_NAME_LENGTH) {
      emitError(socket.id, `名字过长（最多 ${MAX_NAME_LENGTH} 字）`);
      return;
    }
    if (lobby.getPlayer(socket.id)) {
      // 已在大厅，仅更新名字
      return;
    }
    lobby.addPlayer(socket.id, name);
    persist();
  });

  socket.on(ClientEvent.MATCH_REQUEST, () => {
    const player = lobby.getPlayer(socket.id);
    if (!player) {
      emitError(socket.id, "请先加入大厅");
      return;
    }
    if (player.status !== "lobby") {
      emitError(socket.id, "当前状态无法匹配");
      return;
    }
    lobby.setStatus(socket.id, "matching");
    matchQueue.enqueue(socket.id, player.name);
    lobby.broadcastUpdate();
    persist();
  });

  socket.on(ClientEvent.MATCH_CONFIRM, () => {
    matchQueue.confirm(socket.id);
  });

  socket.on(ClientEvent.MATCH_DECLINE, () => {
    matchQueue.decline(socket.id);
  });

  // 练习模式：本地棋盘，服务器仅更新状态
  socket.on(ClientEvent.PRACTICE_START, () => {
    const player = lobby.getPlayer(socket.id);
    if (!player || player.status !== "lobby") {
      emitError(socket.id, "当前状态无法进入练习");
      return;
    }
    lobby.setStatus(socket.id, "practice");
    lobby.broadcastUpdate();
    persist();
  });

  socket.on(ClientEvent.PRACTICE_END, () => {
    const player = lobby.getPlayer(socket.id);
    if (!player || player.status !== "practice") return;
    lobby.setStatus(socket.id, "lobby");
    lobby.broadcastUpdate();
    persist();
  });

  // 落子（权威引擎验证）
  socket.on(ClientEvent.MOVE_PLACE, (data: unknown) => {
    const room = findRoomBySocket(socket.id);
    if (!room) {
      emitError(socket.id, "未在对局中");
      return;
    }
    if (
      data === null ||
      typeof data !== "object" ||
      typeof (data as { row?: unknown }).row !== "number" ||
      typeof (data as { col?: unknown }).col !== "number"
    ) {
      emitError(socket.id, "非法落子参数");
      return;
    }
    const { row, col } = data as { row: number; col: number };
    room.handlePlace(socket.id, row, col);
  });

  // 虚手
  socket.on(ClientEvent.MOVE_PASS, () => {
    const room = findRoomBySocket(socket.id);
    if (!room) {
      emitError(socket.id, "未在对局中");
      return;
    }
    room.handlePass(socket.id);
  });

  // 认输
  socket.on(ClientEvent.RESIGN, () => {
    const room = findRoomBySocket(socket.id);
    if (!room) {
      emitError(socket.id, "未在对局中");
      return;
    }
    room.handleResign(socket.id);
  });

  // 断线：匹配中断 + 断线判负
  socket.on("disconnect", () => {
    // 1. 先从大厅移除（避免 onGameOver 把断线方误设为 lobby 造成状态闪烁）
    lobby.removePlayer(socket.id);
    // 2. 取消匹配中/队列中的位置（对方作为受害者重新入队）
    matchQueue.handleDisconnect(socket.id);
    // 3. 若在对局中 → 立即判负（onGameOver 仅把对方设回大厅）
    const room = findRoomBySocket(socket.id);
    if (room) {
      room.handleDisconnect(socket.id);
    }
    persist();
  });
});

// ====== 启动 ======

// 启动时审计上次持久化状态（socket 会话已失效，不做恢复，仅记录）
const saved = store.loadState();
if (saved) {
  console.log(
    `[store] 上次状态: ${saved.players.length} 玩家, ${saved.pending.length} 等待确认, ${saved.rooms.length} 房间 (保存于 ${new Date(saved.savedAt).toLocaleString()})`
  );
}
const gameCount = store.loadGames().length;
if (gameCount > 0) {
  console.log(`[store] 已有对局记录: ${gameCount} 局（上限 ${GAME_RECORD_LIMIT} 局）`);
}

// 优雅退出：立即落盘未写入的活跃状态
for (const sig of ["SIGINT", "SIGTERM"] as const) {
  process.on(sig, () => {
    console.log(`\n[warhorn-server] 收到 ${sig}，保存状态并退出`);
    store.flushStateSync();
    process.exit(0);
  });
}

httpServer.listen(PORT, () => {
  console.log(`[warhorn-server] listening on http://localhost:${PORT}`);
});

export { app, io };
