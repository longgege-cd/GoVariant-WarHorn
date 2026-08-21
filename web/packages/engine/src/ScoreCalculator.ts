// 得分计算（v7.3 全分数动态结算）
// 总分 = 占领分(围空+效率奖励) + 防御分(歼灭+围困) - 战损分
// v7.3 已取消活子分：落子本身不得分，只有围空才得分
// 对应 GDScript c:\边境线\scripts\core\ScoreCalculator.gd (209行)

import { Color, opponent, isAttackZone, isDefenseZone } from "./Const.js";
import { BoardModel, Point, Group } from "./BoardModel.js";
import { SiegeDetector, DeadAliveResult } from "./SiegeDetector.js";
import { TerritoryDetector, Enclosure } from "./TerritoryDetector.js";
import type { ScoreBreakdown, ScoreSide, FinalResult } from "@warhorn/shared";

export interface Counters {
  annihilate: number; // 歼灭分累计（实际提吃次数）
  normalLost: number; // 普通子被提次数
  specialLost: number; // 特种部队被提次数（MVP 不用，保留接口）
}

export type CountersMap = Map<Color, Counters>;

export function makeCounters(): CountersMap {
  return new Map([
    [Color.BLACK, { annihilate: 0, normalLost: 0, specialLost: 0 }],
    [Color.WHITE, { annihilate: 0, normalLost: 0, specialLost: 0 }],
  ]);
}

export function makeBreakdown(): ScoreBreakdown {
  return {
    occupationLive: 0,
    occupationTerritory: 0,
    occupationEfficiency: 0,
    defenseAnnihilate: 0,
    defenseSiege: 0,
    casualtyLoss: 0,
    casualtySpecial: 0,
  };
}

export interface ScoreResult {
  black: ScoreBreakdown;
  white: ScoreBreakdown;
}

export class ScoreCalculator {
  // 盘中实时计分（6步）
  static compute(
    board: BoardModel,
    counters: CountersMap,
    precomputedSieged?: Group[],
    precomputedEncs?: Enclosure[]
  ): ScoreResult {
    const bk = makeBreakdown();
    const wt = makeBreakdown();

    // 步骤1: 识别所有围困棋子
    const siegedStonesSet = new Map<number, Color>(); // idx -> color
    let siegedGroupsList: Group[];
    if (precomputedSieged) {
      siegedGroupsList = precomputedSieged;
    } else {
      const da = SiegeDetector.solveDeadAlive(board);
      siegedGroupsList = da.sieged;
    }
    for (const g of siegedGroupsList) {
      for (const s of g.stones) siegedStonesSet.set(s.row * board.size + s.col, g.color);
    }

    // 步骤2: 围空分
    const encs = precomputedEncs ?? TerritoryDetector.enclosures(board);
    for (const e of encs) {
      const target = e.color === Color.BLACK ? bk : wt;
      // 圈内空点 +2/点
      for (const p of e.points) {
        if (isAttackZone(p.row, e.color)) target.occupationTerritory += 2;
      }
    }
    // 围空分：圈内对方围困棋子位置 +2/点（规则3.4）。
    // 关键：不依赖 enclosure.stonesInside——圈内全被对方围困棋子填满（无空点）时
    // TerritoryDetector 不产生围空圈，若仅靠 stonesInside 则围死棋子的围空分会丢失。
    // 被围困（sieged）本身即"在包围圈内"，直接按 sieged 组群计分即可。
    for (const g of siegedGroupsList) {
      const opp = opponent(g.color); // 围困方
      const oppTarget = opp === Color.BLACK ? bk : wt;
      for (const s of g.stones) {
        if (isAttackZone(s.row, opp)) oppTarget.occupationTerritory += 2;
      }
    }

    // 步骤3: 扣除围困棋子自形包围圈的围空分（规则3.4 + 6.3嵌套）
    for (const e of encs) {
      if (!ScoreCalculator.isEnclosureFormedBySieged(board, e, siegedStonesSet)) continue;
      const encColor = e.color;
      const target = encColor === Color.BLACK ? bk : wt;
      // 扣除围空方围空分
      for (const p of e.points) {
        if (isAttackZone(p.row, encColor)) target.occupationTerritory -= 2;
      }
      for (const s of e.stonesInside) {
        const sidx = s.row * board.size + s.col;
        if (!siegedStonesSet.has(sidx)) continue;
        if (isAttackZone(s.row, encColor)) target.occupationTerritory -= 2;
      }
      // 嵌套归属：无效包围圈空点归对手方（规则6.3）
      const opp = opponent(encColor);
      const oppTarget = opp === Color.BLACK ? bk : wt;
      for (const p of e.points) {
        if (isAttackZone(p.row, opp)) oppTarget.occupationTerritory += 2;
      }
    }

    // 步骤4: 效率奖励（v7.3 §3.2）：每个独立有效包围圈分别计算
    // 有效围空点数 = 圈内空点(攻击区) + 圈内被围困的对方棋子(攻击区)
    // 仅由活棋围成的有效包围圈获得奖励（围困棋子围成的无效圈不给）
    for (const e of encs) {
      if (ScoreCalculator.isEnclosureFormedBySieged(board, e, siegedStonesSet)) continue;
      const target = e.color === Color.BLACK ? bk : wt;
      let valid = 0;
      for (const p of e.points) {
        if (isAttackZone(p.row, e.color)) valid++;
      }
      for (const s of e.stonesInside) {
        const sidx = s.row * board.size + s.col;
        if (!siegedStonesSet.has(sidx)) continue;
        if (isAttackZone(s.row, e.color)) valid++;
      }
      if (valid >= 4) target.occupationEfficiency += 2 * Math.floor(valid / 4);
    }

    // 步骤5: 围困分（围困棋子按所在区域计分，+2/子于围困方己境/边境）
    for (const g of siegedGroupsList) {
      const color = g.color; // 被围困方
      const opp = opponent(color); // 围困方
      const oppTarget = opp === Color.BLACK ? bk : wt;
      for (const s of g.stones) {
        if (isDefenseZone(s.row, opp)) oppTarget.defenseSiege += 2;
      }
    }

    // 步骤6: 累计事件分（歼灭分/战损分）
    ScoreCalculator._applyCounters(bk, wt, counters);

    return { black: bk, white: wt };
  }

  // 终局结算
  static computeFinal(
    board: BoardModel,
    counters: CountersMap,
    komi: number
  ): FinalResult {
    const res = ScoreCalculator.compute(board, counters);
    const bk = res.black;
    const wt = res.white;

    const bkTotal = ScoreCalculator._total(bk);
    const wtTotal = ScoreCalculator._total(wt);
    const bkFinal = bkTotal - komi;
    const wtFinal = wtTotal;

    let winner = "和棋";
    let winnerColor: Color = Color.EMPTY;
    if (bkFinal > wtFinal) { winner = "黑方胜"; winnerColor = Color.BLACK; }
    else if (wtFinal > bkFinal) { winner = "白方胜"; winnerColor = Color.WHITE; }

    const blackSide: ScoreSide = { breakdown: bk, total: bkTotal, komi, final: bkFinal };
    const whiteSide: ScoreSide = { breakdown: wt, total: wtTotal, komi: 0, final: wtFinal };

    return {
      black: blackSide,
      white: whiteSide,
      winner,
      winnerColor,
      reason: "", // 由 GameSession 填充
      ply: 0,     // 由 GameSession 填充
    };
  }

  // 无效包围圈判定：围空方边界棋子任一为围困 → 无效
  static isEnclosureFormedBySieged(
    board: BoardModel,
    enclosure: Enclosure,
    siegedStonesSet: Map<number, Color>
  ): boolean {
    const encColor = enclosure.color;
    const size = board.size;
    for (const idx of enclosure.borderStonesIdx) {
      const r = Math.floor(idx / size);
      const c = idx % size;
      if (board.getAt(r, c) !== encColor) continue; // 对方棋子作为边界，不影响判定
      if (siegedStonesSet.has(idx)) return true;
    }
    return false;
  }

  private static _applyCounters(bk: ScoreBreakdown, wt: ScoreBreakdown, counters: CountersMap): void {
    for (const color of [Color.BLACK, Color.WHITE]) {
      const c = counters.get(color) ?? { annihilate: 0, normalLost: 0, specialLost: 0 };
      const b = color === Color.BLACK ? bk : wt;
      b.defenseAnnihilate += c.annihilate * 3;
      b.casualtyLoss -= c.normalLost;
      b.casualtySpecial -= c.specialLost * 6;
    }
  }

  private static _total(b: ScoreBreakdown): number {
    return (
      b.occupationTerritory +
      b.occupationEfficiency +
      b.defenseAnnihilate +
      b.defenseSiege +
      b.casualtyLoss +
      b.casualtySpecial
    );
  }
}
