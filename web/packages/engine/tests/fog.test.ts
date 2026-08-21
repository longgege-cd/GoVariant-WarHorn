import { test } from "node:test";
import assert from "node:assert";
import { Color } from "../src/Const.js";
import { BoardModel } from "../src/BoardModel.js";
import { visionCells, visibleGrid, fogCells } from "../src/FogUtils.js";
import { GameSession } from "../src/GameSession.js";

// 战争迷雾（可选规则）回归：视图 / 遭遇战 / 黎明

// 视野：以己方棋子为中心，曼哈顿距离≤2 可见
test("fog 视野：曼哈顿≤2", () => {
  const board = new BoardModel(19);
  board.grid[10 * 19 + 10] = Color.BLACK;
  const vis = visionCells(Color.BLACK, board);
  assert.ok(vis.has(10 * 19 + 10), "己方棋子本身可见");
  assert.ok(vis.has(10 * 19 + 12), "同列距离2可见");
  assert.ok(vis.has(12 * 19 + 10), "同行距离2可见");
  assert.ok(vis.has(11 * 19 + 11), "对角曼哈顿2可见");
  assert.ok(!vis.has(10 * 19 + 15), "距离5不可见");
});

// 可见网格：迷雾下隐藏视野外对方棋子，保护己方棋子
test("fog 可见网格隐藏视野外敌子", () => {
  const board = new BoardModel(19);
  board.grid[2 * 19 + 2] = Color.BLACK; // 黑视野原点
  board.grid[16 * 19 + 16] = Color.WHITE; // 远处敌子（黑视线外）
  const view = visibleGrid(board.grid, Color.BLACK, board, true);
  assert.strictEqual(view[16 * 19 + 16], Color.EMPTY, "视野外白子被隐藏");
  assert.strictEqual(view[2 * 19 + 2], Color.BLACK, "己方棋子保留");
  // 无迷雾时原样保留
  const plain = visibleGrid(board.grid, Color.BLACK, board, false);
  assert.strictEqual(plain[16 * 19 + 16], Color.WHITE, "无迷雾时敌子可见");
});

// 遭遇战：落子与隐藏棋重叠 → 现形 + 弹子
test("fog 遭遇战：现形 + 弹子", () => {
  const s = new GameSession({ enableDeployPhase: false, fogEnabled: true });
  // 黑(2,2)建视野中心，白(16,16)在其视线外
  assert.ok(s.playMove(Color.BLACK, 2, 2).ok);
  assert.ok(s.playMove(Color.WHITE, 16, 16).ok);
  // 黑在迷雾下看不到(16,16)，落该点触发遭遇战
  const res = s.playMove(Color.BLACK, 16, 16);
  assert.strictEqual(res.ok, true);
  assert.strictEqual(res.encounter, true);
  assert.deepStrictEqual(res.revealed, [{ row: 16, col: 16 }]);
  assert.ok(res.placed && res.placed.row >= 0, "弹子成功落位");
});

// 黎明：第30手后迷雾消散
test("fog 黎明：第30手后全盘可见", () => {
  const s = new GameSession({ enableDeployPhase: false, fogEnabled: true });
  assert.strictEqual(s.isFogActive(), true, "开局迷雾生效");
  // 交替落子到第30手
  let ply = 0;
  let lastDawn = false;
  while (ply < 30) {
    const color = ply % 2 === 0 ? Color.BLACK : Color.WHITE;
    // 依序填对角线，保证合法
    const row = Math.floor(ply / 2) % 19;
    const col = ply % 19;
    const res = s.playMove(color, row, col);
    if (res.dawn) lastDawn = true;
    ply = res.ply ?? ply + 1;
  }
  assert.strictEqual(s.ply, 30);
  assert.strictEqual(s.isFogActive(), false, "第30手后迷雾消散");
  // 迷雾控制相关方法在非迷雾态应原样返回
  assert.strictEqual(s.fogCellsOf(Color.BLACK).size, 0, "迷雾消散无雾区");
});