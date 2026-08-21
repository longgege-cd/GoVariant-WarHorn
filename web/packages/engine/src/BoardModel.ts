// 棋盘数据模型：纯数据，无规则判定
// 一维 Uint8Array 存储，index = row * size + col
// 对应 GDScript c:\边境线\scripts\core\BoardModel.gd

import { BOARD_SIZE, Color } from "./Const.js";

export interface Point {
  row: number;
  col: number;
}

export interface Group {
  stones: Point[]; // 同色连通块
  color: Color;
}

export class BoardModel {
  readonly size: number;
  grid: Uint8Array;

  constructor(size: number = BOARD_SIZE) {
    this.size = size;
    this.grid = new Uint8Array(size * size); // 默认全 0 (EMPTY)
  }

  indexOf(row: number, col: number): number {
    return row * this.size + col;
  }

  inBounds(row: number, col: number): boolean {
    return row >= 0 && row < this.size && col >= 0 && col < this.size;
  }

  getAt(row: number, col: number): Color {
    return this.grid[row * this.size + col] as Color;
  }

  setAt(row: number, col: number, color: Color): void {
    this.grid[row * this.size + col] = color;
  }

  isEmpty(row: number, col: number): boolean {
    return this.grid[row * this.size + col] === Color.EMPTY;
  }

  clone(): BoardModel {
    const b = new BoardModel(this.size);
    b.grid = new Uint8Array(this.grid);
    return b;
  }

  // 四邻（边界自动忽略），返回 [row, col] 数组
  neighbors(row: number, col: number): Array<[number, number]> {
    const out: Array<[number, number]> = [];
    if (row > 0) out.push([row - 1, col]);
    if (row < this.size - 1) out.push([row + 1, col]);
    if (col > 0) out.push([row, col - 1]);
    if (col < this.size - 1) out.push([row, col + 1]);
    return out;
  }

  // 对角四邻（用于真眼判定）
  diagonals(row: number, col: number): Array<[number, number]> {
    const out: Array<[number, number]> = [];
    const r0 = row - 1, r1 = row + 1, c0 = col - 1, c1 = col + 1;
    if (r0 >= 0 && c0 >= 0) out.push([r0, c0]);
    if (r0 >= 0 && c1 < this.size) out.push([r0, c1]);
    if (r1 < this.size && c0 >= 0) out.push([r1, c0]);
    if (r1 < this.size && c1 < this.size) out.push([r1, c1]);
    return out;
  }

  // 同色连通组群（DFS，不含空点）
  groupAt(row: number, col: number): Group {
    const color = this.getAt(row, col);
    if (color === Color.EMPTY) return { stones: [], color: Color.EMPTY };

    const size = this.size;
    const seen = new Set<number>();
    const stones: Point[] = [];
    const stack: Array<[number, number]> = [[row, col]];

    while (stack.length > 0) {
      const [r, c] = stack.pop()!;
      const idx = r * size + c;
      if (seen.has(idx)) continue;
      seen.add(idx);
      stones.push({ row: r, col: c });

      // 内联四方向邻居
      if (r > 0 && this.grid[idx - size] === color && !seen.has(idx - size)) stack.push([r - 1, c]);
      if (r < size - 1 && this.grid[idx + size] === color && !seen.has(idx + size)) stack.push([r + 1, c]);
      if (c > 0 && this.grid[idx - 1] === color && !seen.has(idx - 1)) stack.push([r, c - 1]);
      if (c < size - 1 && this.grid[idx + 1] === color && !seen.has(idx + 1)) stack.push([r, c + 1]);
    }
    return { stones, color };
  }

  // 组群的气（去重空邻接点）
  liberties(stones: Point[]): Point[] {
    const size = this.size;
    const libSet = new Set<number>();
    const libs: Point[] = [];

    for (const s of stones) {
      const r = s.row, c = s.col;
      const idx = r * size + c;
      // 内联四方向
      if (r > 0 && this.grid[idx - size] === Color.EMPTY && !libSet.has(idx - size)) {
        libSet.add(idx - size); libs.push({ row: r - 1, col: c });
      }
      if (r < size - 1 && this.grid[idx + size] === Color.EMPTY && !libSet.has(idx + size)) {
        libSet.add(idx + size); libs.push({ row: r + 1, col: c });
      }
      if (c > 0 && this.grid[idx - 1] === Color.EMPTY && !libSet.has(idx - 1)) {
        libSet.add(idx - 1); libs.push({ row: r, col: c - 1 });
      }
      if (c < size - 1 && this.grid[idx + 1] === Color.EMPTY && !libSet.has(idx + 1)) {
        libSet.add(idx + 1); libs.push({ row: r, col: c + 1 });
      }
    }
    return libs;
  }

  libertyCount(stones: Point[]): number {
    return this.liberties(stones).length;
  }

  // 全盘所有同色连通组群（去重）
  allGroups(): Group[] {
    const size = this.size;
    const seen = new Set<number>();
    const out: Group[] = [];

    for (let r = 0; r < size; r++) {
      for (let c = 0; c < size; c++) {
        const idx = r * size + c;
        if (this.grid[idx] === Color.EMPTY || seen.has(idx)) continue;
        const g = this.groupAt(r, c);
        for (const s of g.stones) seen.add(s.row * size + s.col);
        out.push(g);
      }
    }
    return out;
  }

  countColor(color: Color): number {
    let n = 0;
    for (let i = 0; i < this.grid.length; i++) if (this.grid[i] === color) n++;
    return n;
  }

  // 序列化为纯数组（网络传输用）
  serialize(): number[] {
    return Array.from(this.grid);
  }

  static deserialize(size: number, data: number[]): BoardModel {
    const b = new BoardModel(size);
    b.grid = new Uint8Array(data);
    return b;
  }
}
