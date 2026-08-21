// 联机流程集成测试：用 socket.io-client 模拟两个玩家完整走一遍匹配+对局
// 用法：npx tsx packages/server/tests/online_flow.test.ts
//
// 验证：
//   1. 双方加入大厅 → lobby:update 推送在线人数=2
//   2. 双方点击匹配 → 双方收到 match:found
//   3. 双方确认 → 双方收到 game:start
//   4. 黑方落子 → 双方收到 game:update
//   5. 白方落子 → 双方收到 game:update
//   6. 双方连续虚手 → 收到 game:over

import { io as ioc, type Socket } from "socket.io-client";
import {
  ClientEvent, ServerEvent,
  type LobbyUpdatePayload, type MatchFoundPayload,
  type GameStartPayload, type GameUpdatePayload,
  type GameOverPayload, type TimeUpdatePayload,
  type ErrorPayload,
} from "@warhorn/shared";

const SERVER = "http://localhost:3000";
const TIMEOUT = 5000;

function makeClient(name: string): Promise<Socket> {
  return new Promise((resolve, reject) => {
    const s = ioc(SERVER, { transports: ["websocket"] });
    s.on("connect", () => {
      s.emit(ClientEvent.LOBBY_JOIN, { name });
      resolve(s);
    });
    s.on("connect_error", (e: Error) => reject(e));
    setTimeout(() => reject(new Error(`${name} connect timeout`)), TIMEOUT);
  });
}

function waitFor<T>(socket: Socket, event: string, filter?: (p: any) => boolean): Promise<T> {
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error(`timeout waiting ${event}`)), TIMEOUT);
    const handler = (p: any) => {
      if (filter && !filter(p)) return;
      clearTimeout(t);
      socket.off(event, handler);
      resolve(p as T);
    };
    socket.on(event, handler);
  });
}

async function main(): Promise<void> {
  console.log("=== 联机对战流程测试 ===\n");

  // 1. 双方加入大厅
  console.log("[1] 玩家A、B 加入大厅");
  const a = await makeClient("黑棋玩家A");
  const b = await makeClient("白棋玩家B");
  console.log("    A.socketId =", a.id);
  console.log("    B.socketId =", b.id);

  // 等 A 收到 lobby:update 在线人数=2
  // 注意：A 加入时 onlineCount=1（A 错过），B 加入后 A 应收到 onlineCount=2
  const lobbyA = await waitFor<LobbyUpdatePayload>(a, ServerEvent.LOBBY_UPDATE);
  console.log("    A 收到 lobby:update onlineCount =", lobbyA.onlineCount, "matchingCount =", lobbyA.matchingCount);
  // 如果第一次收到 onlineCount=1（A 自己加入），再等一次
  if (lobbyA.onlineCount < 2) {
    const lobbyA2 = await waitFor<LobbyUpdatePayload>(a, ServerEvent.LOBBY_UPDATE, (p) => p.onlineCount >= 2);
    console.log("    A 再次收到 lobby:update onlineCount =", lobbyA2.onlineCount);
  }

  // 2. 双方点击匹配
  console.log("\n[2] 双方点击匹配");
  const foundAP = waitFor<MatchFoundPayload>(a, ServerEvent.MATCH_FOUND);
  const foundBP = waitFor<MatchFoundPayload>(b, ServerEvent.MATCH_FOUND);
  a.emit(ClientEvent.MATCH_REQUEST);
  b.emit(ClientEvent.MATCH_REQUEST);
  const foundA = await foundAP;
  const foundB = await foundBP;
  console.log("    A 收到 match:found roomId =", foundA.roomId, "ownColor =", foundA.ownColor, "opp =", foundA.opponentName);
  console.log("    B 收到 match:found roomId =", foundB.roomId, "ownColor =", foundB.ownColor, "opp =", foundB.opponentName);
  if (foundA.roomId !== foundB.roomId) throw new Error("roomId 不一致");
  if (foundA.ownColor === foundB.ownColor) throw new Error("双方颜色相同");

  // 3. 双方确认
  console.log("\n[3] 双方确认匹配");
  const startAP = waitFor<GameStartPayload>(a, ServerEvent.GAME_START);
  const startBP = waitFor<GameStartPayload>(b, ServerEvent.GAME_START);
  a.emit(ClientEvent.MATCH_CONFIRM);
  b.emit(ClientEvent.MATCH_CONFIRM);
  const startA = await startAP;
  const startB = await startBP;
  console.log("    A 收到 game:start ownColor =", startA.ownColor, "黑=", startA.blackName, "白=", startA.whiteName);
  console.log("    B 收到 game:start ownColor =", startB.ownColor);

  const blackSocket = startA.ownColor === 1 ? a : b;
  const whiteSocket = startA.ownColor === 1 ? b : a;
  const blackName = startA.ownColor === 1 ? "A" : "B";
  const whiteName = startA.ownColor === 1 ? "B" : "A";
  console.log(`    黑方 = ${blackName}, 白方 = ${whiteName}`);

  // 4. 黑方落子（布局阶段，必须落己方领土：黑方领土为 row 0..8）
  console.log("\n[4] 黑方布局落子 (3,3)");
  const upd1A = waitFor<GameUpdatePayload>(a, ServerEvent.GAME_UPDATE);
  const upd1B = waitFor<GameUpdatePayload>(b, ServerEvent.GAME_UPDATE);
  blackSocket.emit(ClientEvent.MOVE_PLACE, { row: 3, col: 3 });
  const u1a = await upd1A;
  const u1b = await upd1B;
  console.log("    A 收到 game:update currentTurn =", u1a.currentTurn, "placed =", u1a.outcome.placed);
  console.log("    B 收到 game:update currentTurn =", u1b.currentTurn);
  if (!u1a.outcome.ok || !u1a.outcome.placed) throw new Error("黑方落子失败");
  if (u1a.outcome.placed!.row !== 3 || u1a.outcome.placed!.col !== 3) throw new Error("落子位置错误");

  // 5. 白方布局落子（白方领土为 row 10..18）
  console.log("\n[5] 白方布局落子 (15,15)");
  const upd2A = waitFor<GameUpdatePayload>(a, ServerEvent.GAME_UPDATE);
  const upd2B = waitFor<GameUpdatePayload>(b, ServerEvent.GAME_UPDATE);
  whiteSocket.emit(ClientEvent.MOVE_PLACE, { row: 15, col: 15 });
  const u2a = await upd2A;
  const u2b = await upd2B;
  console.log("    A 收到 game:update currentTurn =", u2a.currentTurn);
  console.log("    B 收到 game:update currentTurn =", u2b.currentTurn);

  // 6. 等待计时器推送
  console.log("\n[6] 等待 time:update 推送");
  const timeP = waitFor<TimeUpdatePayload>(a, ServerEvent.TIME_UPDATE);
  const time = await timeP;
  console.log("    A 收到 time:update black =", time.black.main, "white =", time.white.main);
  if (time.black.main <= 0 || time.white.main <= 0) throw new Error("计时器异常");

  // 7. 非法：白方在黑方回合落子（此时 currentTurn=BLACK）
  console.log("\n[7] 白方在黑方回合落子（应失败）");
  const errP = waitFor<ErrorPayload>(whiteSocket, ServerEvent.ERROR);
  whiteSocket.emit(ClientEvent.MOVE_PLACE, { row: 16, col: 16 });
  const err = await errP;
  console.log("    收到 error:", err.message);
  if (!err.message.includes("非该方行棋")) throw new Error(`期望"非该方行棋"，实际 "${err.message}"`);

  // 8. 终局：连续虚手（黑方虚手 → 白方虚手 → 应触发 game:over）
  console.log("\n[8] 黑方虚手 → 白方虚手 → 应触发 game:over");
  const overAP = waitFor<GameOverPayload>(a, ServerEvent.GAME_OVER);
  const overBP = waitFor<GameOverPayload>(b, ServerEvent.GAME_OVER);
  blackSocket.emit(ClientEvent.MOVE_PASS);
  await waitFor<GameUpdatePayload>(blackSocket, ServerEvent.GAME_UPDATE);
  // 白方虚手 → 连续2次虚手 → game:over
  whiteSocket.emit(ClientEvent.MOVE_PASS);
  const overA = await overAP;
  const overB = await overBP;
  console.log("    A 收到 game:over winner =", overA.winner, "reason =", overA.reason);
  console.log("    B 收到 game:over winner =", overB.winner);

  // 9. 关闭
  a.disconnect();
  b.disconnect();
  console.log("\n=== 全部通过 ===");
}

main().catch((e) => {
  console.error("\n!!! 测试失败:", e.message);
  process.exit(1);
});
