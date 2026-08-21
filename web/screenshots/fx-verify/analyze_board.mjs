// 棋盘特效深度验证：坐标标注 / 边境线呼吸 / 底色 / 落子脉冲时间曲线
import { spawn } from "node:child_process";
import { mkdirSync, writeFileSync, existsSync, rmSync } from "node:fs";
import { join } from "node:path";

const CHROME = "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe";
const BASE = join(import.meta.dirname);
const PROFILE = join(BASE, "profile2");
const PORT = 9224;
const URL = "http://localhost:5173/";
const SHOT = (name) => join(BASE, name);

mkdirSync(BASE, { recursive: true });
if (existsSync(PROFILE)) rmSync(PROFILE, { recursive: true, force: true });

const chrome = spawn(CHROME, [
  "--headless=new", `--remote-debugging-port=${PORT}`, `--user-data-dir=${PROFILE}`,
  "--no-first-run", "--no-default-browser-check", "--disable-gpu", "--hide-scrollbars",
  "--mute-audio", "--disable-backgrounding-occluded-windows", "--disable-renderer-backgrounding",
  "--window-size=1400,1000", "about:blank",
], { stdio: "ignore", windowsHide: true });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

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

class CDP {
  constructor(ws) {
    this.ws = ws;
    this.id = 0;
    this.pending = new Map();
    this.consoleErrors = [];
    this.pageErrors = [];
    this.failedRequests = [];
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
      } else if (msg.method === "Network.loadingFailed") {
        const p = msg.params;
        this.failedRequests.push(`failed: type=${p.type} err=${p.errorText} canceled=${p.canceled ?? false}`);
      } else if (msg.method === "Network.responseReceived") {
        const p = msg.params;
        if (p.response.status >= 400) {
          this.failedRequests.push(`HTTP ${p.response.status}: ${p.response.url}`);
        }
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
  close() { try { this.ws.close(); } catch {} }
}

try {
  const targets = await waitCDP();
  const page = targets.find((t) => t.type === "page");
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
  const cdp = new CDP(ws);

  await cdp.send("Page.enable");
  await cdp.send("Runtime.enable");
  await cdp.send("Log.enable");
  await cdp.send("Network.enable");
  await cdp.send("Page.navigate", { url: URL });
  await sleep(2500);

  const ev = async (expr) => {
    const r = await cdp.send("Runtime.evaluate", { expression: expr, returnByValue: true });
    if (r.exceptionDetails) throw new Error("eval failed: " + JSON.stringify(r.exceptionDetails).slice(0, 300));
    return r.result.value;
  };

  // 进入本地对局
  await ev(`(() => {
    const ni = document.querySelector('#name-input');
    ni.value = '特效测试';
    ni.dispatchEvent(new Event('input', { bubbles: true }));
    document.querySelector('#start-btn').click();
    return true;
  })()`);
  await sleep(2500);

  const boardInfo = await ev(`JSON.stringify({
    status: document.querySelector('#status')?.textContent,
    rect: (() => { const r = document.querySelector('#board-canvas').getBoundingClientRect(); return { left: r.left, top: r.top, w: r.width, h: r.height, cw: document.querySelector('#board-canvas').width, ch: document.querySelector('#board-canvas').height }; })(),
  })`);
  console.log("board:", boardInfo);

  const shot = async (name) => {
    const r = await cdp.send("Page.captureScreenshot", { format: "png" });
    writeFileSync(SHOT(name), Buffer.from(r.data, "base64"));
  };

  // ========== A. 坐标标注逐列/逐行文本检测 ==========
  console.log("== A. coordinate labels ==");
  const coords = JSON.parse(await ev(`(() => {
    const c = document.querySelector('#board-canvas');
    const ctx = c.getContext('2d');
    const px = (x, y) => Array.from(ctx.getImageData(x, y, 1, 1).data);
    const dark = (r, g, b) => r < 120 && g < 100 && b < 80;
    const topCols = [], bottomCols = [], leftRows = [], rightRows = [];
    for (let i = 0; i < 19; i++) {
      const cx = 26 + i * 30;
      let ct = 0, cb = 0;
      for (let dx = -9; dx <= 9; dx++) for (let dy = 4; dy <= 22; dy++) {
        const p = px(cx + dx, dy);
        if (dark(p[0], p[1], p[2])) ct++;
        const q = px(cx + dx, 566 + dy);
        if (dark(q[0], q[1], q[2])) cb++;
      }
      topCols.push(ct); bottomCols.push(cb);
    }
    for (let i = 0; i < 19; i++) {
      const cy = 26 + i * 30;
      let cl = 0, cr = 0;
      for (let dy = -9; dy <= 9; dy++) for (let dx = 4; dx <= 22; dx++) {
        const p = px(dx, cy + dy);
        if (dark(p[0], p[1], p[2])) cl++;
        const q = px(566 + dx, cy + dy);
        if (dark(q[0], q[1], q[2])) cr++;
      }
      leftRows.push(cl); rightRows.push(cr);
    }
    return JSON.stringify({ topCols, bottomCols, leftRows, rightRows });
  })()`));
  const hasTop = coords.topCols.filter((n) => n > 5).length;
  const hasBot = coords.bottomCols.filter((n) => n > 5).length;
  const hasLeft = coords.leftRows.filter((n) => n > 5).length;
  const hasRight = coords.rightRows.filter((n) => n > 5).length;
  console.log("topCols dark-pixel counts:", JSON.stringify(coords.topCols));
  console.log("bottomCols:", JSON.stringify(coords.bottomCols));
  console.log("leftRows:", JSON.stringify(coords.leftRows));
  console.log("rightRows:", JSON.stringify(coords.rightRows));
  console.log(`label detection: top=${hasTop}/19 bottom=${hasBot}/19 left=${hasLeft}/19 right=${hasRight}/19`);
  await shot("shot_a_board.png");

  // ========== B. 边境线呼吸灯精细采样（0.25s 间隔 x 10 = 2.5s，覆盖完整周期）==========
  console.log("== B. border pulse ==");
  const pulse = [];
  for (let i = 0; i < 10; i++) {
    const s = JSON.parse(await ev(`(() => {
      const c = document.querySelector('#board-canvas');
      const ctx = c.getContext('2d');
      const p = Array.from(ctx.getImageData(311, 281, 1, 1).data);
      const p2 = Array.from(ctx.getImageData(26 + 4 * 30, 26 + 4 * 30, 1, 1).data); // 对照：普通区域
      return JSON.stringify({ b: p, ref: p2 });
    })()`));
    pulse.push({ t: (i * 0.25).toFixed(2), b: s.b, ref: s.ref });
    await sleep(250);
  }
  console.log("pulse:", JSON.stringify(pulse));
  const bCh = pulse.map((p) => p.b[2]);
  const rCh = pulse.map((p) => p.b[0]);
  console.log(`border B channel: ${bCh.join(",")}  min=${Math.min(...bCh)} max=${Math.max(...bCh)} delta=${Math.max(...bCh) - Math.min(...bCh)}`);
  console.log(`border R channel: ${rCh.join(",")}  (R 应随 alpha 反向变化: alpha 低 -> 木色主导 R 高)`);

  // ========== C. 领土底色 ==========
  console.log("== C. zones ==");
  const zones = JSON.parse(await ev(`(() => {
    const c = document.querySelector('#board-canvas');
    const ctx = c.getContext('2d');
    const px = (x, y) => Array.from(ctx.getImageData(x, y, 1, 1).data);
    // 上半区采样 3 点（row 1/4/7 单元格中心，远离星位线）
    const topPts = [px(26 + 4.5 * 30, 26 + 1 * 30 + 15), px(26 + 4.5 * 30, 26 + 4 * 30 + 15), px(26 + 4.5 * 30, 26 + 7 * 30 + 15)];
    // 下半区采样 3 点（row 11/14/17）
    const botPts = [px(26 + 4.5 * 30, 26 + 11 * 30 + 15), px(26 + 4.5 * 30, 26 + 14 * 30 + 15), px(26 + 4.5 * 30, 26 + 17 * 30 + 15)];
    return JSON.stringify({ topPts, botPts });
  })()`));
  console.log("zones:", JSON.stringify(zones));
  const avg = (arr, i) => Math.round(arr.reduce((s, p) => s + p[i], 0) / arr.length);
  const tB = avg(zones.topPts, 2), bB = avg(zones.botPts, 2);
  const tR = avg(zones.topPts, 0), bR = avg(zones.botPts, 0);
  console.log(`avg top rgb=(${avg(zones.topPts,0)},${avg(zones.topPts,1)},${tB})  avg bot rgb=(${bR},${avg(zones.botPts,1)},${bB})`);
  console.log(`top B>bot B: ${tB > bB} (${tB} vs ${bB}); bot R>top R: ${bR > tR} (${bR} vs ${tR})`);

  // ========== D. 落子 + 脉冲时间曲线 ==========
  console.log("== D. move pulse curve ==");
  const info = JSON.parse(boardInfo);
  const rect = info.rect;
  const tx = rect.left + 296 * (rect.cw / rect.w);
  const ty = rect.top + 146 * (rect.ch / rect.h);
  await cdp.send("Input.dispatchMouseEvent", { type: "mousePressed", x: tx, y: ty, button: "left", clickCount: 1 });
  await cdp.send("Input.dispatchMouseEvent", { type: "mouseReleased", x: tx, y: ty, button: "left", clickCount: 1 });

  const scan = () => ev(`(() => {
    const c = document.querySelector('#board-canvas');
    const ctx = c.getContext('2d');
    const cx = 296, cy = 146, R = 48;
    const data = ctx.getImageData(cx - R, cy - R, R * 2, R * 2).data;
    let greenPx = 0, greenScore = 0, yellowPx = 0;
    for (let i = 0; i < data.length; i += 4) {
      const r = data[i], g = data[i+1], b = data[i+2];
      if (g > 150 && g > r - 20 && g > b + 15) { greenPx++; greenScore += g - b; }
      if (r > 200 && g > 190 && b < 160) yellowPx++;
    }
    return JSON.stringify({ greenPx, greenScore, yellowPx });
  })()`);

  const curve = [];
  for (let i = 0; i < 9; i++) {
    const s = JSON.parse(await scan());
    curve.push({ t: i === 0 ? "t0(0ms)" : `t${(i * 100).toFixed(0)}ms`, ...s });
    if (i === 0) await shot("shot_d_t0.png");
    if (i === 3) await shot("shot_d_t300.png");
    await sleep(100);
  }
  // 1.2s 后再采样确认消散
  await sleep(1100);
  const sFinal = JSON.parse(await scan());
  curve.push({ t: "t+2.0s", ...sFinal });
  await shot("shot_d_after2s.png");
  console.log("pulse curve:", JSON.stringify(curve, null, 1));

  const moveCheck = await ev(`JSON.stringify({
    status: document.querySelector('#status')?.textContent,
    history: document.querySelector('#history-list')?.innerText,
  })`);
  console.log("move result:", moveCheck);

  // ========== 汇总 ==========
  console.log("console errors:", JSON.stringify(cdp.consoleErrors, null, 2));
  console.log("page exceptions:", JSON.stringify(cdp.pageErrors, null, 2));
  console.log("failed requests:", JSON.stringify(cdp.failedRequests, null, 2));

  cdp.close();
  console.log("DONE");
} catch (e) {
  console.error("FATAL:", e.message);
  process.exitCode = 1;
} finally {
  setTimeout(() => { try { chrome.kill(); } catch {} }, 500);
}
