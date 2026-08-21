// 战争迷雾（可选规则）视图工具
// 规则书 v7.3 §战争迷雾：从布局阶段起全盘迷雾，仅己方棋子周围曼哈顿距离≤2 可见；
// 多子相邻视野合并；己方棋子永远可见，对方棋子仅在视野内可见；第30手黎明全盘可见。

import { BOARD_SIZE, Color, opponent, FOG_VISION_RADIUS } from "./Const.js";
import { BoardModel } from "./BoardModel.js";

// 计算 color 方的可见区域：以每颗己方棋子为中心、曼哈顿距离≤R 的所有交叉点。
// 多颗己方棋子相邻时视野自动合并（Set 求并集）；己方棋子本身（距离0）恒在视野内。
export function visionCells(color: Color, board: BoardModel, radius: number = FOG_VISION_RADIUS): Set<number> {
  const size = board.size;
  const vis = new Set<number>();
  for (let r = 0; r < size; r++) {
    for (let c = 0; c < size; c++) {
      if (board.getAt(r, c) !== color) continue;
      for (let dr = -radius; dr <= radius; dr++) {
        const nd = radius - Math.abs(dr);
        for (let dc = -nd; dc <= nd; dc++) {
          const nr = r + dr;
          const nc = c + dc;
          if (nr < 0 || nr >= size || nc < 0 || nc >= size) continue;
          vis.add(nr * size + nc);
        }
      }
    }
  }
  return vis;
}

// 生成可见网格：fogActive 时，把视野外的对方棋子置为 EMPTY（隐藏），
// 返回新 Uint8Array（不修改原网格）。fogActive=false 时原样返回一份拷贝。
export function visibleGrid(
  grid: Uint8Array,
  color: Color,
  board: BoardModel,
  fogActive: boolean,
  revealed: Set<number> = new Set()
): Uint8Array {
  const out = new Uint8Array(grid);
  if (!fogActive) return out;
  const size = board.size;
  const enemy = opponent(color);
  const vis = visionCells(color, board);
  for (let r = 0; r < size; r++) {
    for (let c = 0; c < size; c++) {
      const idx = r * size + c;
      if (out[idx] !== enemy) continue;
      if (!vis.has(idx) && !revealed.has(idx)) out[idx] = Color.EMPTY;
    }
  }
  return out;
}

// 迷雾覆盖区域：fogActive 时，视野外所有交叉点的索引集合（渲染半透明浅灰迷雾用）。
// 已现形（revealed）的位置不再被迷雾掩盖。
export function fogCells(
  board: BoardModel,
  color: Color,
  fogActive: boolean,
  revealed: Set<number> = new Set()
): Set<number> {
  const fog = new Set<number>();
  if (!fogActive) return fog;
  const size = board.size;
  const vis = visionCells(color, board);
  const total = size * size;
  for (let idx = 0; idx < total; idx++) {
    if (!vis.has(idx) && !revealed.has(idx)) fog.add(idx);
  }
  return fog;
}