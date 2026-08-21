// 围困判定：迭代不动点求解全盘死活（v5.3/v6.2）
// 规则要点：
//   - 围困 = 被有效包围 + 无两眼 + 圈内可合法落子空点 < 4
//   - 有效包围圈 = 由对方活棋围成（围困棋子不能构成有效包围圈）
//   - 死活相互依赖 → 全盘用 solve_dead_alive() 迭代不动点求解
//   - 不存在双活：双方互相包围时各自独立判定
// 对应 GDScript c:\边境线\scripts\core\SiegeDetector.gd (497行)

import { Color, opponent } from "./Const.js";
import { BoardModel, Point, Group } from "./BoardModel.js";
import { GoRules, NO_KO } from "./GoRules.js";

export interface DeadAliveResult {
  alive: Group[];
  sieged: Group[];
}

export class SiegeDetector {
  // 全盘死活迭代求解（核心）
  static solveDeadAlive(board: BoardModel): DeadAliveResult {
    const groups = board.allGroups();
    if (groups.length === 0) return { alive: [], sieged: [] };

    const size = board.size;
    let siegedSet = new Set<number>(); // 组群首子 idx -> true
    const stateLog: Set<number>[] = []; // 每轮 siegedSet 深拷贝（循环检测用）
    const maxIter = groups.length + 4;

    for (let it = 0; it < maxIter; it++) {
      // 1. 构建每色「活棋墙」（围困组群不作墙）
      const oppWall = new Map<Color, Set<number>>();
      oppWall.set(Color.BLACK, new Set());
      oppWall.set(Color.WHITE, new Set());
      for (const g of groups) {
        if (siegedSet.has(g.stones[0].row * size + g.stones[0].col)) continue;
        const wall = oppWall.get(g.color)!;
        for (const s of g.stones) wall.add(s.row * size + s.col);
      }

      // 2. 每色外部集合（以该色活棋为墙）
      const outs = new Map<Color, Set<number>>();
      outs.set(Color.BLACK, SiegeDetector.computeOutsideByWall(board, oppWall.get(Color.BLACK)!));
      outs.set(Color.WHITE, SiegeDetector.computeOutsideByWall(board, oppWall.get(Color.WHITE)!));

      // 3. 判定每个组群死活（三条件全满足才围困）
      const newSieged = new Set<number>();
      for (const g of groups) {
        const gkey = g.stones[0].row * size + g.stones[0].col;
        const opp = opponent(g.color);
        const surrounded = SiegeDetector._isSurroundedByWall(
          board, g, oppWall.get(opp)!, outs.get(opp)!
        );
        if (!surrounded) continue;
        if (SiegeDetector.hasTwoTrueEyes(board, g)) continue;
        if (SiegeDetector.countLegalEmptyPoints(board, g, 4) >= 4) continue;
        newSieged.add(gkey);
      }

      // 4. 收敛检查
      if (SiegeDetector._sameSieged(siegedSet, newSieged)) {
        siegedSet = newSieged;
        break;
      }

      // 5. 循环检测（双活僵局）：取历史中围困最多者（保守判死）
      let cycled = false;
      for (const prev of stateLog) {
        if (SiegeDetector._sameSieged(prev, newSieged)) {
          siegedSet = SiegeDetector._maxSieged(stateLog);
          cycled = true;
          break;
        }
      }
      if (cycled) break;
      stateLog.push(new Set(newSieged));
      siegedSet = newSieged;
    }

    const res: DeadAliveResult = { alive: [], sieged: [] };
    for (const g of groups) {
      const gkey = g.stones[0].row * size + g.stones[0].col;
      if (siegedSet.has(gkey)) res.sieged.push(g);
      else res.alive.push(g);
    }
    return res;
  }

  // 单组群快速判定（v5.3 兼容接口，以对方全部棋子为墙）
  static isAlive(board: BoardModel, group: Group, outside?: Set<number>): boolean {
    // 优先级1：未被包围 → 活棋
    if (!SiegeDetector._isSurroundedByOpponent(board, group, outside)) return true;
    // 优先级2：被包围但合法空点≥4 → 活棋（短路：找到4个即返回）
    if (SiegeDetector.countLegalEmptyPoints(board, group, 4) >= 4) return true;
    // 优先级3：两眼 → 活棋
    if (SiegeDetector.hasTwoTrueEyes(board, group)) return true;
    return false;
  }

  static isSieged(board: BoardModel, group: Group, outside?: Set<number>): boolean {
    return !SiegeDetector.isAlive(board, group, outside);
  }

  // 两真眼判定
  static hasTwoTrueEyes(board: BoardModel, group: Group): boolean {
    if (group.stones.length === 0) return false;
    const size = board.size;
    // 1. 收集组群所有气
    const libs = board.liberties(group.stones);
    if (libs.length === 0) return false;

    // 2. 气域 R：从所有气出发，洪水填充所有相连空点
    const region = new Set<number>();
    const stack: number[] = [];
    for (const l of libs) {
      const idx = l.row * size + l.col;
      if (!region.has(idx)) { region.add(idx); stack.push(idx); }
    }
    while (stack.length > 0) {
      const idx = stack.pop()!;
      const r = Math.floor(idx / size);
      const c = idx % size;
      const dirs: Array<[number, number]> = [
        [r - 1, c], [r + 1, c], [r, c - 1], [r, c + 1],
      ];
      for (const [nr, nc] of dirs) {
        if (nr < 0 || nr >= size || nc < 0 || nc >= size) continue;
        const ni = nr * size + nc;
        if (board.grid[ni] !== Color.EMPTY) continue;
        if (!region.has(ni)) { region.add(ni); stack.push(ni); }
      }
    }

    // 3. 对 R 中每个空点判真眼，计数 ≥ 2 → 活棋
    const groupSet = new Set<number>();
    for (const s of group.stones) groupSet.add(s.row * size + s.col);
    let eyeCount = 0;
    for (const idx of region) {
      const r = Math.floor(idx / size);
      const c = idx % size;
      if (SiegeDetector._isTrueEye(board, r, c, groupSet, group.color)) eyeCount++;
      if (eyeCount >= 2) return true;
    }
    return false;
  }

  // 圈内可合法落子空点数（短路：达到 earlyReturnAt 即返回）
  static countLegalEmptyPoints(
    board: BoardModel,
    group: Group,
    earlyReturnAt: number = -1
  ): number {
    const size = board.size;
    const color = group.color;
    const opp = opponent(color);

    // 1. flooding 从组群出发（穿过空点+己方棋子，仅被对方棋子阻挡）
    const region = new Set<number>();
    const visited = new Set<number>();
    const stack: Array<[number, number]> = [];
    for (const s of group.stones) stack.push([s.row, s.col]);
    while (stack.length > 0) {
      const [r, c] = stack.pop()!;
      const idx = r * size + c;
      if (visited.has(idx)) continue;
      const v = board.grid[idx];
      if (v === opp) continue; // 对方棋子阻挡
      visited.add(idx);
      if (v === Color.EMPTY) region.add(idx);
      const dirs: Array<[number, number]> = [
        [r - 1, c], [r + 1, c], [r, c - 1], [r, c + 1],
      ];
      for (const [nr, nc] of dirs) {
        if (nr < 0 || nr >= size || nc < 0 || nc >= size) continue;
        const ni = nr * size + nc;
        if (visited.has(ni)) continue;
        if (board.grid[ni] === opp) continue;
        stack.push([nr, nc]);
      }
    }

    // 2. 统计可合法落子的空点
    let count = 0;
    for (const idx of region) {
      const r = Math.floor(idx / size);
      const c = idx % size;
      if (SiegeDetector._isLegalMove(board, r, c, color)) {
        count++;
        if (earlyReturnAt > 0 && count >= earlyReturnAt) return count;
      }
    }
    return count;
  }

  // ====== 有效包围圈判定（v6.2 核心）======

  // 组群是否被给定墙完全封闭
  private static _isSurroundedByWall(
    board: BoardModel,
    group: Group,
    wallSet: Set<number>,
    outside: Set<number>
  ): boolean {
    const size = board.size;
    // 反向 flooding：组群气域（穿过空点+己方棋子+对方围困棋子，仅被墙阻挡）
    const region = new Set<number>();
    const stack: Array<[number, number]> = [];
    for (const s of group.stones) {
      const dirs: Array<[number, number]> = [
        [s.row - 1, s.col], [s.row + 1, s.col], [s.row, s.col - 1], [s.row, s.col + 1],
      ];
      for (const [nr, nc] of dirs) {
        if (nr < 0 || nr >= size || nc < 0 || nc >= size) continue;
        const ni = nr * size + nc;
        if (wallSet.has(ni)) continue; // 墙阻挡
        if (!region.has(ni)) { region.add(ni); stack.push([nr, nc]); }
      }
    }
    while (stack.length > 0) {
      const [r, c] = stack.pop()!;
      const idx = r * size + c;
      // 早退：气域触及外部开放空点 → 与外部连通 → 不被包围
      if (board.grid[idx] === Color.EMPTY && outside.has(idx)) return false;
      const dirs: Array<[number, number]> = [
        [r - 1, c], [r + 1, c], [r, c - 1], [r, c + 1],
      ];
      for (const [nr, nc] of dirs) {
        if (nr < 0 || nr >= size || nc < 0 || nc >= size) continue;
        const ni = nr * size + nc;
        if (wallSet.has(ni)) continue;
        if (!region.has(ni)) { region.add(ni); stack.push([nr, nc]); }
      }
    }
    return true;
  }

  // v5.3 兼容：以对方全部棋子为墙判定包围
  private static _isSurroundedByOpponent(
    board: BoardModel,
    group: Group,
    outside?: Set<number>
  ): boolean {
    const size = board.size;
    const opp = opponent(group.color);
    const wallSet = new Set<number>();
    for (let i = 0; i < board.grid.length; i++) {
      if (board.grid[i] === opp) wallSet.add(i);
    }
    const out = outside ?? SiegeDetector.computeOutsideByWall(board, wallSet);
    return SiegeDetector._isSurroundedByWall(board, group, wallSet, out);
  }

  // 外部集合计算：含最多边缘点的非墙连通分量
  static computeOutsideByWall(board: BoardModel, wallSet: Set<number>): Set<number> {
    const size = board.size;
    const total = size * size;
    const visited = new Uint8Array(total);
    let best: { points: Set<number>; edgeCount: number } | null = null;

    for (let i = 0; i < total; i++) {
      if (visited[i] || wallSet.has(i)) continue;
      const points = new Set<number>();
      let edgeCount = 0;
      const stack: number[] = [i];
      while (stack.length > 0) {
        const idx = stack.pop()!;
        if (visited[idx] || wallSet.has(idx)) continue;
        visited[idx] = 1;
        points.add(idx);
        const r = Math.floor(idx / size);
        const c = idx % size;
        if (r === 0 || r === size - 1 || c === 0 || c === size - 1) edgeCount++;

        if (r > 0) { const ni = idx - size; if (!visited[ni] && !wallSet.has(ni)) stack.push(ni); }
        if (r < size - 1) { const ni = idx + size; if (!visited[ni] && !wallSet.has(ni)) stack.push(ni); }
        if (c > 0) { const ni = idx - 1; if (!visited[ni] && !wallSet.has(ni)) stack.push(ni); }
        if (c < size - 1) { const ni = idx + 1; if (!visited[ni] && !wallSet.has(ni)) stack.push(ni); }
      }
      if (best === null || edgeCount > best.edgeCount) best = { points, edgeCount };
    }
    return best ? best.points : new Set();
  }

  // ====== 真眼判定（规则6.4 模拟提吃）======

  private static _isTrueEye(
    board: BoardModel,
    row: number,
    col: number,
    groupSet: Set<number>,
    color: Color
  ): boolean {
    if (board.getAt(row, col) !== Color.EMPTY) return false;
    const opp = opponent(color);
    const size = board.size;

    // 条件1：正交邻居全为己方棋子（可为多个同色组群，棋盘边界视为包围）
    const dirs: Array<[number, number]> = [
      [row - 1, col], [row + 1, col], [row, col - 1], [row, col + 1],
    ];
    for (const [nr, nc] of dirs) {
      if (nr < 0 || nr >= size || nc < 0 || nc >= size) continue; // 边界视为包围
      if (board.grid[nr * size + nc] !== color) return false;
    }

    // 条件2：对方不能在该点落子（禁入点）
    if (SiegeDetector._isLegalMove(board, row, col, opp)) return false;

    // 条件3：填眼不能提吃对方（倒扑判定）
    const sim = SiegeDetector._simulatePlace(board, row, col, color);
    if (sim.captures.length > 0) return false;

    return true;
  }

  // ====== 局部模拟（不 clone 全盘，性能关键）======

  private static _isLegalMove(
    board: BoardModel,
    row: number,
    col: number,
    color: Color
  ): boolean {
    return SiegeDetector._simulatePlace(board, row, col, color).ownAlive;
  }

  private static _simulatePlace(
    board: BoardModel,
    row: number,
    col: number,
    color: Color
  ): { captures: Point[]; ownAlive: boolean } {
    const size = board.size;
    const opp = opponent(color);
    const idx = row * size + col;

    // 快速路径：落子点有空邻居 → 落子后有气
    const dirs: Array<[number, number]> = [
      [row - 1, col], [row + 1, col], [row, col - 1], [row, col + 1],
    ];
    for (const [nr, nc] of dirs) {
      if (nr < 0 || nr >= size || nc < 0 || nc >= size) continue;
      if (board.grid[nr * size + nc] === Color.EMPTY) {
        return { captures: [], ownAlive: true };
      }
    }

    // 收集四邻对方组群（判定是否被提）
    const captures: Point[] = [];
    const oppGroupsSeen = new Set<number>();
    for (const [nr, nc] of dirs) {
      if (nr < 0 || nr >= size || nc < 0 || nc >= size) continue;
      const ni = nr * size + nc;
      if (board.grid[ni] !== opp) continue;
      if (oppGroupsSeen.has(ni)) continue;
      const g = board.groupAt(nr, nc);
      for (const s of g.stones) oppGroupsSeen.add(s.row * size + s.col);
      // 排除落子点（该点原为空，落子后不再计气）
      const libCount = SiegeDetector._groupLibertyCountExcluding(board, g, row, col);
      if (libCount === 0) {
        for (const s of g.stones) captures.push({ row: s.row, col: s.col });
      }
    }

    // 收集四邻己方组群
    const ownStones: Point[] = [{ row, col }];
    const ownSeen = new Set<number>([idx]);
    for (const [nr, nc] of dirs) {
      if (nr < 0 || nr >= size || nc < 0 || nc >= size) continue;
      const ni = nr * size + nc;
      if (board.grid[ni] !== color) continue;
      if (ownSeen.has(ni)) continue;
      const g = board.groupAt(nr, nc);
      for (const s of g.stones) ownSeen.add(s.row * size + s.col);
      for (const s of g.stones) ownStones.push({ row: s.row, col: s.col });
    }

    // 判定己方连通块（落子点 + 邻接己方组群 + 被提位置）是否有气
    const ownAlive = SiegeDetector._connectedHasLiberty(
      board, ownStones, captures, row, col
    );
    return { captures, ownAlive };
  }

  // 组群气数（排除落子点；该点原为空点，落子后不再计气）
  private static _groupLibertyCountExcluding(
    board: BoardModel,
    g: Group,
    excludeRow: number,
    excludeCol: number
  ): number {
    const size = board.size;
    const libSet = new Set<number>();
    for (const s of g.stones) {
      const dirs: Array<[number, number]> = [
        [s.row - 1, s.col], [s.row + 1, s.col], [s.row, s.col - 1], [s.row, s.col + 1],
      ];
      for (const [nr, nc] of dirs) {
        if (nr < 0 || nr >= size || nc < 0 || nc >= size) continue;
        if (nr === excludeRow && nc === excludeCol) continue; // 排除落子点
        const ni = nr * size + nc;
        if (board.grid[ni] === Color.EMPTY) libSet.add(ni);
      }
    }
    return libSet.size;
  }

  // 提吃/连接后的己方连通块是否有气
  // 候选气点 = 连通块成员的四邻；落子后棋盘上为空 ⇔ 原为空点(≠落子点) 或 被提位置
  private static _connectedHasLiberty(
    board: BoardModel,
    ownStones: Point[],
    captures: Point[],
    placedRow: number,
    placedCol: number
  ): boolean {
    const size = board.size;
    const captureSet = new Set<number>();
    for (const c of captures) captureSet.add(c.row * size + c.col);
    const placedIdx = placedRow * size + placedCol;

    for (const s of ownStones) {
      const dirs: Array<[number, number]> = [
        [s.row - 1, s.col], [s.row + 1, s.col], [s.row, s.col - 1], [s.row, s.col + 1],
      ];
      for (const [nr, nc] of dirs) {
        if (nr < 0 || nr >= size || nc < 0 || nc >= size) continue;
        const ni = nr * size + nc;
        if (ni === placedIdx) continue; // 落子点不再是空
        // 落子后棋盘上为空 ⇔ 原为空点 或 被提位置
        const wasEmpty = board.grid[ni] === Color.EMPTY;
        const wasCaptured = captureSet.has(ni);
        if (wasEmpty || wasCaptured) return true;
      }
    }
    return false;
  }

  // ====== 辅助 ======

  private static _sameSieged(a: Set<number>, b: Set<number>): boolean {
    if (a.size !== b.size) return false;
    for (const v of a) if (!b.has(v)) return false;
    return true;
  }

  private static _maxSieged(states: Set<number>[]): Set<number> {
    let best: Set<number> | null = null;
    for (const s of states) {
      if (best === null || s.size > best.size) best = s;
    }
    return best ?? new Set();
  }
}
