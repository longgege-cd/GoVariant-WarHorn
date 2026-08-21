// 边境线棋盘特效验证脚本
// 直接通过 CDP 控制系统 Chrome（headless），不依赖 agent-browser
// 用法: node verify_board.mjs
import { spawn } from "node:child_process";
import { mkdirSync, writeFileSync, existsSync, rmSync } from "node:fs";
import { join } from "node:path";

const CHROME = "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe";
const BASE = join(import.meta.dirname);
const PROFILE = join(BASE, "profile");
const PORT = 9223;
const URL = "http://localhost:5173/";
const SHOT = (name) => join(BASE, name);

mkdirSync(BASE, { recursive: true });
if (existsSync(PROFILE)) rmSync(PROFILE, { recursive: true, force: true });

// ============ Chrome 启动 ============
const chrome = spawn(
  CHROME,
  [
    "--headless=new",
    `--remote-debugging-port=${PORT}`,
    `--user-data-dir=${PROFILE}`,
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-gpu",
    "--hide-scrollbars",
    "--mute-audio",
    "--disable-backgrounding-occluded-windows",
    "--disable-renderer-backgrounding",
    "--window-size=1400,1000",
    "about:blank",
  ],
  { stdio: "ignore", windowsHide: true }
);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// 等待 CDP 端口
async function waitCDP(retries = 40) {
  for (let i = 0; i < retries; i++) {
    try {
      const res = await fetch(`http://127.0.0.1:${PORT}/json/list`);
      if (res.ok) return await res.json();
    } catch {}
    await sleep(300);
  }
  throw new Error("CDP port not ready");
}

// ============ CDP 客户端 ============
class CDP {
  constructor(ws) {
    this.ws = ws;
    this.id = 0;
    this.pending = new Map();
    this.consoleErrors = [];
    this.pageErrors = [];
    this.ws.onmessage = (ev) => {
      const msg = JSON.parse(ev.data);
      if (msg.id && this.pending.has(msg.id)) {
        const { resolve, reject } = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        if (msg.error) reject(new Error(JSON.stringify(msg.error)));
        else resolve(msg.result);
      } else if (msg.method === "Runtime.exceptionThrown") {
        const d = msg.params.exceptionDetails;
        this.pageErrors.push((d.exception?.description || d.text || "").slice(0, 500));
      } else if (msg.method === "Runtime.consoleAPICalled") {
        const type = msg.params.type;
        if (type === "error" || type === "warning") {
          const txt = msg.params.args.map((a) => a.value ?? a.description ?? "").join(" ");
          this.consoleErrors.push(`[${type}] ${txt}`.slice(0, 500));
        }
      } else if (msg.method === "Log.entryAdded") {
        const e = msg.params.entry;
        if (e.level === "error") this.consoleErrors.push(`[log] ${e.text}`.slice(0, 500));
      }
    };
  }
  send(method, params = {}) {
    const id = ++this.id;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params }));
    });
  }
  close() {
    try { this.ws.close(); } catch {}
  }
}

// ============ 主流程 ============
try {
  console.log("[1] waiting for CDP...");
  const targets = await waitCDP();
  const page = targets.find((t) => t.type === "page");
  if (!page) throw new Error("no page target");

  console.log("[2] connecting websocket...");
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
  const cdp = new CDP(ws);

  await cdp.send("Page.enable");
  await cdp.send("Runtime.enable");
  await cdp.send("Log.enable");
  console.log("[3] navigate...");
  await cdp.send("Page.navigate", { url: URL });
  await sleep(2500);

  // 检查名字界面
  const ev = async (expr) => {
    const r = await cdp.send("Runtime.evaluate", { expression: expr, returnByValue: true });
    if (r.exceptionDetails) throw new Error("eval failed: " + JSON.stringify(r.exceptionDetails).slice(0, 300));
    return r.result.value;
  };

  const hasNameScreen = await ev(`!!document.querySelector('#name-input')`);
  console.log("[4] name screen present:", hasNameScreen);

  if (hasNameScreen) {
    // 输入名字并点击开始（默认本地对战模式）
    await ev(`(() => {
      const ni = document.querySelector('#name-input');
      ni.value = '特效测试';
      ni.dispatchEvent(new Event('input', { bubbles: true }));
      document.querySelector('#start-btn').click();
      return true;
    })()`);
    await sleep(2500);
  }

  const hasBoard = await ev(`!!document.querySelector('#board-canvas')`);
  console.log("[5] board present:", hasBoard);
  if (!hasBoard) {
    console.log("STATUS_TEXT:", await ev(`document.body.innerText.slice(0, 300)`));
    throw new Error("board canvas not found");
  }

  const boardInfo = await ev(`JSON.stringify({
    status: document.querySelector('#status')?.textContent,
    rect: (() => { const r = document.querySelector('#board-canvas').getBoundingClientRect(); return { left: r.left, top: r.top, w: r.width, h: r.height, cw: document.querySelector('#board-canvas').width, ch: document.querySelector('#board-canvas').height }; })(),
    history: document.querySelector('#history-list')?.innerText,
  })`);
  console.log("[6] board info:", boardInfo);

  const shot = async (name) => {
    const r = await cdp.send("Page.captureScreenshot", { format: "png" });
    const p = SHOT(name);
    writeFileSync(p, Buffer.from(r.data, "base64"));
    return p;
  };

  // 采样：边境线、上下半区底色（canvas 内部像素坐标）
  // cellSize=30, padding=26。边境线 row=9 横带 y 266~296；采样 (311,281) 避开网格线
  // 上半区 row4 单元格中心 (161,161)；下半区 row12 单元格中心 (431,401)
  const sample = () => ev(`(() => {
    const c = document.querySelector('#board-canvas');
    const ctx = c.getContext('2d');
    const px = (x, y) => Array.from(ctx.getImageData(x, y, 1, 1).data);
    return JSON.stringify({ border: px(311, 281), topZone: px(161, 161), botZone: px(431, 401) });
  })()`);

  // ===== 呼吸灯验证：2s 周期，0.4s 间隔采样 6 次 =====
  console.log("[7] border pulse sampling...");
  const pulseSamples = [];
  for (let i = 0; i < 6; i++) {
    const s = JSON.parse(await sample());
    pulseSamples.push(s.border);
    if (i === 0) await shot("shot_01_board_initial.png");
    if (i === 3) await shot("shot_02_border_phase2.png");
    await sleep(400);
  }
  console.log("pulseSamples(border px rgb):", JSON.stringify(pulseSamples));
  // 呼吸灯明暗差异（B 通道变化）
  const bs = pulseSamples.map((p) => p[2]);
  const bMin = Math.min(...bs), bMax = Math.max(...bs);
  console.log(`border B channel min=${bMin} max=${bMax} delta=${bMax - bMin}`);

  // ===== 领土底色验证 =====
  const zone = JSON.parse(await sample());
  console.log("zones:", JSON.stringify(zone));
  const topB = zone.topZone[2], botB = zone.botZone[2];
  const topR = zone.topZone[0], botR = zone.botZone[0];
  console.log(`topZone rgb=${zone.topZone} botZone rgb=${zone.botZone} -> topB>botB:${topB > botB} botR>topR:${botR > topR}`);
  await shot("shot_03_zones.png");

  // ===== 落子（黑方布局阶段，row=4, col=9，第5行第10列）=====
  // canvas 内部坐标 (26+9*30, 26+4*30) = (296, 146)
  const info = JSON.parse(boardInfo);
  const rect = info.rect;
  const scaleX = rect.cw / rect.w, scaleY = rect.ch / rect.h;
  const tx = rect.left + 296 * scaleX;
  const ty = rect.top + 146 * scaleY;
  console.log(`[8] click at client (${tx.toFixed(1)}, ${ty.toFixed(1)}), canvas rect:`, JSON.stringify(rect));

  await cdp.send("Input.dispatchMouseEvent", { type: "mousePressed", x: tx, y: ty, button: "left", clickCount: 1 });
  await cdp.send("Input.dispatchMouseEvent", { type: "mouseReleased", x: tx, y: ty, button: "left", clickCount: 1 });
  await sleep(60);

  // 落子结果检查
  const moveCheck = await ev(`JSON.stringify({
    status: document.querySelector('#status')?.textContent,
    history: document.querySelector('#history-list')?.innerText,
  })`);
  console.log("[9] after move:", moveCheck);

  // 落子点绿环扫描（中心 296,146，半径 48px 区域）
  const scanGreen = () => ev(`(() => {
    const c = document.querySelector('#board-canvas');
    const ctx = c.getContext('2d');
    const cx = 296, cy = 146, R = 48;
    const data = ctx.getImageData(cx - R, cy - R, R * 2, R * 2).data;
    let greenPx = 0, yellowPx = 0, maxG = 0;
    for (let i = 0; i < data.length; i += 4) {
      const r = data[i], g = data[i+1], b = data[i+2];
      if (g > 140 && g > r + 30 && g > b + 20) { greenPx++; if (g > maxG) maxG = g; }
      if (r > 200 && g > 190 && b < 160) yellowPx++;
    }
    return JSON.stringify({ greenPx, yellowPx, maxG });
  })()`);

  // 连拍：立即 / 0.3s / 0.6s
  console.log("[10] burst shots + green scan...");
  const g0 = JSON.parse(await scanGreen());
  await shot("shot_04_deploy_t0.png");
  console.log("t0 green scan:", JSON.stringify(g0));
  await sleep(300);
  const g1 = JSON.parse(await scanGreen());
  await shot("shot_05_deploy_t03.png");
  console.log("t0.3 green scan:", JSON.stringify(g1));
  await sleep(300);
  const g2 = JSON.parse(await scanGreen());
  await shot("shot_06_deploy_t06.png");
  console.log("t0.6 green scan:", JSON.stringify(g2));

  // 等待 1 秒后确认消散
  await sleep(1000);
  const g3 = JSON.parse(await scanGreen());
  await shot("shot_07_after_1s.png");
  console.log("t~1.9 green scan:", JSON.stringify(g3));

  // ===== 控制台消息 =====
  console.log("[11] console errors:", JSON.stringify(cdp.consoleErrors, null, 2));
  console.log("[12] page exceptions:", JSON.stringify(cdp.pageErrors, null, 2));

  // 落子后棋盘状态（确认棋子已落）
  const finalState = await ev(`JSON.stringify({
    status: document.querySelector('#status')?.textContent,
    history: document.querySelector('#history-list')?.innerText,
    stone: Array.from(document.querySelector('#board-canvas').getContext('2d').getImageData(296, 146, 1, 1).data),
  })`);
  console.log("[13] final state:", finalState);

  cdp.close();
  console.log("DONE");
} catch (e) {
  console.error("FATAL:", e.message);
  process.exitCode = 1;
} finally {
  setTimeout(() => { try { chrome.kill(); } catch {} }, 500);
}
