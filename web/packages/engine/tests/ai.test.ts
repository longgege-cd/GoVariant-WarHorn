// AI 对手单元测试
// 运行: node --test --import tsx tests/ai.test.ts
import assert from "node:assert";
import { describe, it } from "node:test";
import { GameSession } from "../src/GameSession.js";
import { Color } from "../src/Const.js";
import {
  AIEngine,
  AI_DIFFICULTY_NAMES,
  getAIConfig,
  AIDifficulty,
} from "../src/AI.js";

describe("AI 难度配置", () => {
  it("三档难度配置递增（深度/候选/思考时间）", () => {
    const easy = getAIConfig(AIDifficulty.EASY);
    const normal = getAIConfig(AIDifficulty.NORMAL);
    const hard = getAIConfig(AIDifficulty.HARD);
    assert.ok(easy.refinePly < normal.refinePly && normal.refinePly < hard.refinePly);
    assert.ok(easy.maxCandidates < normal.maxCandidates && normal.maxCandidates < hard.maxCandidates);
    assert.ok(easy.thinkTimeMs < normal.thinkTimeMs && normal.thinkTimeMs < hard.thinkTimeMs);
  });

  it("难度名称非空且互不相同", () => {
    const names = new Set(
      [AIDifficulty.EASY, AIDifficulty.NORMAL, AIDifficulty.HARD].map(
        (d) => AI_DIFFICULTY_NAMES[d]
      )
    );
    assert.strictEqual(names.size, 3);
  });
});

describe("AIEngine 正式阶段", () => {
  it("三档难度均选择合法落子", () => {
    for (const d of [AIDifficulty.EASY, AIDifficulty.NORMAL, AIDifficulty.HARD]) {
      const s = new GameSession({ enableDeployPhase: false });
      s.playMove(Color.BLACK, 9, 9);
      const ai = new AIEngine(Color.WHITE, d);
      const move = ai.chooseMove(s);
      assert.strictEqual(move.type, "move", `难度 ${d} 应落子而非虚手`);
      const out = s.playMove(Color.WHITE, move.row, move.col);
      assert.ok(out.ok, `难度 ${d} 落子不合法: ${out.reason}`);
      assert.strictEqual(s.board.getAt(move.row, move.col), Color.WHITE);
    }
  });

  it("大师难度（迭代加深+PVS+置换表）选择合法落子", () => {
    const s = new GameSession({ enableDeployPhase: false });
    s.playMove(Color.BLACK, 9, 9);
    const ai = new AIEngine(Color.WHITE, AIDifficulty.MASTER);
    const move = ai.chooseMove(s);
    assert.strictEqual(move.type, "move", "大师应落子而非虚手");
    const out = s.playMove(Color.WHITE, move.row, move.col);
    assert.ok(out.ok, `大师落子不合法: ${out.reason}`);
    assert.strictEqual(s.board.getAt(move.row, move.col), Color.WHITE);
  });

  it("无合法点时返回虚手", () => {
    // 构造全满棋盘（无任何空点），白方无合法落子 → 应虚手
    const s = new GameSession({ enableDeployPhase: false });
    for (let r = 0; r < s.board.size; r++) {
      for (let c = 0; c < s.board.size; c++) {
        s.board.setAt(r, c, Color.BLACK);
      }
    }
    s.toMove = Color.WHITE;
    const ai = new AIEngine(Color.WHITE, AIDifficulty.EASY);
    const move = ai.chooseMove(s);
    assert.strictEqual(move.type, "pass");
  });
});

describe("AIEngine 布局阶段", () => {
  it("AI 执白布局落子于己方领土", () => {
    const s = new GameSession({ enableDeployPhase: true });
    // 黑方先手布局 (7,9)，轮到白方 AI
    const blackOut = s.playMove(Color.BLACK, 7, 9);
    assert.ok(blackOut.ok);
    assert.ok(s.isInDeployPhase());
    const ai = new AIEngine(Color.WHITE, AIDifficulty.EASY);
    const move = ai.chooseMove(s);
    assert.strictEqual(move.type, "move");
    assert.ok(move.row >= 10 && move.row <= 18, `白方布局应落在己方领土，实际 row=${move.row}`);
    const out = s.playMove(Color.WHITE, move.row, move.col);
    assert.ok(out.ok, out.reason);
  });
});

describe("AI 对局模拟", () => {
  it("AI 与随机黑方对弈 60 手无非法落子", () => {
    const s = new GameSession({ enableDeployPhase: false });
    const ai = new AIEngine(Color.WHITE, AIDifficulty.EASY);
    for (let i = 0; i < 60 && !s.gameOver; i++) {
      if (s.toMove === Color.WHITE) {
        const move = ai.chooseMove(s);
        if (move.type === "pass") {
          const out = s.doPass(Color.WHITE);
          assert.ok(out.ok);
        } else {
          const out = s.playMove(Color.WHITE, move.row, move.col);
          assert.ok(out.ok, `AI 第 ${i} 手非法: ${out.reason}`);
        }
      } else {
        // 随机黑方：随机取点，非法则尝试其它空点，全不可行则虚手
        const empties: Array<[number, number]> = [];
        for (let r = 0; r < s.board.size; r++) {
          for (let c = 0; c < s.board.size; c++) {
            if (s.board.isEmpty(r, c)) empties.push([r, c]);
          }
        }
        if (empties.length === 0) {
          s.doPass(Color.BLACK);
          continue;
        }
        let placed = false;
        for (let k = 0; k < empties.length && !placed; k++) {
          const [r, c] = empties[Math.floor(Math.random() * empties.length)];
          const o = s.playMove(Color.BLACK, r, c);
          if (o.ok) placed = true;
        }
        if (!placed) s.doPass(Color.BLACK);
      }
    }
    assert.ok(true, "对局应能持续进行且 AI 不产生非法落子");
  });
});

// GNU Go "worthwhile capture" 回归：不打无益追打、不救孤军深入之死子。
// 构造中盘局面（≥12 子进入 midgame），验证 AI 不会把棋下在"追打/逃气"点上做无意义纠缠。
describe("AI 值得性判定（追打/逃气）", () => {
  // 棋盘上放置若干棋子，返回对局。棋子直接 setAt 放置（构造专用局面）。
  function buildSession(black: Array<[number, number]>, white: Array<[number, number]>): GameSession {
    const s = new GameSession({ enableDeployPhase: false });
    for (const [r, c] of black) s.board.setAt(r, c, Color.BLACK);
    for (const [r, c] of white) s.board.setAt(r, c, Color.WHITE);
    s.toMove = Color.BLACK;
    return s;
  }

  it("不打无益追打：开放地带孤子（不贴墙、4气）不值得追", () => {
    // 白孤子 (5,9) 位于黑方半场中央开放地带，四面皆空（4 气），不贴任何黑棋、
    // 不贴墙/前线 → 追打无法围堵，AI 不应浪费一手去围它（该走布局要点）。
    const s = buildSession(
      [[3, 3], [3, 15], [5, 5], [5, 13], [7, 7]],
      [[15, 3], [15, 15], [13, 5], [13, 13], [11, 9], [5, 9]]
    );
    // 白孤子应恰好 1 子且 4 气（开放地带，不贴黑棋）
    assert.strictEqual(s.board.groupAt(5, 9).stones.length, 1);
    assert.strictEqual(s.board.liberties(s.board.groupAt(5, 9).stones).length, 4);
    const ai = new AIEngine(Color.BLACK, AIDifficulty.NORMAL);
    const move = ai.chooseMove(s);
    assert.strictEqual(move.type, "move");
    assert.ok(
      !(move.row === 6 && move.col === 9) && !(move.row === 5 && move.col === 10),
      `不应追打开放孤子，却选了 (${move.row},${move.col}) [${move.reason}]`
    );
  });

  it("不救孤军：深入对方半场且无己方近邻的 2 气组群放弃", () => {
    // 黑孤子 (15,9) 深入白方半场，气为 (16,9)/(15,10)，无己方棋子可连 →
    // 救它得不偿失，AI 不应在 (16,9) 或 (15,10) 落子（放弃而非逃气纠缠）。
    const s = buildSession(
      [[3, 3], [3, 15], [5, 5], [5, 13], [7, 7], [15, 9]],
      [[15, 3], [15, 15], [13, 5], [13, 13], [11, 9], [14, 9], [15, 8]]
    );
    assert.strictEqual(s.board.groupAt(15, 9).stones.length, 1);
    const ai = new AIEngine(Color.BLACK, AIDifficulty.NORMAL);
    const move = ai.chooseMove(s);
    assert.strictEqual(move.type, "move");
    assert.ok(
      !(move.row === 16 && move.col === 9) && !(move.row === 15 && move.col === 10),
      `不应救深入敌阵的孤子，却选了 (${move.row},${move.col}) [${move.reason}]`
    );
  });
});
