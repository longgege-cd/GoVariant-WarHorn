// Canvas 棋盘渲染：19x19 木质棋盘、网格、星位、棋子、最后一手标记、围空/围困显示
// 特效（参考原项目 BoardView.gd）：落子脉冲、提子爆裂+波浪、围困红环、围空扩散、边境线呼吸灯
// 负责绘制 + 鼠标交互（点击转 row/col）

import { BOARD_SIZE, BORDER_ROW, Color, BoardModel } from "@warhorn/engine";
import type { Enclosure, Group } from "@warhorn/engine";
import { atariStoneSet, influenceRenderData, type InfluenceRender } from "@warhorn/engine";
import { SoundFx } from "./audio/SoundFx.js";

interface BoardCanvasOptions {
  cellSize?: number;
  padding?: number;
  showCoords?: boolean;
  showTerritory?: boolean;
  showSieged?: boolean;
  borderPulse?: boolean; // 边境线呼吸灯（默认开启）
}

// 特效叠加层（参考原项目 effect_overlays）
interface EffectOverlay {
  type: EffectType;
  startTime?: number; // 秒（由 _addOverlay 赋值）
  duration: number;
  positions?: Array<{ row: number; col: number }>; // capture
  stones?: Array<{ row: number; col: number }>; // siege / siege_broken
  points?: Array<{ row: number; col: number }>; // territory_formed / territory_lost
  color?: Color;
  position?: { row: number; col: number }; // move / deploy_place
}

type EffectType =
  | "move"
  | "deploy_place"
  | "capture"
  | "siege"
  | "siege_broken"
  | "territory_formed"
  | "territory_lost"
  | "opening";

const COLS = "ABCDEFGHJKLMNOPQRST"; // 跳过 I（围棋惯例）

// ====== 棋盘棋子主题 ======
interface BoardTheme {
  id: string;
  name: string;
  boardGrad: [string, string]; // 棋盘背景渐变（起始/结束）
  grid: string; // 网格线颜色
  star: string; // 星位颜色
  coord: string; // 坐标颜色
  border: string; // 边境线呼吸灯颜色（hex）
  borderHeight: number; // 边境线高度（格数）
  borderAlphaMin: number; // 呼吸最低 alpha
  borderAlphaMax: number; // 呼吸最高 alpha
  borderGlow: boolean; // 上下光晕渐变
  borderDashed: boolean; // 像素分段带
  territoryBlack: string; // 黑境底色（"rgba(r, g, b, " 前缀，拼接 alpha）
  territoryWhite: string; // 白境底色前缀
  blackHi: string; // 黑棋高光
  blackLo: string; // 黑棋主体
  blackEdge: string; // 黑棋描边
  whiteHi: string; // 白棋高光
  whiteLo: string; // 白棋主体
  whiteEdge: string; // 白棋描边
  openingWave: [number, number, number]; // 开局波浪主色（RGB，与棋盘底色对比）
  captureWave: [number, number, number]; // 提子波浪主色（RGB，与棋盘底色对比）
}

const THEMES: BoardTheme[] = [
  {
    id: "wood",
    name: "经典木质",
    boardGrad: ["#dcb35c", "#d2a550"],
    grid: "#3d2817",
    star: "#3d2817",
    coord: "#3d2817",
    border: "#4a9eff",
    borderHeight: 1,
    borderAlphaMin: 0.08,
    borderAlphaMax: 0.16,
    borderGlow: false,
    borderDashed: false,
    territoryBlack: "rgba(90, 140, 217, ",
    territoryWhite: "rgba(242, 199, 82, ",
    blackHi: "#4a4a4a",
    blackLo: "#1a1a1a",
    blackEdge: "#000",
    whiteHi: "#ffffff",
    whiteLo: "#d0d0d0",
    whiteEdge: "#888",
    openingWave: [40, 210, 170], // 青绿（金木底对比）
    captureWave: [255, 92, 92], // 珊瑚红
  },
  {
    id: "pixel",
    name: "动画像素风",
    boardGrad: ["#8aa9a0", "#6d8d84"],
    grid: "#ddeae7",
    star: "#e2ece9",
    coord: "#3f5f5a",
    border: "#e0b35e",
    borderHeight: 1,
    borderAlphaMin: 0.12,
    borderAlphaMax: 0.24,
    borderGlow: false,
    borderDashed: true,
    territoryBlack: "rgba(92, 148, 140, ",
    territoryWhite: "rgba(222, 184, 118, ",
    blackHi: "#8d79ba",
    blackLo: "#574687",
    blackEdge: "#3c3460",
    whiteHi: "#ffffff",
    whiteLo: "#e9eff0",
    whiteEdge: "#8fa9a4",
    openingWave: [165, 135, 255], // 亮紫（灰绿底对比）
    captureWave: [255, 143, 64], // 亮橙
  },
  {
    id: "obsidian",
    name: "黑曜石",
    boardGrad: ["#33324a", "#16151f"],
    grid: "#7c86ad",
    star: "#9aa6cc",
    coord: "#9aa6cc",
    border: "#c084fc",
    borderHeight: 1,
    borderAlphaMin: 0.16,
    borderAlphaMax: 0.32,
    borderGlow: true,
    borderDashed: false,
    territoryBlack: "rgba(120, 100, 220, ",
    territoryWhite: "rgba(150, 130, 240, ",
    blackHi: "#6d6a92",
    blackLo: "#0f0e17",
    blackEdge: "#a78bfa",
    whiteHi: "#f5f3ff",
    whiteLo: "#b8b4d6",
    whiteEdge: "#5b5b7a",
    openingWave: [92, 230, 255], // 亮青（深紫底对比）
    captureWave: [255, 172, 92], // 亮琥珀
  },
  {
    id: "porcelain",
    name: "青花瓷",
    boardGrad: ["#e9e7de", "#d7d4c9"],
    grid: "#2f5fa3",
    star: "#2f5fa3",
    coord: "#2f5fa3",
    border: "#4a9eff",
    borderHeight: 0.5,
    borderAlphaMin: 0.12,
    borderAlphaMax: 0.22,
    borderGlow: true,
    borderDashed: false,
    territoryBlack: "rgba(47, 95, 163, ",
    territoryWhite: "rgba(184, 224, 232, ", // 淡淡天青围空
    blackHi: "#1e3a5f",
    blackLo: "#0d2a4f",
    blackEdge: "#0b2b5e",
    whiteHi: "#ffffff",
    whiteLo: "#dbe7f5",
    whiteEdge: "#2f5fa3",
    openingWave: [64, 200, 122], // 翠绿（米白底对比）
    captureWave: [233, 86, 86], // 朱红（青花蓝的朱砂对照）
  },
];

// hex(#rrggbb) → "r, g, b"（用于拼接 alpha 字符串）
function hexToRgb(s: string): string {
  const h = s.replace("#", "");
  return `${parseInt(h.slice(0, 2), 16)}, ${parseInt(h.slice(2, 4), 16)}, ${parseInt(h.slice(4, 6), 16)}`;
}

// RGB 三元组提亮 → "r, g, b" 字符串（用于 rgba 拼接，模拟中心光晕）
function lightenRgb(c: [number, number, number], amt: number): string {
  return `${Math.min(255, c[0] + amt)}, ${Math.min(255, c[1] + amt)}, ${Math.min(255, c[2] + amt)}`;
}

export class BoardCanvas {
  readonly canvas: HTMLCanvasElement;
  private ctx: CanvasRenderingContext2D;
  private staticCanvas: HTMLCanvasElement; // 离屏静态层缓存（背景/网格/棋子等不变元素）
  private staticCtx: CanvasRenderingContext2D;
  private staticDirty = true; // 静态层需重建标志（状态/主题变化时置位）
  private cellSize: number;
  private padding: number;
  private showCoords: boolean;
  private showTerritory: boolean;
  private showSieged: boolean;
  private borderPulse: boolean;

  // 主题风格（按 T 切换，默认青花瓷）
  private themeId = THEMES.findIndex((t) => t.id === "porcelain");
  private theme: BoardTheme = THEMES[this.themeId];

  // 当前盘面状态
  private grid: Uint8Array = new Uint8Array(BOARD_SIZE * BOARD_SIZE);
  private lastMove: { row: number; col: number } | null = null;
  private enclosures: Enclosure[] = [];
  private siegedStones: Set<number> = new Set();
  private hoverPos: { row: number; col: number } | null = null;
  private currentColor: Color = Color.BLACK;
  // 战争迷雾（可选规则）：fogActive 时在 fogCells 覆盖半透明浅灰迷雾
  private fogCells: Set<number> = new Set();
  private fogActive: boolean = false;

  // 特效叠加层
  private effectOverlays: EffectOverlay[] = [];
  private time: number = 0; // 当前秒（动画时间基）
  private animFrame: number | null = null;
  private _destroyed = false;

  // 打吃（剩最后一口气）组群标记 + 势力热力图
  private atariStones: Set<number> = new Set();
  private influence: InfluenceRender | null = null;
  private showInfluence: boolean = false;
  private _keydownHandler: (e: KeyboardEvent) => void;
  private _themeKeyHandler: (e: KeyboardEvent) => void;

  // 布局阶段视觉提示
  private deployPhase: boolean = false;

  // 点击回调
  onCellClick?: (row: number, col: number) => void;
  // 空格切换热力图回调（用于 UI 提示）
  onInfluenceToggle?: (shown: boolean) => void;
  // 按 T 切换主题回调（用于 UI 提示当前主题名）
  onThemeToggle?: (name: string) => void;

  constructor(opts: BoardCanvasOptions = {}) {
    this.cellSize = opts.cellSize ?? 32;
    this.padding = opts.padding ?? 28;
    this.showCoords = opts.showCoords ?? true;
    this.showTerritory = opts.showTerritory ?? true;
    this.showSieged = opts.showSieged ?? true;
    this.borderPulse = opts.borderPulse ?? true;

    this.canvas = document.createElement("canvas");
    const total = this.padding * 2 + (BOARD_SIZE - 1) * this.cellSize;
    this.canvas.width = total;
    this.canvas.height = total;
    this.canvas.id = "board-canvas";

    const ctx = this.canvas.getContext("2d");
    if (!ctx) throw new Error("Canvas 2D context unavailable");
    this.ctx = ctx;

    // 离屏静态层缓存（同尺寸；背景/网格/棋子等不变元素只画一次，动画循环仅 blit + 动态特效）
    this.staticCanvas = document.createElement("canvas");
    this.staticCanvas.width = total;
    this.staticCanvas.height = total;
    const sctx = this.staticCanvas.getContext("2d");
    if (!sctx) throw new Error("Canvas 2D context unavailable");
    this.staticCtx = sctx;

    this._keydownHandler = (e: KeyboardEvent) => {
      if (e.code !== "Space" || e.repeat) return;
      e.preventDefault();
      this.toggleInfluence();
    };
    window.addEventListener("keydown", this._keydownHandler);

    // 按 T 切换棋盘主题
    this._themeKeyHandler = (e: KeyboardEvent) => {
      if (e.code !== "KeyT" || e.repeat) return;
      e.preventDefault();
      this.toggleTheme();
    };
    window.addEventListener("keydown", this._themeKeyHandler);

    this._bindEvents();
    this._startAnimLoop();
    this.render();
  }

  destroy(): void {
    this._destroyed = true;
    if (this.animFrame !== null) cancelAnimationFrame(this.animFrame);
    window.removeEventListener("keydown", this._keydownHandler);
    window.removeEventListener("keydown", this._themeKeyHandler);
  }

  // 按 T 切换主题：青花瓷 → 动画像素风 → 黑曜石 → 经典木质
  toggleTheme(): void {
    this.themeId = (this.themeId + 1) % THEMES.length;
    this.theme = THEMES[this.themeId];
    this.onThemeToggle?.(this.theme.name);
    this.staticDirty = true;
    this.render();
  }

  // 空格键切换势力热力图显示
  toggleInfluence(): void {
    this.showInfluence = !this.showInfluence;
    if (this.showInfluence && !this.influence) {
      this.influence = influenceRenderData(this._board());
    }
    this.onInfluenceToggle?.(this.showInfluence);
    this.staticDirty = true;
    this.render();
  }

  // 从当前 grid 构造临时棋盘（状态检测用）
  private _board(): BoardModel {
    const b = new BoardModel(BOARD_SIZE);
    b.grid = this.grid;
    return b;
  }

  // 更新盘面状态
  updateState(
    grid: Uint8Array,
    lastMove: { row: number; col: number } | null,
    enclosures: Enclosure[],
    siegedGroups: Group[],
    currentColor: Color,
    fogCells?: Set<number>,
    fogActive?: boolean
  ): void {
    this.grid = grid;
    this.lastMove = lastMove;
    this.enclosures = enclosures;
    this.siegedStones.clear();
    for (const g of siegedGroups) {
      for (const s of g.stones) this.siegedStones.add(s.row * BOARD_SIZE + s.col);
    }
    this.currentColor = currentColor;
    this.fogCells = fogCells ?? new Set();
    this.fogActive = fogActive ?? false;
    // 重算打吃状态与势力图（仅显示辅助）
    this.atariStones = atariStoneSet(this._board());
    this.influence = influenceRenderData(this._board());
    // 盘面变化 → 静态层需重建
    this.staticDirty = true;
    this.render();
  }

  // 鼠标悬停的预览棋子
  setHover(pos: { row: number; col: number } | null): void {
    this.hoverPos = pos;
  }

  // ====== 特效接口（参考原项目 EffectsPlayer）======

  /** 落子脉冲：金色扩散环（0.4s），黑"叮"白"咚" */
  playMove(position: { row: number; col: number }, color: Color): void {
    this._addOverlay({ type: "move", position, duration: 0.4 });
    SoundFx.playMove(color);
  }

  /** 布局落子脉冲：青绿色双层扩散环（0.5s），黑"叮"白"咚" */
  playDeployPlace(position: { row: number; col: number }, color: Color): void {
    this._addOverlay({ type: "deploy_place", position, duration: 0.5 });
    SoundFx.playMove(color);
  }

  /** 提子特效：被吃棋子上升渐大淡出 + 震波扩散（0.9s） */
  playCapture(positions: Array<{ row: number; col: number }>, color: Color): void {
    this._addOverlay({ type: "capture", positions, color, duration: 0.9 });
    SoundFx.playCapture();
  }

  /** 围困形成：红色脉冲环（0.8s） */
  playSiege(stones: Array<{ row: number; col: number }>): void {
    this._addOverlay({ type: "siege", stones, duration: 0.8 });
    SoundFx.playSiege();
  }

  /** 围困解除：绿色光环扩散（0.8s） */
  playSiegeBroken(stones: Array<{ row: number; col: number }>): void {
    this._addOverlay({ type: "siege_broken", stones, duration: 0.8 });
  }

  /** 围空形成：圈内光晕扩散 + 中心环（1.0s） */
  playTerritoryFormed(points: Array<{ row: number; col: number }>, color: Color): void {
    this._addOverlay({ type: "territory_formed", points, color, duration: 1.0 });
    SoundFx.playTerritory();
  }

  /** 围空失守：灰色消散 + 边界红闪（1.0s） */
  playTerritoryLost(points: Array<{ row: number; col: number }>, color: Color): void {
    this._addOverlay({ type: "territory_lost", points, color, duration: 1.0 });
  }

  /** 开局过渡动画：从棋盘中央开始的圆形扩散波浪（1.4s） */
  playOpeningAnimation(): void {
    this._addOverlay({ type: "opening", duration: 1.4 });
  }

  /** 设置布局阶段状态（控制领土辉光提示） */
  setDeployPhase(active: boolean): void {
    this.deployPhase = active;
    if (active) this._startAnimLoop(); // 领土辉光需要呼吸动画
  }

  private _addOverlay(ov: EffectOverlay): void {
    ov.startTime = this.time;
    this.effectOverlays.push(ov);
    this._startAnimLoop();
  }

  // 像素坐标 → 棋盘坐标 (row, col)，无效返回 null
  pixelToBoard(x: number, y: number): { row: number; col: number } | null {
    const col = Math.round((x - this.padding) / this.cellSize);
    const row = Math.round((y - this.padding) / this.cellSize);
    if (row < 0 || row >= BOARD_SIZE || col < 0 || col >= BOARD_SIZE) return null;
    // 容差检查：离最近交叉点不超过 cellSize/2
    const cx = this.padding + col * this.cellSize;
    const cy = this.padding + row * this.cellSize;
    if (Math.abs(x - cx) > this.cellSize / 2 || Math.abs(y - cy) > this.cellSize / 2) return null;
    return { row, col };
  }

  // ====== 渲染 ======

  render(): void {
    const ctx = this.ctx;
    const cs = this.cellSize;
    const pad = this.padding;

    // 静态层（背景/领土底色/网格/星位/坐标/热力图/围空圈/棋子/围困标记）：
    // 仅当盘面状态或主题变化（staticDirty）时重建，动画循环通过 blit 复用，避免每帧全量重绘
    if (this.staticDirty) {
      this._renderStatic();
      this.staticDirty = false;
    }
    ctx.drawImage(this.staticCanvas, 0, 0);

    // 布局阶段：领土辉光呼吸（叠加在静态领土底色之上）
    if (this.deployPhase) {
      const th = this.theme;
      const topH = cs * 9;
      const botY = pad + cs * 9;
      const glow = 0.04 + 0.03 * (0.5 + 0.5 * Math.sin(this.time * 2.5));
      ctx.fillStyle = `${th.territoryBlack}${glow.toFixed(3)})`;
      ctx.fillRect(pad, pad, cs * 18, topH);
      ctx.fillStyle = `${th.territoryWhite}${glow.toFixed(3)})`;
      ctx.fillRect(pad, botY, cs * 18, cs * 18 - topH);
    }

    // 边境线呼吸灯（随时间变化 → 动态层）
    this._drawBorderZone();

    // 最后一手标记（紫色呼吸小圆圈）
    if (this.lastMove && this.lastMove.row >= 0) {
      const cx = pad + this.lastMove.col * cs;
      const cy = pad + this.lastMove.row * cs;
      const pulse = 0.5 + 0.5 * Math.sin(this.time * 7.85); // 0.8s 呼吸周期
      ctx.strokeStyle = `rgba(180, 100, 255, ${(0.75 + 0.2 * pulse).toFixed(3)})`;
      ctx.lineWidth = 3;
      ctx.beginPath();
      ctx.arc(cx, cy, cs * 0.3 * (1 + pulse * 0.1), 0, Math.PI * 2);
      ctx.stroke();
    }

    // 打吃（剩最后一口气）呼吸灯提示
    this._drawAtariMarkers();

    // 特效叠加层（参考原项目 _draw_effect_overlays）
    this._drawEffectOverlays();

    // 悬停预览
    if (this.hoverPos && this.grid[this.hoverPos.row * BOARD_SIZE + this.hoverPos.col] === Color.EMPTY) {
      ctx.globalAlpha = 0.4;
      this._drawStone(this.hoverPos.col, this.hoverPos.row, this.currentColor);
      ctx.globalAlpha = 1;
    }
  }

  // 静态层绘制：棋盘上不随时间变化的元素，写入离屏 canvas（staticCtx）。
  // 仅当盘面状态或主题变化（staticDirty）时重建一次
  private _renderStatic(): void {
    const ctx = this.staticCtx;
    const cs = this.cellSize;
    const pad = this.padding;
    const size = BOARD_SIZE;
    const th = this.theme;

    // 1. 棋盘背景（主题渐变）
    ctx.fillStyle = th.boardGrad[0];
    ctx.fillRect(0, 0, this.staticCanvas.width, this.staticCanvas.height);
    const grad = ctx.createLinearGradient(0, 0, this.staticCanvas.width, this.staticCanvas.height);
    grad.addColorStop(0, th.boardGrad[0]);
    grad.addColorStop(0.5, th.boardGrad[1]);
    grad.addColorStop(1, th.boardGrad[0]);
    ctx.fillStyle = grad;
    ctx.fillRect(0, 0, this.staticCanvas.width, this.staticCanvas.height);

    // 2. 领土底色提示（基础透明度；布局阶段辉光由 render() 动态叠加）
    const topH = cs * 9;
    const botY = pad + cs * 9;
    ctx.fillStyle = `${th.territoryBlack}0.060)`;
    ctx.fillRect(pad, pad, cs * 18, topH);
    ctx.fillStyle = `${th.territoryWhite}0.070)`;
    ctx.fillRect(pad, botY, cs * 18, cs * 18 - topH);

    // 3. 网格线 + 边框加粗
    ctx.strokeStyle = th.grid;
    ctx.lineWidth = 1;
    ctx.beginPath();
    for (let i = 0; i < size; i++) {
      const y = pad + i * cs;
      ctx.moveTo(pad, y);
      ctx.lineTo(pad + (size - 1) * cs, y);
      const x = pad + i * cs;
      ctx.moveTo(x, pad);
      ctx.lineTo(x, pad + (size - 1) * cs);
    }
    ctx.stroke();
    ctx.lineWidth = 2;
    ctx.strokeRect(pad, pad, (size - 1) * cs, (size - 1) * cs);

    // 4. 星位（9个）
    ctx.fillStyle = th.star;
    const stars = [3, 9, 15];
    for (const r of stars) {
      for (const c of stars) {
        ctx.beginPath();
        ctx.arc(pad + c * cs, pad + r * cs, 3, 0, Math.PI * 2);
        ctx.fill();
      }
    }

    // 5. 坐标标注（参考原项目：列=A-T，行=1-19 从上往下，1=顶部row0）
    if (this.showCoords) {
      ctx.fillStyle = th.coord;
      ctx.font = "11px sans-serif";
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      for (let i = 0; i < size; i++) {
        ctx.fillText(COLS[i], pad + i * cs, pad / 2);
        ctx.fillText(COLS[i], pad + i * cs, pad + (size - 1) * cs + pad / 2);
        ctx.fillText(String(i + 1), pad / 2, pad + i * cs);
        ctx.fillText(String(i + 1), pad + (size - 1) * cs + pad / 2, pad + i * cs);
      }
    }

    // 6. 势力热力图（空格键切换显示；静态，随 updateState 重建）
    if (this.showInfluence && this.influence) {
      this._drawInfluence(ctx);
    }

    // 7. 围空圈显示（半透明色块）
    if (this.showTerritory) {
      for (const enc of this.enclosures) {
        // 使用主题围空色：黑围空=深蓝，白围空=淡淡天青
        const color =
          enc.color === Color.BLACK
            ? `${this.theme.territoryBlack}0.25)`
            : `${this.theme.territoryWhite}0.68)`;
        ctx.fillStyle = color;
        for (const p of enc.points) {
          ctx.fillRect(pad + p.col * cs - cs / 2, pad + p.row * cs - cs / 2, cs, cs);
        }
      }
    }

    // 8. 棋子
    for (let r = 0; r < size; r++) {
      for (let c = 0; c < size; c++) {
        const v = this.grid[r * size + c];
        if (v === Color.EMPTY) continue;
        this._drawStone(c, r, v as Color, ctx);
      }
    }

    // 9. 围困棋子标记（棋子中心的红色 ×，参考原项目 _draw_siege_cross_icon）
    if (this.showSieged) {
      const arm = cs * 0.45 * 0.225;
      const lw = Math.max(1.5, cs * 0.45 * 0.09);
      ctx.strokeStyle = "rgba(255, 40, 40, 0.95)";
      ctx.lineWidth = lw;
      for (const idx of this.siegedStones) {
        const r = Math.floor(idx / size);
        const c = idx % size;
        const cx = pad + c * cs;
        const cy = pad + r * cs;
        ctx.beginPath();
        ctx.moveTo(cx - arm, cy - arm);
        ctx.lineTo(cx + arm, cy + arm);
        ctx.moveTo(cx - arm, cy + arm);
        ctx.lineTo(cx + arm, cy - arm);
        ctx.stroke();
      }
    }

    // 10. 战争迷雾覆盖（半透明浅灰迷雾，盖住视野外区域，隐藏对方棋子）
    if (this.fogActive && this.fogCells.size > 0) {
      ctx.fillStyle = "rgba(150, 152, 160, 0.55)";
      for (const idx of this.fogCells) {
        const r = Math.floor(idx / size);
        const c = idx % size;
        ctx.fillRect(pad + c * cs - cs / 2, pad + r * cs - cs / 2, cs, cs);
      }
    }
  }

  // 边境线呼吸灯（参考原项目 _draw_border_zone_highlight 的 border_zone_pulse 分支）
  // 颜色与效果随主题调整：宽度/呼吸范围/光晕/像素分段由当前主题配置决定
  private _drawBorderZone(): void {
    const ctx = this.ctx;
    const cs = this.cellSize;
    const pad = this.padding;
    const th = this.theme;
    const y = pad + BORDER_ROW * cs - cs * 0.5;
    // 呼吸效果：2s 周期
    const t = (this.time % 2.0) / 2.0;
    const pulse = 0.5 + 0.5 * Math.sin(t * Math.PI * 2);
    const alpha = this.borderPulse
      ? th.borderAlphaMin + (th.borderAlphaMax - th.borderAlphaMin) * pulse
      : th.borderAlphaMin;
    const h = cs * th.borderHeight;
    const base = `rgba(${hexToRgb(th.border)}, `;

    if (th.borderGlow) {
      // 上下光晕渐变（发光感，暗背景主题更明显）
      const glow = ctx.createLinearGradient(0, y - cs * 0.5, 0, y + h + cs * 0.5);
      glow.addColorStop(0, `${base}0)`);
      glow.addColorStop(0.5, `${base}${alpha.toFixed(3)})`);
      glow.addColorStop(1, `${base}0)`);
      ctx.fillStyle = glow;
      ctx.fillRect(pad, y - cs * 0.5, cs * 18, h + cs);
      return;
    }

    if (th.borderDashed) {
      // 像素分段带（每格一个小方块，模拟像素风）
      ctx.fillStyle = `${base}${alpha.toFixed(3)})`;
      const seg = cs * 0.42;
      for (let i = 0; i < 18; i++) {
        ctx.fillRect(pad + i * cs + (cs - seg) / 2, y + h * 0.25, seg, h * 0.5);
      }
      return;
    }

    // 普通呼吸带
    ctx.fillStyle = `${base}${alpha.toFixed(3)})`;
    ctx.fillRect(pad, y, cs * 18, h);
  }

  // 势力热力图：空点按双方影响力差值着色（黑=冷蓝，白=暖金）
  // target 指定绘制上下文（默认主 ctx；静态层重建时传入 staticCtx）
  private _drawInfluence(target?: CanvasRenderingContext2D): void {
    if (!this.influence || this.influence.maxAbs <= 0) return;
    const ctx = target ?? this.ctx;
    const cs = this.cellSize;
    const pad = this.padding;
    const map = this.influence.map;
    const invMax = 1 / this.influence.maxAbs;
    for (let r = 0; r < BOARD_SIZE; r++) {
      for (let c = 0; c < BOARD_SIZE; c++) {
        const idx = r * BOARD_SIZE + c;
        // 棋子点不显示（被棋子覆盖）
        if (this.grid[idx] !== Color.EMPTY) continue;
        const diff = map[idx];
        if (diff === 0) continue;
        const strength = Math.abs(diff) * invMax;
        const x = pad + c * cs - cs / 2;
        const y = pad + r * cs - cs / 2;
        if (diff > 0) {
          // 黑方势力：冷蓝
          ctx.fillStyle = `rgba(80, 140, 255, ${(strength * 0.5).toFixed(3)})`;
        } else {
          // 白方势力：暖金
          ctx.fillStyle = `rgba(255, 190, 80, ${(strength * 0.5).toFixed(3)})`;
        }
        ctx.fillRect(x, y, cs, cs);
      }
    }
  }

  // 打吃（剩最后一口气）呼吸灯：橙色外环呼吸 + 内圈脉冲
  private _drawAtariMarkers(): void {
    if (this.atariStones.size === 0) return;
    const ctx = this.ctx;
    const cs = this.cellSize;
    const pad = this.padding;
    // 呼吸节奏：1s 周期
    const pulse = 0.5 + 0.5 * Math.sin(this.time * Math.PI * 2);
    const radius = cs * 0.45;
    for (const idx of this.atariStones) {
      const r = Math.floor(idx / BOARD_SIZE);
      const c = idx % BOARD_SIZE;
      const cx = pad + c * cs;
      const cy = pad + r * cs;
      // 外层橙色呼吸环（半径随脉冲扩张）
      ctx.strokeStyle = `rgba(255, 140, 40, ${(0.45 + 0.4 * pulse).toFixed(3)})`;
      ctx.lineWidth = 2;
      ctx.beginPath();
      ctx.arc(cx, cy, radius * (1.22 + pulse * 0.16), 0, Math.PI * 2);
      ctx.stroke();
      // 内圈淡黄脉冲（反相呼吸）
      ctx.strokeStyle = `rgba(255, 205, 90, ${(0.3 + 0.3 * (1 - pulse)).toFixed(3)})`;
      ctx.lineWidth = 1.5;
      ctx.beginPath();
      ctx.arc(cx, cy, radius * 1.02, 0, Math.PI * 2);
      ctx.stroke();
    }
  }

  // 特效叠加层绘制（参考原项目 BoardView 各 _draw_*_effect）
  private _drawEffectOverlays(): void {
    const now = this.time;
    // 过滤过期特效（startTime 由 _addOverlay 赋值，此处一定存在）
    this.effectOverlays = this.effectOverlays.filter((ov) => now - (ov.startTime ?? 0) < ov.duration);
    for (const ov of this.effectOverlays) {
      const t = Math.min(1, (now - (ov.startTime ?? 0)) / ov.duration);
      switch (ov.type) {
        case "move": this._drawMovePulse(ov, t); break;
        case "deploy_place": this._drawDeployPlacePulse(ov, t); break;
        case "capture": this._drawCaptureBurst(ov, t); break;
        case "siege": this._drawSiegeEffect(ov, t); break;
        case "siege_broken": this._drawSiegeBroken(ov, t); break;
        case "territory_formed": this._drawTerritoryFormed(ov, t); break;
        case "territory_lost": this._drawTerritoryLost(ov, t); break;
        case "opening": this._drawOpeningAnimation(ov, t); break;
      }
    }
  }

  private _cellPos(row: number, col: number): { x: number; y: number } {
    return { x: this.padding + col * this.cellSize, y: this.padding + row * this.cellSize };
  }

  // 落子脉冲：双层天青扩散环 + 中心闪光（原项目 _draw_move_pulse）
  private _drawMovePulse(ov: EffectOverlay, t: number): void {
    if (!ov.position) return;
    const { x, y } = this._cellPos(ov.position.row, ov.position.col);
    const alpha = Math.pow(1 - t, 1.2) * 0.85; // 更亮、更快衰减
    const baseR = this.cellSize * 0.45;
    // 内层亮环（紧凑扩散 + 高亮天青）
    this.ctx.strokeStyle = `rgba(0, 185, 210, ${alpha.toFixed(3)})`;
    this.ctx.lineWidth = 3;
    this.ctx.beginPath();
    this.ctx.arc(x, y, baseR * (0.9 + t * 0.45), 0, Math.PI * 2);
    this.ctx.stroke();
    // 外层扩散环（更大扩散、更淡青）
    this.ctx.strokeStyle = `rgba(76, 212, 232, ${(alpha * 0.6).toFixed(3)})`;
    this.ctx.lineWidth = 2;
    this.ctx.beginPath();
    this.ctx.arc(x, y, baseR * (1.15 + t * 1.9), 0, Math.PI * 2);
    this.ctx.stroke();
    // 中心闪光：缩拢亮点
    const glow = (1 - t) * 0.55;
    this.ctx.fillStyle = `rgba(216, 248, 255, ${glow.toFixed(3)})`;
    this.ctx.beginPath();
    this.ctx.arc(x, y, baseR * 0.5 * (1 - t * 0.6), 0, Math.PI * 2);
    this.ctx.fill();
  }

  // 布局落子脉冲：青绿色双层扩散环（原项目 _draw_deploy_place_pulse）
  private _drawDeployPlacePulse(ov: EffectOverlay, t: number): void {
    if (!ov.position) return;
    const { x, y } = this._cellPos(ov.position.row, ov.position.col);
    const alpha = (1 - t) * 0.6;
    const baseR = this.cellSize * 0.45;
    // 内层亮环
    this.ctx.strokeStyle = `rgba(89, 229, 165, ${alpha.toFixed(3)})`;
    this.ctx.lineWidth = 2;
    this.ctx.beginPath();
    this.ctx.arc(x, y, baseR * (1 + t * 0.6), 0, Math.PI * 2);
    this.ctx.stroke();
    // 外层扩散环
    this.ctx.strokeStyle = `rgba(51, 178, 128, ${(alpha * 0.6).toFixed(3)})`;
    this.ctx.lineWidth = 1.5;
    this.ctx.beginPath();
    this.ctx.arc(x, y, baseR * (1.2 + t * 1.6), 0, Math.PI * 2);
    this.ctx.stroke();
  }

  // 提子：被吃棋子上升渐大淡出 + 震波扩散（原项目 _draw_capture_burst）
  private _drawCaptureBurst(ov: EffectOverlay, t: number): void {
    const positions = ov.positions ?? [];
    if (positions.length === 0) return;
    const baseR = this.cellSize * 0.45;
    const cw = this.theme.captureWave; // 主题提子色
    const stoneColor = ov.color ?? Color.BLACK; // 被吃棋子颜色
    const fill = stoneColor === Color.BLACK ? this.theme.blackLo : this.theme.whiteLo;
    const edge = stoneColor === Color.BLACK ? this.theme.blackEdge : this.theme.whiteEdge;
    for (const p of positions) {
      const { x, y } = this._cellPos(p.row, p.col);
      // 1) 震波扩散：双层环从吃子点向四周扩散并淡出
      const ringA = (1 - t) * 0.9;
      this.ctx.strokeStyle = `rgba(${cw[0]}, ${cw[1]}, ${cw[2]}, ${ringA.toFixed(3)})`;
      this.ctx.lineWidth = 3;
      this.ctx.beginPath();
      this.ctx.arc(x, y, baseR * (0.8 + t * 2.4), 0, Math.PI * 2);
      this.ctx.stroke();
      const ringA2 = (1 - t) * 0.5;
      this.ctx.strokeStyle = `rgba(0, 185, 210, ${ringA2.toFixed(3)})`; // 天青副环
      this.ctx.lineWidth = 1.5;
      this.ctx.beginPath();
      this.ctx.arc(x, y, baseR * (1.1 + t * 3.2), 0, Math.PI * 2);
      this.ctx.stroke();
      // 2) 被吃棋子：上升 + 渐大 + 淡出
      const rise = t * this.cellSize * 0.6;
      const r = baseR * (0.42 + t * 0.5);
      this.ctx.globalAlpha = Math.max(0, 1 - t);
      this.ctx.fillStyle = fill;
      this.ctx.beginPath();
      this.ctx.arc(x, y - rise, r, 0, Math.PI * 2);
      this.ctx.fill();
      this.ctx.lineWidth = 1.5;
      this.ctx.strokeStyle = edge;
      this.ctx.stroke();
    }
    this.ctx.globalAlpha = 1;
  }

  // 围困形成：红色脉冲环（2层，原项目 _draw_siege_effect）
  private _drawSiegeEffect(ov: EffectOverlay, t: number): void {
    const stones = ov.stones ?? [];
    if (stones.length === 0) return;
    const alpha = 1 - t;
    const baseR = this.cellSize * 0.45;
    for (const s of stones) {
      const { x, y } = this._cellPos(s.row, s.col);
      this.ctx.strokeStyle = `rgba(229, 51, 26, ${(alpha * 0.7).toFixed(3)})`;
      this.ctx.lineWidth = 2;
      this.ctx.beginPath();
      this.ctx.arc(x, y, baseR * (1.2 + t * 0.8), 0, Math.PI * 2);
      this.ctx.stroke();
      const t2 = Math.min(1, Math.max(0, (t - 0.2) / 0.8));
      if (t2 > 0) {
        this.ctx.strokeStyle = `rgba(204, 38, 26, ${((1 - t2) * 0.5).toFixed(3)})`;
        this.ctx.lineWidth = 1.5;
        this.ctx.beginPath();
        this.ctx.arc(x, y, baseR * (1 + t2 * 1.5), 0, Math.PI * 2);
        this.ctx.stroke();
      }
    }
  }

  // 围困解除：绿色光环扩散（原项目 _draw_siege_broken）
  private _drawSiegeBroken(ov: EffectOverlay, t: number): void {
    const stones = ov.stones ?? [];
    if (stones.length === 0) return;
    const alpha = 1 - t;
    const baseR = this.cellSize * 0.45;
    for (const s of stones) {
      const { x, y } = this._cellPos(s.row, s.col);
      this.ctx.strokeStyle = `rgba(51, 229, 102, ${(alpha * 0.7).toFixed(3)})`;
      this.ctx.lineWidth = 2;
      this.ctx.beginPath();
      this.ctx.arc(x, y, baseR * (1.2 + t * 1.2), 0, Math.PI * 2);
      this.ctx.stroke();
      const t2 = Math.min(1, Math.max(0, (t - 0.2) / 0.8));
      if (t2 > 0) {
        this.ctx.strokeStyle = `rgba(77, 204, 77, ${((1 - t2) * 0.5).toFixed(3)})`;
        this.ctx.lineWidth = 1.5;
        this.ctx.beginPath();
        this.ctx.arc(x, y, baseR * (1 + t2 * 1.8), 0, Math.PI * 2);
        this.ctx.stroke();
      }
    }
  }

  // 围空形成：圈内光晕扩散 + 中心扩散环（原项目 _draw_territory_formed）
  private _drawTerritoryFormed(ov: EffectOverlay, t: number): void {
    const points = ov.points ?? [];
    if (points.length === 0) return;
    const alpha = 1 - t;
    const fill = ov.color === Color.BLACK ? "20, 20, 20" : "245, 245, 245";
    const cs = this.cellSize;
    // 圈内逐点光晕扩散（波纹效果）
    for (let i = 0; i < points.length; i++) {
      const p = points[i];
      const { x, y } = this._cellPos(p.row, p.col);
      const delay = (i / points.length) * 0.3;
      const pt = Math.min(1, Math.max(0, (t - delay) / (1 - delay)));
      if (pt <= 0) continue;
      const ptAlpha = (1 - pt) * 0.6;
      const s = cs * 0.5 * (0.5 + pt * 0.8);
      this.ctx.fillStyle = `rgba(${fill}, ${ptAlpha.toFixed(3)})`;
      this.ctx.fillRect(x - s, y - s, s * 2, s * 2);
    }
    // 中心扩散环
    let cx = 0, cy = 0;
    for (const p of points) {
      const pos = this._cellPos(p.row, p.col);
      cx += pos.x; cy += pos.y;
    }
    cx /= points.length;
    cy /= points.length;
    const ringColor = ov.color === Color.BLACK ? "30, 30, 30" : "150, 200, 255";
    this.ctx.strokeStyle = `rgba(${ringColor}, ${(alpha * 0.5).toFixed(3)})`;
    this.ctx.lineWidth = 2;
    this.ctx.beginPath();
    this.ctx.arc(cx, cy, this.cellSize * 0.45 * (1 + t * 4), 0, Math.PI * 2);
    this.ctx.stroke();
  }

  // 围空失守：灰色消散 + 边界红闪（原项目 _draw_territory_lost）
  private _drawTerritoryLost(ov: EffectOverlay, t: number): void {
    const points = ov.points ?? [];
    if (points.length === 0) return;
    const alpha = 1 - t;
    const cs = this.cellSize;
    for (const p of points) {
      const { x, y } = this._cellPos(p.row, p.col);
      // 灰色消散
      this.ctx.fillStyle = `rgba(128, 128, 128, ${(alpha * 0.4).toFixed(3)})`;
      this.ctx.fillRect(x - cs * 0.5, y - cs * 0.5, cs, cs);
      // 边界红闪
      this.ctx.strokeStyle = `rgba(229, 51, 26, ${(alpha * 0.6).toFixed(3)})`;
      this.ctx.lineWidth = 2;
      this.ctx.strokeRect(x - cs * 0.5, y - cs * 0.5, cs, cs);
    }
  }

  // 开局圆形扩散波浪：从棋盘中央开始，波纹沿方格向四周扩散（1.4s）
  // 参考原项目 BoardView._draw_circular_wave
  private _drawOpeningAnimation(_ov: EffectOverlay, t: number): void {
    const ctx = this.ctx;
    const cs = this.cellSize;
    const pad = this.padding;
    const intensity = Math.sin(t * Math.PI); // 整体强度 0→1→0

    // 棋盘中央（18 格区域中心）
    const centerX = pad + cs * 9;
    const centerY = pad + cs * 9;

    // 波纹参数
    const wavelength = 2.4;
    const waveSpeed = 3.8;
    const phaseBase = -this.time * waveSpeed * Math.PI * 2 / wavelength;

    // 遍历 18×18 方格
    for (let gr = 0; gr < 18; gr++) {
      const rowCenter = gr + 0.5;
      const y = pad + cs * gr;
      for (let gc = 0; gc < 18; gc++) {
        const colCenter = gc + 0.5;
        const dx = colCenter - 9.0;
        const dy = rowCenter - 9.0;
        const dist = Math.sqrt(dx * dx + dy * dy);
        // 波纹相位：距离越远相位越滞后，随时间向外扩散
        const phase = dist * Math.PI * 2 / wavelength + phaseBase;
        // 多环叠加：2 个波纹层
        let wave = (Math.sin(phase) + 0.5 * Math.sin(phase * 2.0 + 0.6)) * 0.5;
        wave = Math.max(0, wave) * intensity;
        if (wave < 0.05) continue;

        const x = pad + cs * gc;
        // 颜色：主题开局波浪色，中心加白提亮（亮心→主题色边缘）
        const base = this.theme.openingWave;
        const warm = Math.max(0.2, Math.min(1.0, 1.0 - dist / 13.0));
        const r = Math.round(base[0] + (255 - base[0]) * warm * 0.4);
        const g = Math.round(base[1] + (255 - base[1]) * warm * 0.4);
        const b = Math.round(base[2] + (255 - base[2]) * warm * 0.4);
        ctx.fillStyle = `rgba(${r}, ${g}, ${b}, ${(0.42 * wave).toFixed(3)})`;
        ctx.fillRect(x, y, cs, cs);
      }
    }

    // 中心光晕（波纹源点，随动画呼吸，主题色提亮）
    const centerGlowA = 0.35 * intensity;
    ctx.fillStyle = `rgba(${lightenRgb(this.theme.openingWave, 60)}, ${centerGlowA.toFixed(3)})`;
    ctx.beginPath();
    ctx.arc(centerX, centerY, cs * (1.2 + 0.6 * intensity), 0, Math.PI * 2);
    ctx.fill();

    // 扩散前沿光环（随波纹半径移动，主题开局色）
    const ringR = (this.time * waveSpeed * cs) % (cs * 13);
    const ringA = 0.30 * intensity;
    ctx.strokeStyle = `rgba(${this.theme.openingWave[0]}, ${this.theme.openingWave[1]}, ${this.theme.openingWave[2]}, ${ringA.toFixed(3)})`;
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.arc(centerX, centerY, ringR, 0, Math.PI * 2);
    ctx.stroke();
  }

  // target 指定绘制上下文（默认主 ctx；静态层重建时传入 staticCtx）
  private _drawStone(col: number, row: number, color: Color, target?: CanvasRenderingContext2D): void {
    const ctx = target ?? this.ctx;
    const cs = this.cellSize;
    const pad = this.padding;
    const cx = pad + col * cs;
    const cy = pad + row * cs;
    const th = this.theme;
    const radius = cs * 0.45;
    const hi = color === Color.BLACK ? th.blackHi : th.whiteHi;
    const lo = color === Color.BLACK ? th.blackLo : th.whiteLo;
    const edge = color === Color.BLACK ? th.blackEdge : th.whiteEdge;

    // 阴影
    ctx.beginPath();
    ctx.arc(cx + 1, cy + 2, radius, 0, Math.PI * 2);
    ctx.fillStyle = "rgba(0, 0, 0, 0.3)";
    ctx.fill();

    // 棋子主体（带渐变）
    const grad = ctx.createRadialGradient(cx - radius * 0.3, cy - radius * 0.3, radius * 0.1, cx, cy, radius);
    grad.addColorStop(0, hi);
    grad.addColorStop(1, lo);
    ctx.beginPath();
    ctx.arc(cx, cy, radius, 0, Math.PI * 2);
    ctx.fillStyle = grad;
    ctx.fill();

    // 边框
    ctx.strokeStyle = edge;
    ctx.lineWidth = 0.5;
    ctx.stroke();
  }

  // 动画循环：驱动特效 + 边境线呼吸灯持续重绘
  private _startAnimLoop(): void {
    if (this.animFrame !== null) return;
    const loop = () => {
      if (this._destroyed) {
        this.animFrame = null;
        return;
      }
      this.time = performance.now() / 1000;
      // 有活跃特效/打吃呼吸灯/边境线呼吸灯/布局辉光时持续重绘
      // （热力图已在静态层，无需每帧重绘）
      const hasActive =
        this.effectOverlays.length > 0 ||
        this.borderPulse ||
        this.atariStones.size > 0 ||
        this.deployPhase;
      if (!hasActive && this.hoverPos === null) {
        this.animFrame = null;
        return;
      }
      this.render();
      this.animFrame = requestAnimationFrame(loop);
    };
    this.animFrame = requestAnimationFrame(loop);
  }

  private _bindEvents(): void {
    this.canvas.addEventListener("click", (e) => {
      const rect = this.canvas.getBoundingClientRect();
      const scaleX = this.canvas.width / rect.width;
      const scaleY = this.canvas.height / rect.height;
      const x = (e.clientX - rect.left) * scaleX;
      const y = (e.clientY - rect.top) * scaleY;
      const pos = this.pixelToBoard(x, y);
      if (pos) this.onCellClick?.(pos.row, pos.col);
    });

    this.canvas.addEventListener("mousemove", (e) => {
      const rect = this.canvas.getBoundingClientRect();
      const scaleX = this.canvas.width / rect.width;
      const scaleY = this.canvas.height / rect.height;
      const x = (e.clientX - rect.left) * scaleX;
      const y = (e.clientY - rect.top) * scaleY;
      const pos = this.pixelToBoard(x, y);
      this.setHover(pos);
    });

    this.canvas.addEventListener("mouseleave", () => {
      this.setHover(null);
    });
  }
}
