import { test } from "node:test";
import assert from "node:assert/strict";
import {
  Color,
  getPuzzleList,
  buildPuzzleBoard,
  isCorrectNext,
  puzzleSolved,
  nextHintMoves,
} from "../src/index.js";

test("题库：30 题，难度递增（1~4），每题含非空正解序列", () => {
  const list = getPuzzleList();
  assert.equal(list.length, 30);
  // 金字塔式递增：简单5 / 普通7 / 困难8 / 大师10
  const expect = (i) => (i < 5 ? 1 : i < 12 ? 2 : i < 20 ? 3 : 4);
  list.forEach((p, i) => assert.equal(p.level, expect(i), `第${i + 1}关难度`));
  for (const p of list) {
    assert.ok(p.sequences.length > 0, `${p.source} 无正解序列`);
    for (const seq of p.sequences) {
      assert.ok(seq.length >= 1);
      for (const [r, c] of seq) assert.ok(r >= 0 && r < 19 && c >= 0 && c < 19, `越界 ${p.source}`);
    }
  }
});

test("buildPuzzleBoard：初始黑/白子正确摆放", () => {
  const p = getPuzzleList()[0]; // ggg-easy-01
  const b = buildPuzzleBoard(p);
  for (const [r, c] of p.black) assert.equal(b.grid[r * 19 + c], Color.BLACK);
  for (const [r, c] of p.white) assert.equal(b.grid[r * 19 + c], Color.WHITE);
});

test("easy-01 判定：答对才过关，答错不算", () => {
  const p = getPuzzleList()[0]; // ggg-easy-01 执黑
  assert.equal(p.solver, Color.BLACK);
  const seqs = p.sequences; // 两条正解：rs→ns / rs→ps
  assert.ok(seqs.length >= 2);

  // 正手 rs = [18,17]
  assert.ok(isCorrectNext(p, [], [18, 17]));
  // 空手 + 错手：非正解拒绝
  assert.ok(!isCorrectNext(p, [], [18, 18]));
  assert.ok(!isCorrectNext(p, [], [3, 3]));
  // 只走一手 rs 仍未过关
  assert.ok(!puzzleSolved(p, [[18, 17]]));
  // 没有落子时提示下一手应为 rs
  const hint = nextHintMoves(p, []);
  assert.deepEqual(new Set(hint.map((x) => x[0] * 19 + x[1])), new Set([[18, 17][0] * 19 + [18, 17][1]]));

  // 走对完整正解 ns = [18,13] → 过关
  assert.ok(isCorrectNext(p, [[18, 17]], [18, 13]));
  assert.ok(puzzleSolved(p, [[18, 17], [18, 13]]));
  // 另一条正解 ps = [18,15] 同样过关
  assert.ok(isCorrectNext(p, [[18, 17]], [18, 15]));
  assert.ok(puzzleSolved(p, [[18, 17], [18, 15]]));
  // 第二手走错 → 不构成正解前缀
  assert.ok(!isCorrectNext(p, [[18, 17]], [18, 14]));
});

test("题库每题首手在当前空口内存在正解且至少一手", () => {
  for (const p of getPuzzleList()) {
    const firsts = nextHintMoves(p, []);
    assert.ok(firsts.length > 0, `${p.source} 首手无正解`);
  }
});

test("全题库无坏题：序列落子不与 setup 冲突、不重复、不越界", () => {
  for (const p of getPuzzleList()) {
    const occ = new Set([...p.black, ...p.white].map(([r, c]) => r * 19 + c));
    for (const seq of p.sequences) {
      const seen = new Set<number>();
      for (const [r, c] of seq) {
        const k = r * 19 + c;
        assert.ok(!occ.has(k), `${p.source} 序列 ${JSON.stringify(seq)} 落子(${r},${c}) 与 setup 冲突`);
        assert.ok(!seen.has(k), `${p.source} 序列 ${JSON.stringify(seq)} 重复落子(${r},${c})`);
        seen.add(k);
      }
    }
  }
});