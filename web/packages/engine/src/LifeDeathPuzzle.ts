// 死活题闯关模块：基于 GoGameGuru 真实死活题 SGF（含正解树），共 30 关，难度递增
// 判定口径 =「正解序列匹配」：玩家按正解逐手落子，答对（走完某条完整正解）才算过关
//   - 玩家只能在空点落子；当前手落在任一正解下一手上 → 正确并保留
//   - 落错点 → 判错，不落子，需重试（答对才能进入下一题，无法跳过）
// 难度分级：1简单(易) / 2普通(中) / 3困难(难) / 4大师(难·加深)

import { Color } from "./Const.js";
import { BoardModel } from "./BoardModel.js";
import { TSUMEGO_LIST, type TsumegoSeqEntry } from "./puzzles_tsumego.js";

export type LifeDeathPuzzle = TsumegoSeqEntry;
export { TSUMEGO_LIST };

export function getPuzzleList(): LifeDeathPuzzle[] {
  return TSUMEGO_LIST;
}

// 重建初始棋盘（仅固定棋子）
export function buildPuzzleBoard(puzzle: LifeDeathPuzzle): BoardModel {
  const b = new BoardModel(19);
  for (const [r, c] of puzzle.black) b.setAt(r, c, Color.BLACK);
  for (const [r, c] of puzzle.white) b.setAt(r, c, Color.WHITE);
  return b;
}

function seqKey(p: [number, number]): number {
  return p[0] * 19 + p[1];
}

// pick 是否 seq 的前缀
function isSeqPrefix(pick: Array<[number, number]>, seq: Array<[number, number]>): boolean {
  if (pick.length > seq.length) return false;
  for (let i = 0; i < pick.length; i++) {
    if (seqKey(pick[i]) !== seqKey(seq[i])) return false;
  }
  return true;
}

// 落子 move 后是否仍走在某条正解上（答对下一步）
export function isCorrectNext(
  puzzle: LifeDeathPuzzle,
  placed: Array<[number, number]>,
  move: [number, number]
): boolean {
  const pick = [...placed, move];
  return puzzle.sequences.some((seq) => isSeqPrefix(pick, seq));
}

// 达成条件：某条完整正解已被玩家走完
export function puzzleSolved(
  puzzle: LifeDeathPuzzle,
  placed: Array<[number, number]>
): boolean {
  return puzzle.sequences.some(
    (seq) => seq.length === placed.length && isSeqPrefix(placed, seq)
  );
}

// 提示：返回当前应走的全部正确点（所有以已落子为前缀的正解序列的下一手并集）
export function nextHintMoves(
  puzzle: LifeDeathPuzzle,
  placed: Array<[number, number]>
): Array<[number, number]> {
  const seen = new Set<number>();
  const out: Array<[number, number]> = [];
  for (const seq of puzzle.sequences) {
    if (!isSeqPrefix(placed, seq)) continue;
    const next = seq[placed.length];
    if (!next) continue;
    const k = seqKey(next);
    if (!seen.has(k)) {
      seen.add(k);
      out.push(next);
    }
  }
  return out;
}