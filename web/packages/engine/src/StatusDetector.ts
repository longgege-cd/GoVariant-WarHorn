// 盘面状态检测：打吃（atari）组群 + 势力热力图
// 纯逻辑，无 UI 依赖，供 UI 层渲染辅助使用

import { BoardModel, type Group, type Point } from "./BoardModel.js";
import { Color } from "./Const.js";

// 打吃（剩最后一口气）的组群：所有气数 == 1 的连通块
// 对应围棋 atari：下一手可被提吃
export function atariGroups(board: BoardModel): Group[] {
  return board.allGroups().filter((g) => board.libertyCount(g.stones) === 1);
}

// 打吃组群石头索引集合（idx = row*size+col），便于渲染
export function atariStoneSet(board: BoardModel): Set<number> {
  const size = board.size;
  const out = new Set<number>();
  for (const g of atariGroups(board)) {
    for (const s of g.stones) out.add(s.row * size + s.col);
  }
  return out;
}

// 势力热力图：对每个空点计算双方影响力差值
//   返回 Float32Array(size*size)，正值 = 黑方势力强，负值 = 白方势力强，0 = 均衡
// 算法：每个棋子沿上/下/左/右四个方向延伸，遇到棋子或边界停止，
//   距离越远影响力按权重递减（围棋传统 influence 计算简化版）
export function influenceMap(board: BoardModel): Float32Array {
  const n = board.size;
  const map = new Float32Array(n * n);
  // 距离权重（1~6 格）：紧邻最强，越远越弱
  const weights = [1.0, 0.65, 0.4, 0.22, 0.1, 0.05];
  const dirs: Array<[number, number]> = [[-1, 0], [1, 0], [0, -1], [0, 1]];

  for (let r = 0; r < n; r++) {
    for (let c = 0; c < n; c++) {
      const v = board.getAt(r, c);
      if (v === Color.EMPTY) continue;
      const sign = v === Color.BLACK ? 1 : -1;
      for (const [dr, dc] of dirs) {
        let d = 1;
        for (; d <= weights.length; d++) {
          const nr = r + dr * d;
          const nc = c + dc * d;
          if (!board.inBounds(nr, nc)) break;
          const idx = nr * n + nc;
          if (board.grid[idx] !== Color.EMPTY) break; // 被棋子阻挡
          map[idx] += sign * weights[d - 1];
        }
      }
    }
  }
  return map;
}

// 势力热力图归一化强度（供渲染：0~1，正值黑方 / 负值白方）
export interface InfluenceRender {
  map: Float32Array;
  maxAbs: number;
}

export function influenceRenderData(board: BoardModel): InfluenceRender {
  const map = influenceMap(board);
  let maxAbs = 0;
  for (let i = 0; i < map.length; i++) {
    const a = Math.abs(map[i]);
    if (a > maxAbs) maxAbs = a;
  }
  return { map, maxAbs };
}

export type { Point };
