// 围空检测：纯几何判定包围圈（v4.1）
// 规则要点：
//   - 包围圈 = 一方棋子 + 棋盘边界 形成的完全封闭几何边界
//   - 棋盘边界参与包围需棋子占据两端点
//   - 死活判定不在此模块，由 ScoreCalculator 终局处理
//   - 嵌套包围圈：内层小圈先处理，外层扣除内层已覆盖区域
// 对应 GDScript c:\边境线\scripts\core\TerritoryDetector.gd (422行)

import { Color, opponent } from "./Const.js";
import { BoardModel, Point } from "./BoardModel.js";

export interface EmptyRegion {
  empty: Point[]; // 空连通块的空点
  borderColors: Map<Color, number>; // 边界棋子颜色统计
  touchesEdge: boolean; // 是否触及棋盘外缘
  borderStones: Set<number>; // 边界棋子位置 idx
}

export interface Enclosure {
  color: Color; // 围空方颜色
  points: Point[]; // 圈内空点（已做嵌套去重）
  stonesInside: Point[]; // 圈内对方棋子（终局由ScoreCalculator判围困）
  borderStonesIdx: Set<number>; // 边界棋子位置 idx
  seq: number; // 收集顺序（稳定排序用）
}

interface RawEnclosure {
  color: Color;
  points: Point[];
  borderStonesIdx: Set<number>;
  seq: number;
}

interface WallComponents {
  outside: Set<number>; // "外部"连通分量 idx 集合
  cavities: Array<Set<number>>; // "洞腔"连通分量
}

export class TerritoryDetector {
  // 全盘空连通块扫描（BFS）
  static allEmptyRegions(board: BoardModel): EmptyRegion[] {
    const size = board.size;
    const visited = new Uint8Array(size * size);
    const regions: EmptyRegion[] = [];

    for (let r = 0; r < size; r++) {
      for (let c = 0; c < size; c++) {
        const idx = r * size + c;
        if (board.grid[idx] !== Color.EMPTY || visited[idx]) continue;

        const empty: Point[] = [];
        const borderColors = new Map<Color, number>();
        const borderStones = new Set<number>();
        let touchesEdge = false;
        const stack: Array<[number, number]> = [[r, c]];

        while (stack.length > 0) {
          const [cr, cc] = stack.pop()!;
          const cidx = cr * size + cc;
          if (visited[cidx]) continue;
          visited[cidx] = 1;
          empty.push({ row: cr, col: cc });

          // 边缘检测
          if (cr === 0 || cr === size - 1 || cc === 0 || cc === size - 1) touchesEdge = true;

          // 内联四方向邻居
          const dirs: Array<[number, number]> = [
            [cr - 1, cc], [cr + 1, cc], [cr, cc - 1], [cr, cc + 1],
          ];
          for (const [nr, nc] of dirs) {
            if (nr < 0 || nr >= size || nc < 0 || nc >= size) continue;
            const ni = nr * size + nc;
            const v = board.grid[ni];
            if (v === Color.EMPTY) {
              if (!visited[ni]) stack.push([nr, nc]);
            } else {
              borderStones.add(ni);
              borderColors.set(v as Color, (borderColors.get(v as Color) ?? 0) + 1);
            }
          }
        }
        regions.push({ empty, borderColors, touchesEdge, borderStones });
      }
    }
    return regions;
  }

  // 主入口：收集所有围空圈（含嵌套去重）
  static enclosures(board: BoardModel): Enclosure[] {
    const raw = TerritoryDetector._collectRawEnclosures(board);
    if (raw.length === 0) return [];

    const size = board.size;

    // 1. 按色合并所有围空圈的 points（用于 stonesInside 判定）
    const colorPoints = new Map<Color, Set<number>>();
    for (const enc of raw) {
      let set = colorPoints.get(enc.color);
      if (!set) { set = new Set(); colorPoints.set(enc.color, set); }
      for (const p of enc.points) set.add(p.row * size + p.col);
    }

    // 2. 对每个圈扫描圈内对方棋子
    for (const enc of raw) {
      const allPts = colorPoints.get(enc.color)!;
      (enc as RawEnclosure & { stonesInside?: Point[] }).stonesInside =
        TerritoryDetector._collectStonesInside(board, enc, allPts);
    }

    // 3. 按区域大小升序排序（内层小圈先处理；同大小按 seq 稳定排序）
    raw.sort((a, b) => {
      if (a.points.length !== b.points.length) return a.points.length - b.points.length;
      return a.seq - b.seq;
    });

    // 4. 嵌套去重
    const covered = new Set<number>(); // 空点 idx
    const coveredStones = new Set<number>(); // 棋子位置 idx
    const result: Enclosure[] = [];

    for (const enc of raw) {
      const filteredPoints: Point[] = [];
      for (const p of enc.points) {
        const idx = p.row * size + p.col;
        if (covered.has(idx)) continue;
        covered.add(idx);
        filteredPoints.push(p);
      }
      const rawStones = (enc as RawEnclosure & { stonesInside?: Point[] }).stonesInside ?? [];
      const filteredStones: Point[] = [];
      for (const s of rawStones) {
        const sidx = s.row * size + s.col;
        if (coveredStones.has(sidx)) continue;
        coveredStones.add(sidx);
        filteredStones.push(s);
      }
      if (filteredPoints.length === 0 && filteredStones.length === 0) continue;
      result.push({
        color: enc.color,
        points: filteredPoints,
        stonesInside: filteredStones,
        borderStonesIdx: enc.borderStonesIdx,
        seq: enc.seq,
      });
    }
    return result;
  }

  // 过滤指定色围空
  static enclosuresOf(board: BoardModel, color: Color): Enclosure[] {
    return TerritoryDetector.enclosures(board).filter((e) => e.color === color);
  }

  // 该色棋子是否参与某围空圈（用于特种部队判定，MVP不用但保留接口）
  static stoneParticipatesInEnclosure(
    board: BoardModel,
    row: number,
    col: number,
    color: Color
  ): boolean {
    const size = board.size;
    const idx = row * size + col;
    const encs = TerritoryDetector.enclosures(board);
    for (const e of encs) {
      if (e.color !== color) continue;
      if (e.borderStonesIdx.has(idx)) return true;
      // 邻接某被该色包围的空块
      const dirs: Array<[number, number]> = [
        [row - 1, col], [row + 1, col], [row, col - 1], [row, col + 1],
      ];
      for (const [nr, nc] of dirs) {
        if (nr < 0 || nr >= size || nc < 0 || nc >= size) continue;
        const ni = nr * size + nc;
        if (e.points.some((p) => p.row * size + p.col === ni)) return true;
      }
    }
    return false;
  }

  // ====== 内部实现 ======

  // 两阶段收集原始围空圈（Pass A 空区域 + Pass B 洞腔）
  private static _collectRawEnclosures(board: BoardModel): RawEnclosure[] {
    const size = board.size;
    const out: RawEnclosure[] = [];
    let seq = 0;

    // 预建每色棋子索引墙
    const walls = new Map<Color, Set<number>>();
    walls.set(Color.BLACK, new Set());
    walls.set(Color.WHITE, new Set());
    for (let i = 0; i < board.grid.length; i++) {
      const v = board.grid[i];
      if (v === Color.BLACK) walls.get(Color.BLACK)!.add(i);
      else if (v === Color.WHITE) walls.get(Color.WHITE)!.add(i);
    }

    // 每色墙连通分量（外部 + 洞腔）
    const comps = new Map<Color, WallComponents>();
    comps.set(Color.BLACK, TerritoryDetector._computeWallComponents(board, walls.get(Color.BLACK)!));
    comps.set(Color.WHITE, TerritoryDetector._computeWallComponents(board, walls.get(Color.WHITE)!));

    // Pass A：空区域围空
    const regions = TerritoryDetector.allEmptyRegions(board);
    for (const region of regions) {
      if (region.empty.length === 0) continue;
      // 检查每色墙是否包围此区域
      const candidates: Array<{ color: Color; cav: Set<number> }> = [];
      for (const c of [Color.BLACK, Color.WHITE]) {
        const comp = comps.get(c)!;
        if (TerritoryDetector._isRegionEnclosedByWallWithSize(region, comp.outside, size)) {
          // 找到此区域所在的洞腔（不在 outside 中的非墙点）
          // 选最小洞腔（规则4.3：内层活棋归内方）
          let bestCav: Set<number> | null = null;
          for (const cav of comp.cavities) {
            // 区域任一空点在 cav 中 → 此 cav 包围该区域
            const firstPt = region.empty[0];
            if (cav.has(firstPt.row * size + firstPt.col)) {
              if (bestCav === null || cav.size < bestCav.size) bestCav = cav;
            }
          }
          if (bestCav === null) bestCav = comp.outside; // fallback
          candidates.push({ color: c, cav: bestCav });
        }
      }
      if (candidates.length === 0) continue;
      // 多色均可封闭时选"最小洞腔"= 最内层
      candidates.sort((a, b) => a.cav.size - b.cav.size);
      const chosen = candidates[0];

      // 收集边界棋子（区域 borderStones 中属于 chosen.color 的）
      const borderStonesIdx = new Set<number>();
      for (const idx of region.borderStones) {
        if (board.grid[idx] === chosen.color) borderStonesIdx.add(idx);
      }
      out.push({
        color: chosen.color,
        points: region.empty.slice(),
        borderStonesIdx,
        seq: seq++,
      });
    }

    // Pass B：洞腔围空（补充被对方棋子填满或空点已归属内圈的洞腔）
    const coveredC = new Set<number>(); // 已被 Pass A 同色圈覆盖的空点
    for (const enc of out) {
      if (enc.color !== Color.BLACK && enc.color !== Color.WHITE) continue;
      for (const p of enc.points) coveredC.add(p.row * size + p.col);
    }

    for (const c of [Color.BLACK, Color.WHITE]) {
      const comp = comps.get(c)!;
      for (const cav of comp.cavities) {
        const cavPts: Point[] = [];
        let hasEmpty = false;
        let allCovered = true;
        for (const idx of cav) {
          if (board.grid[idx] !== Color.EMPTY) continue;
          hasEmpty = true;
          if (!coveredC.has(idx)) allCovered = false;
          cavPts.push({ row: Math.floor(idx / size), col: idx % size });
        }
        if (!hasEmpty) continue;
        if (allCovered) continue; // 已被 Pass A 同色圈覆盖

        // 计算洞腔边界（墙色棋子邻接洞腔）
        const border = new Set<number>();
        for (const idx of cav) {
          const r = Math.floor(idx / size);
          const cc = idx % size;
          const dirs: Array<[number, number]> = [
            [r - 1, cc], [r + 1, cc], [r, cc - 1], [r, cc + 1],
          ];
          for (const [nr, nc] of dirs) {
            if (nr < 0 || nr >= size || nc < 0 || nc >= size) continue;
            const ni = nr * size + nc;
            if (walls.get(c)!.has(ni)) border.add(ni);
          }
        }
        out.push({
          color: c,
          points: cavPts,
          borderStonesIdx: border,
          seq: seq++,
        });
      }
    }
    return out;
  }

  // 每色墙连通分量：外部 = 含最多边缘点的非墙连通分量；洞腔 = 其他
  private static _computeWallComponents(
    board: BoardModel,
    wallSet: Set<number>
  ): WallComponents {
    const size = board.size;
    const total = size * size;
    const visited = new Uint8Array(total);
    const components: Array<{ points: Set<number>; edgeCount: number }> = [];

    for (let i = 0; i < total; i++) {
      if (visited[i] || wallSet.has(i)) continue;
      // BFS 非墙连通分量（空点 + 非墙色棋子可穿过）
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

        // 内联四方向
        if (r > 0) {
          const ni = idx - size;
          if (!visited[ni] && !wallSet.has(ni)) stack.push(ni);
        }
        if (r < size - 1) {
          const ni = idx + size;
          if (!visited[ni] && !wallSet.has(ni)) stack.push(ni);
        }
        if (c > 0) {
          const ni = idx - 1;
          if (!visited[ni] && !wallSet.has(ni)) stack.push(ni);
        }
        if (c < size - 1) {
          const ni = idx + 1;
          if (!visited[ni] && !wallSet.has(ni)) stack.push(ni);
        }
      }
      components.push({ points, edgeCount });
    }

    if (components.length === 0) {
      return { outside: new Set(), cavities: [] };
    }

    // 外部 = 含最多边缘点的连通分量
    let bestIdx = 0;
    for (let i = 1; i < components.length; i++) {
      if (components[i].edgeCount > components[bestIdx].edgeCount) bestIdx = i;
    }
    const outside = components[bestIdx].points;
    const cavities = components.filter((_, i) => i !== bestIdx).map((c) => c.points);
    return { outside, cavities };
  }

  // 几何封闭性判定：区域任意空点不在「外部」分量内 → 被墙包围
  // （区域是连通块，要么全在外部要么全在洞腔内，用第一个点判断即可）
  private static _isRegionEnclosedByWallWithSize(
    region: EmptyRegion,
    outside: Set<number>,
    size: number
  ): boolean {
    const first = region.empty[0];
    return !outside.has(first.row * size + first.col);
  }

  // 圈内对方棋子扫描：组群所有气都在同色围空圈的合并 points 内 → 计入
  private static _collectStonesInside(
    board: BoardModel,
    enc: RawEnclosure,
    allColorPoints: Set<number>
  ): Point[] {
    const size = board.size;
    const opp = opponent(enc.color);
    const candidates = new Set<number>();
    const stonesInside: Point[] = [];
    const seen = new Set<number>();

    // 1. 空区域边界上的对方棋子
    for (const idx of enc.borderStonesIdx) {
      if (board.grid[idx] === opp) candidates.add(idx);
    }
    // 2. 围空方边界棋子的邻居中的对方棋子
    for (const idx of enc.borderStonesIdx) {
      if (board.grid[idx] !== enc.color) continue;
      const r = Math.floor(idx / size);
      const c = idx % size;
      const dirs: Array<[number, number]> = [
        [r - 1, c], [r + 1, c], [r, c - 1], [r, c + 1],
      ];
      for (const [nr, nc] of dirs) {
        if (nr < 0 || nr >= size || nc < 0 || nc >= size) continue;
        const ni = nr * size + nc;
        if (board.grid[ni] === opp) candidates.add(ni);
      }
    }

    // 对每个候选组群：所有气都在 allColorPoints 内 → 计入整个组群
    for (const idx of candidates) {
      if (seen.has(idx)) continue;
      const r = Math.floor(idx / size);
      const c = idx % size;
      const g = board.groupAt(r, c);
      if (g.stones.length === 0) continue;
      for (const s of g.stones) seen.add(s.row * size + s.col);
      const libs = board.liberties(g.stones);
      let allInside = true;
      for (const l of libs) {
        if (!allColorPoints.has(l.row * size + l.col)) { allInside = false; break; }
      }
      if (!allInside) continue;
      for (const s of g.stones) stonesInside.push({ row: s.row, col: s.col });
    }
    return stonesInside;
  }
}
