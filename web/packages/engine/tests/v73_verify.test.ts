import { test } from "node:test";
import assert from "node:assert";
import { Color } from "../src/Const.js";
import { BoardModel } from "../src/BoardModel.js";
import { ScoreCalculator, makeCounters } from "../src/ScoreCalculator.js";

// v7.3 规则回归：效率奖励 / 活子分取消 / 歼灭+3 / 围困+2

// 黑在白方半场(row>=10)围出 4 空点 → 围空8 + 效率奖励2；活子分恒为0
test("v7.3 效率奖励 / 活子分取消", () => {
  const board = new BoardModel(19);
  const r = 19;
  // 白方半场内 (row11..14, col8..11) 黑子围成框，内部空点 row12-13, col9-10
  for (const c of [9, 10]) {
    board.grid[r * 11 + c] = Color.BLACK;
    board.grid[r * 14 + c] = Color.BLACK;
  }
  for (let row = 11; row <= 14; row++) {
    board.grid[r * row + 8] = Color.BLACK;
    board.grid[r * row + 11] = Color.BLACK;
  }
  const res = ScoreCalculator.compute(board, makeCounters());
  const b = res.black;
  assert.strictEqual(b.occupationEfficiency, 2, "4有效空点应得效率奖励2");
  assert.strictEqual(b.occupationTerritory, 8, "4空点围空分8");
  assert.strictEqual(b.occupationLive, 0, "活子分已取消恒为0");
});

// 歼灭分 +3/子，围困分 +2/子（己境/边境）
test("v7.3 歼灭+3 / 围困+2", () => {
  const counters = makeCounters();
  counters.set(Color.BLACK, { annihilate: 1, normalLost: 1, specialLost: 0 });
  const board = new BoardModel(19);
  const r = 19;
  // 白子 (8,9) 在黑方领土被黑完全围住（被围困）
  board.grid[r * 8 + 9] = Color.WHITE;
  const ring = [
    [7, 8], [7, 9], [7, 10], [8, 10], [9, 10], [9, 9], [9, 8], [8, 8],
  ];
  for (const [rr, cc] of ring) board.grid[r * rr + cc] = Color.BLACK;
  const res = ScoreCalculator.compute(board, counters);
  assert.strictEqual(res.black.defenseAnnihilate, 3, "歼灭分+3/子");
  assert.strictEqual(res.black.defenseSiege, 2, "围困分+2/子");
});