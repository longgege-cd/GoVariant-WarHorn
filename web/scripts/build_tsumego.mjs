// 一次性生成脚本：解析 GoGameGuru 真死活题 SGF（gogameguru/go-problems，CC BY-NC-SA 4.0）
// 输入：c:\边境线\_tsumego_ref\weekly-go-problems\{easy,intermediate,hard}\*.sgf
// 输出：c:\边境线\web\packages\engine\src\puzzles_tsumego.ts（内嵌 30 题含正解序列）
import { readdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const DIR = dirname(fileURLToPath(import.meta.url));
const REF = join(DIR, "..", "..", "_tsumego_ref", "weekly-go-problems");
const OUT = join(DIR, "..", "packages", "engine", "src", "puzzles_tsumego.ts");

const letter = (ch) => ch.charCodeAt(0) - 97; // a=0..s=18

// ---- 极小 SGF 树解析（只取所需的属性）----
class Node {
  constructor() { this.color = null; this.point = null; this.comment = ""; this.children = []; }
}
function parseSgf(text) {
  const root = new Node();
  let i = 0;
  const stack = [root];
  const cur = () => stack[stack.length - 1];
  while (i < text.length) {
    const ch = text[i];
    if (ch === ";") { // 新节点
      const n = new Node();
      cur().children.push(n);
      stack.push(n);
      i++;
    } else if (ch === "(") { // 分支（回到当前节点层级）
      i++;
    } else if (ch === ")") { // 弹出
      if (stack.length > 1) stack.pop();
      i++;
    } else if (ch === "[") { // 属性值
      let v = "";
      i++;
      while (i < text.length && text[i] !== "]") { v += text[i]; i++; }
      i++; // 跳过 ]
      cur()["__lastVal"] = v;
    } else if (ch === "]") {
      i++;
    } else if (/[A-Z]/.test(ch)) { // 属性名
      let name = ch;
      i++;
      while (i < text.length && /[A-Z]/.test(text[i])) { name += text[i]; i++; }
      const node = cur();
      const vals = [];
      while (i < text.length && text[i] === "[") {
        i++;
        let v = "";
        while (i < text.length && text[i] !== "]") { v += text[i]; i++; }
        i++;
        vals.push(v);
      }
      const v = vals.join(" ");
      if (name === "B" || name === "W") {
        // 可能是 B[aa] 或 B[aa][ab]（罕见）；取第一个落子坐标
        const co = vals[0];
        if (co && co.length === 2 && /^[a-s]{2}$/i.test(co)) {
          node.color = name;
          node.point = [letter(co[1]), letter(co[0])]; // [row, col]
        }
      } else if (name === "C") {
        node.comment = v;
      }
    } else {
      i++;
    }
  }
  return root;
}

function hasCorrect(n) {
  if (n.comment && /correct/i.test(n.comment)) return true;
  return n.children.some(hasCorrect);
}

// 深度优先找首个落子节点颜色（= 执子手）
function firstMoveColor(root) {
  const stack = [root];
  const popped = [];
  while (stack.length) {
    const n = stack[stack.length - 1];
    if (!n.__done) {
      n.__done = true;
      for (let i = n.children.length - 1; i >= 0; i--) stack.push(n.children[i]);
    } else {
      stack.pop();
      popped.push(n);
    }
  }
  for (const n of popped) if (n.color) return n.color;
  return null;
}

// 提取「正解动手序列」：仅保留执子手颜色著法的極长序列（透明穿透无落子的中间节点）
function extractSequences(root, solver) {
  const out = new Set();
  const key = (seq) => seq.map(([r, c]) => r * 19 + c).join(",");
  function walk(node, seq) {
    let extended = false;
    for (const c of node.children.filter((x) => x.color === solver && x.point && hasCorrect(x))) {
      walk(c, [...seq, c.point]);
      extended = true;
    }
    for (const c of node.children.filter((x) => x.point && x.color !== solver && hasCorrect(x))) {
      walk(c, seq);
      extended = true;
    }
    // 无落子点的纯属性节点（setup/C 注释分组）→ 透明穿透
    for (const c of node.children.filter((x) => !x.point && hasCorrect(x))) {
      walk(c, seq);
      extended = true;
    }
    if (!extended && seq.length > 0) out.add(key(seq) + "|" + JSON.stringify(seq));
  }
  walk(root, []);
  const res = [];
  for (const entry of out) {
    const seq = JSON.parse(entry.slice(entry.indexOf("|") + 1));
    res.push(seq);
  }
  res.sort((a, b) => a.length - b.length);
  return res;
}

const DIFFS = ["easy", "intermediate", "hard"];
const picked = { easy: [], intermediate: [], hard: [] };
const stats = { parsed: 0, skippedNoCorrect: 0, skippedNoSeq: 0, skippedTooLong: 0, chosen: 0 };

for (const diff of DIFFS) {
  const dir = join(REF, diff);
  if (!existsSync(dir)) continue;
  const files = readdirSync(dir).filter((f) => f.endsWith(".sgf")).sort((a, b) => {
    const na = parseInt(a.match(/\d+/)[0], 10), nb = parseInt(b.match(/\d+/)[0], 10);
    return na - nb;
  });
  for (const f of files) {
    if (picked[diff].length >= 10) break;
    const text = readFileSync(join(dir, f), "utf8");
    const root = parseSgf(text);
    if (!hasCorrect(root)) { stats.skippedNoCorrect++; continue; }
    // 棋盘尺寸与 setup
    const szMatch = text.match(/SZ\[(\d+)\]/);
    const size = szMatch ? parseInt(szMatch[1], 10) : 19;
    const ab = [], aw = [];
    const abM = text.match(/AB(\[(?:[a-t]{2})\])+/g);
    const awM = text.match(/AW(\[(?:[a-t]{2})\])+/g);
    const addStones = (m, arr) => {
      if (!m) return;
      for (const g of m) {
        const co = g.match(/\[[a-t]{2}\]/g);
        for (const c of co) {
          const p = c.slice(1, 3);
          arr.push([letter(p[1]), letter(p[0])]);
        }
      }
    };
    addStones(abM, ab);
    addStones(awM, aw);
    // 执子色 = 首手颜色
    const solver = firstMoveColor(root);
    if (!solver) { stats.skippedNoSeq++; continue; }
    const seqs = extractSequences(root, solver)
      .filter((s) => s.length >= 1)
      // 过滤与 setup 占点（AB/AW）冲突的序列：正解落子不能落在已有的黑/白子上
      .filter((s) => {
        const occ = new Set([...ab, ...aw].map(([r, c]) => r * 19 + c));
        return s.every(([r, c]) => !occ.has(r * 19 + c));
      })
      // 过滤序列内重复落子的序列（源 SGF 坏分支陷阱）
      .filter((s) => new Set(s.map(([r, c]) => r * 19 + c)).size === s.length);
    if (seqs.length === 0) { stats.skippedNoSeq++; continue; }
    const longest = seqs[seqs.length - 1];
    if (longest.length > 16) { stats.skippedTooLong++; continue; }
    picked[diff].push({ f, size, ab, aw, solver, seqs });
    stats.chosen++;
  }
}

if (stats.chosen < 30) {
  console.error(`仅挑出 ${stats.chosen} 题，不足 30 题！`, stats);
  process.exit(1);
}

// 拼接：易1-10 / 中11-20 / 难21-30
const titled = [];
for (let p = 0; p < picked.easy.length; p++) {
  const d = picked.easy[p];
  titled.push({ ...d, diff: "easy", idx: p + 1, label: "易" });
}
for (let p = 0; p < picked.intermediate.length; p++) {
  const d = picked.intermediate[p];
  titled.push({ ...d, diff: "intermediate", idx: p + 1, label: "中" });
}
for (let p = 0; p < picked.hard.length; p++) {
  const d = picked.hard[p];
  titled.push({ ...d, diff: "hard", idx: p + 1, label: "难" });
}

const row = (arr) => arr.map(([r, c]) => `[${r},${c}]`).join(",");
const lines = [];
lines.push("// 由 scripts/build_tsumego.mjs 从 GoGameGuru 真死活题 SGF 生成，勿手改。");
lines.push("// 数据源：github.com/gogameguru/go-problems（An Younggil 9p & David Ormerod），CC BY-NC-SA 4.0");
lines.push('import { Color } from "./Const.js";');
lines.push("");
lines.push("export interface TsumegoSeqEntry {");
lines.push("  id: number;");
lines.push('  level: 1 | 2 | 3 | 4;');
lines.push('  title: string;');
lines.push('  source: string;');
lines.push('  black: Array<[number, number]>;');
lines.push('  white: Array<[number, number]>;');
lines.push('  solver: Color;');
lines.push('  sequences: Array<Array<[number, number]>>; // 正解着法序列（仅执子手）');
lines.push("}");
lines.push("");
lines.push("export const TSUMEGO_LIST: TsumegoSeqEntry[] = [");
for (let i = 0; i < titled.length; i++) {
  const d = titled[i];
  // 金字塔式递增：简单5 / 普通7 / 困难8 / 大师10
  const level = i < 5 ? 1 : i < 12 ? 2 : i < 20 ? 3 : 4;
  const label = level === 1 ? "易" : level === 2 ? "中" : level === 3 ? "难" : "大师";
  const sf = d.solver === "B" ? "Color.BLACK" : "Color.WHITE";
  lines.push(`  {`);
  lines.push(`    id: ${i + 1},`);
  lines.push(`    level: ${level},`);
  lines.push(`    title: "第 ${i + 1} 关 · ${label}",`);
  lines.push(`    source: "${d.diff}/${d.f}",`);
  lines.push(`    black: [${row(d.ab)}],`);
  lines.push(`    white: [${row(d.aw)}],`);
  lines.push(`    solver: ${sf},`);
  lines.push(`    sequences: [`);
  for (const s of d.seqs) {
    lines.push(`      [${row(s)}],`);
  }
  lines.push(`    ],`);
  lines.push(`  },`);
}
lines.push("];");
lines.push("");

writeFileSync(OUT, lines.join("\n"), "utf8");
console.log(`生成 ${OUT}（${stats.chosen} 题）`);
for (const diff of DIFFS) {
  console.log(
    `  ${diff}: 挑出前 ${Math.min(10, picked[diff].length)} 题 -> ${picked[diff].map((d) => d.f).join(", ")}`
  );
}
console.log("统计:", stats);