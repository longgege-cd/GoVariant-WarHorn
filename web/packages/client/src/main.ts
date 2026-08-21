// 应用入口：屏幕切换
// M1: 本地对战（黑白交替，同一台机器）
// M2/M3: 在线对战（连接服务器）

import { GameScreen } from "./screens/GameScreen.js";
import { LifeDeathGameScreen } from "./screens/LifeDeathGameScreen.js";
import { OnlineGameScreen } from "./screens/OnlineGameScreen.js";
import type { SocketClient } from "./net/SocketClient.js";
import type { GameStartPayload, MatchFoundPayload } from "@warhorn/shared";
import { Color, AI_DIFFICULTY_NAMES, AIDifficulty, getPuzzleList } from "@warhorn/engine";
import { t, tpl, getLang, setLang } from "./i18n.js";

type Mode = "local" | "ai" | "online" | "puzzle";

class App {
  private root: HTMLElement;
  private currentScreen: { el: HTMLElement; destroy?: () => void } | null = null;

  constructor() {
    this.root = document.getElementById("app")!;
  }

  start(): void {
    this._showNameScreen();
  }

  private _showNameScreen(): void {
    this._clearScreen();
    const screen = document.createElement("div");
    screen.className = "screen screen-centered name-screen";
    screen.innerHTML = `
      <div class="lang-switch">
        <span class="label">${t("lang")}</span>
        <button class="btn lang-btn ${getLang() === "zh" ? "active" : ""}" data-lang="zh">中文</button>
        <button class="btn lang-btn ${getLang() === "en" ? "active" : ""}" data-lang="en">English</button>
      </div>
      <div class="logo">${t("logo")}</div>
      <div class="subtitle">${t("subtitle")}</div>
      <div class="form">
        <div class="mode-tabs">
          <button class="btn active" data-mode="local">${t("mode.local")}</button>
          <button class="btn" data-mode="ai">${t("mode.ai")}</button>
          <button class="btn" data-mode="online">${t("mode.online")}</button>
          <button class="btn" data-mode="puzzle">${t("mode.puzzle")}</button>
        </div>
        <div class="ai-options hidden">
          <div class="ai-options-label">${t("ai.difficulty")}</div>
          <div class="mode-tabs" id="ai-diff">
            <button class="btn active" data-diff="0">${t("ai.easy")}</button>
            <button class="btn" data-diff="1">${t("ai.normal")}</button>
            <button class="btn" data-diff="2">${t("ai.hard")}</button>
            <button class="btn" data-diff="3">${t("ai.master")}</button>
          </div>
        </div>
        <div class="fog-options">
          <label class="checkbox">
            <input type="checkbox" id="fog-toggle" />
            <span>${t("fog.toggle")}</span>
          </label>
          <span class="fog-hint">${t("fog.hint")}</span>
        </div>
        <input class="text-input" id="name-input" placeholder="${t("name.placeholder")}" maxlength="12" />
        <input class="text-input hidden" id="name-input-2" placeholder="${t("name.local2")}" maxlength="12" />
        <button class="btn btn-primary btn-large" id="start-btn">${t("start")}</button>
      </div>
      <details class="rules-box">
        <summary>${t("rules.btn")}</summary>
        <div class="rules-body">
          <div class="rules-title">${t("rules.title")}</div>
          <ol>
            <li>${t("rules.1")}</li>
            <li>${t("rules.2")}</li>
            <li>${t("rules.3")}</li>
            <li>${t("rules.4")}</li>
            <li>${t("rules.5")}</li>
            <li>${t("rules.6")}</li>
            <li>${t("rules.7")}</li>
            <li>${t("rules.8")}</li>
          </ol>
        </div>
      </details>
      <div class="feedback">${t("feedback")}：<a href="mailto:shamdom888@outlook.com">shamdom888@outlook.com</a></div>
    `;
    this.root.appendChild(screen);
    this.currentScreen = { el: screen };

    // 语言切换：重渲染主菜单
    screen.querySelectorAll(".lang-btn").forEach((btn) => {
      btn.addEventListener("click", () => {
        setLang((btn as HTMLElement).dataset.lang as "zh" | "en");
        this._showNameScreen();
      });
    });

    let mode: Mode = "local";
    let difficulty: AIDifficulty = 1; // 默认普通
    let fog = false; // 战争迷雾（可选规则）开关
    const nameInput = screen.querySelector("#name-input") as HTMLInputElement;
    const nameInput2 = screen.querySelector("#name-input-2") as HTMLInputElement;
    const aiOptions = screen.querySelector(".ai-options") as HTMLElement;
    const fogOptions = screen.querySelector(".fog-options") as HTMLElement;
    const fogToggle = screen.querySelector("#fog-toggle") as HTMLInputElement;
    const startBtn = screen.querySelector("#start-btn") as HTMLButtonElement;

    // 战争迷雾开关
    fogToggle.addEventListener("change", () => {
      fog = fogToggle.checked;
    });

    // 模式切换
    screen.querySelectorAll(".mode-tabs .btn[data-mode]").forEach((btn) => {
      btn.addEventListener("click", () => {
        screen.querySelectorAll(".mode-tabs .btn[data-mode]").forEach((b) => b.classList.remove("active"));
        btn.classList.add("active");
        mode = (btn as HTMLElement).dataset.mode as Mode;
        nameInput.placeholder =
          mode === "local" ? t("name.black") : mode === "ai" ? t("name.ai") : t("name.placeholder");
        nameInput2.classList.toggle("hidden", mode !== "local");
        nameInput2.placeholder = mode === "local" ? t("name.white") : "";
        aiOptions.classList.toggle("hidden", mode !== "ai");
        // 在线/死活题模式暂不支持迷雾，隐藏开关
        fogOptions.classList.toggle("hidden", mode === "online" || mode === "puzzle");
      });
    });

    // AI 难度选择
    screen.querySelectorAll("#ai-diff .btn").forEach((btn) => {
      btn.addEventListener("click", () => {
        screen.querySelectorAll("#ai-diff .btn").forEach((b) => b.classList.remove("active"));
        btn.classList.add("active");
        difficulty = Number((btn as HTMLElement).dataset.diff) as AIDifficulty;
      });
    });

    // 开始
    const start = () => {
      const name = nameInput.value.trim() || (mode === "local" ? t("name.default.black") : mode === "ai" ? t("name.default.player") : t("name.default.player"));
      if (mode === "local") {
        const name2 = nameInput2.value.trim() || t("name.default.white");
        this._showLocalGame(name, name2, fog);
      } else if (mode === "ai") {
        this._showAIGame(name, difficulty, fog);
      } else if (mode === "puzzle") {
        this._showPuzzleGame(name);
      } else {
        this._showOnlineLobby(name);
      }
    };
    startBtn.addEventListener("click", start);
    nameInput.addEventListener("keydown", (e) => {
      if (e.key === "Enter") start();
    });
    nameInput.focus();
  }

  private _showLocalGame(blackName: string, whiteName: string, fog: boolean = false): void {
    this._clearScreen();
    const game = new GameScreen(blackName, whiteName, null, AIDifficulty.NORMAL, fog);
    this.root.appendChild(game.el);
    this.currentScreen = { el: game.el, destroy: () => game.destroy() };

    // 退出按钮（返回主菜单）：追加到棋盘下方的控制栏
    const backBtn = document.createElement("button");
    backBtn.className = "btn";
    backBtn.textContent = t("back");
    backBtn.addEventListener("click", () => {
      if (confirm(t("backMenu"))) {
        this._showNameScreen();
      }
    });
    game.el.querySelector(".game-controls")!.appendChild(backBtn);
  }

  private _showAIGame(playerName: string, difficulty: AIDifficulty, fog: boolean = false): void {
    this._clearScreen();
    // 玩家执黑，AI 执白
    const aiName = tpl("aiName", AI_DIFFICULTY_NAMES[difficulty]);
    const game = new GameScreen(playerName, aiName, Color.WHITE, difficulty, fog);
    this.root.appendChild(game.el);
    this.currentScreen = { el: game.el, destroy: () => game.destroy() };

    const controls = game.el.querySelector(".game-controls")!;

    // 匹配状态提示（边下棋边匹配）
    const matchStatus = document.createElement("span");
    matchStatus.className = "match-status-inline hidden";
    controls.appendChild(matchStatus);

    // 匹配对手按钮：进入在线匹配队列，同时可继续与 AI 对弈
    let client: SocketClient | null = null;
    let matching = false;
    const resetMatchUI = () => {
      matching = false;
      client?.disconnect();
      client = null;
      this._resetMatchUI(matchBtn, matchStatus);
    };
    const matchBtn = document.createElement("button");
    matchBtn.className = "btn";
    matchBtn.textContent = t("matchOpponent");
    matchBtn.addEventListener("click", async () => {
      if (matching) {
        // 取消匹配
        resetMatchUI();
        return;
      }
      if (client) client.disconnect(); // 清理上次遗留连接，避免重复入队
      matching = true;
      matchStatus.classList.remove("hidden");
      matchStatus.textContent = t("matchingWait");
      matchBtn.textContent = t("matchingCancel");
      try {
        const { SocketClient } = await import("./net/SocketClient.js");
        client = new SocketClient();
        client.onMatchFound = (payload) => {
          this._showMatchConfirm(client!, payload, playerName);
        };
        client.onMatchCancelled = () => resetMatchUI();
        client.onGameStart = (payload) => {
          // 匹配成功并确认：切换至在线对局（放弃当前 AI 对局）
          matching = false; // 已进入在线对局，后续断线不再触发匹配重置
          this._showOnlineGame(client!, payload);
        };
        client.onError = (payload) => {
          this._showToast(payload.message);
          if (matching) resetMatchUI();
        };
        client.onDisconnect = () => {
          if (matching) {
            this._showToast(t("connLost"));
            resetMatchUI();
          }
        };
        await client.connect();
        client.joinLobby(playerName);
        client.requestMatch();
      } catch (err) {
        this._showToast(t("connFailed"));
        console.error(err);
        resetMatchUI();
      }
    });
    controls.appendChild(matchBtn);

    // 退出按钮（返回主菜单）：若在匹配中则断开连接
    const backBtn = document.createElement("button");
    backBtn.className = "btn";
    backBtn.textContent = t("back");
    backBtn.addEventListener("click", () => {
      if (confirm(t("backMenu"))) {
        client?.disconnect();
        this._showNameScreen();
      }
    });
    controls.appendChild(backBtn);
  }

  private _resetMatchUI(btn: HTMLButtonElement, status: HTMLElement): void {
    btn.textContent = t("matchOpponent");
    status.classList.add("hidden");
  }

  private _showPuzzleGame(playerName: string): void {
    this._clearScreen();
    const puzzles = getPuzzleList();
    let client: SocketClient | null = null;

    const game = new LifeDeathGameScreen(puzzles, {
      playerName,
      onBack: () => {
        client?.disconnect();
        this._showNameScreen();
      },
      attachMatch: (pName) => {
        let cancelled = false;
        const doConnect = async () => {
          try {
            const { SocketClient: SC } = await import("./net/SocketClient.js");
            client = new SC();
            client.onMatchFound = (payload) => {
              this._showMatchConfirm(client!, payload, pName);
            };
            client.onMatchCancelled = () => {
              if (!cancelled) {
                // 界面 UI 复位由闯关界面自行重置（点击取消），连接对象保留
              }
            };
            client.onGameStart = (payload) => {
              this._showOnlineGame(client!, payload);
            };
            client.onError = (payload) => {
              this._showToast(payload.message);
            };
            client.onDisconnect = () => {
              if (!cancelled) this._showToast(t("connLost"));
            };
            await client.connect();
            client.joinLobby(pName);
            client.requestMatch();
          } catch (err) {
            this._showToast(t("connFailed"));
            console.error(err);
          }
        };
        void doConnect();
        return { disconnect: () => { cancelled = true; client?.disconnect(); client = null; } };
      },
    });
    this.root.appendChild(game.el);
    this.currentScreen = { el: game.el, destroy: () => game.destroy() };
  }

  private _showOnlineLobby(name: string): void {
    this._clearScreen();
    const screen = document.createElement("div");
    screen.className = "screen screen-centered lobby-screen";
    screen.innerHTML = `
      <div class="lobby-header" style="width:100%; max-width:600px;">
        <span class="topbar-title">${t("lobbyTitle")}</span>
        <button class="btn" id="back-btn">${t("back")}</button>
      </div>
      <div class="lobby-content">
        <div class="lobby-stats">
          <div class="lobby-stat">
            <span class="label">${t("onlineCount")}</span>
            <span class="value" id="online-count">-</span>
          </div>
          <div class="lobby-stat">
            <span class="label">${t("matchingCount")}</span>
            <span class="value" id="matching-count">-</span>
          </div>
        </div>
        <div class="lobby-settings">
          <div class="lobby-settings-title">${t("curSettings")}</div>
          <div class="lobby-settings-grid">
            <div class="lobby-settings-item">
              <span class="label">${t("komi")}</span>
              <span class="value" id="cfg-komi">-</span>
            </div>
            <div class="lobby-settings-item">
              <span class="label">${t("piecesSide")}</span>
              <span class="value" id="cfg-pieces">-</span>
            </div>
            <div class="lobby-settings-item">
              <span class="label">${t("timing")}</span>
              <span class="value" id="cfg-timer">-</span>
            </div>
            <div class="lobby-settings-item">
              <span class="label">${t("deployTime")}</span>
              <span class="value" id="cfg-deploy">-</span>
            </div>
          </div>
        </div>
        <div id="match-area">
          <button class="btn btn-primary btn-large" id="match-btn">${t("startMatch")}</button>
        </div>
        <div id="match-status" class="match-status hidden">
          <span class="spinner"></span>
          <span id="match-status-text">${t("matchingDots")}</span>
        </div>
        <div class="subtitle" style="color:var(--text-dim); font-size:13px; max-width:400px; text-align:center;">
          ${t("practiceHint")}
        </div>
      </div>
    `;
    this.root.appendChild(screen);
    this.currentScreen = { el: screen };

    screen.querySelector("#back-btn")!.addEventListener("click", () => this._showNameScreen());

    // M2/M3 在线模式：连接服务器
    this._initOnline(screen, name);
  }

  private async _initOnline(screen: HTMLElement, name: string): Promise<void> {
    const matchBtn = screen.querySelector("#match-btn") as HTMLButtonElement;
    const matchArea = screen.querySelector("#match-area") as HTMLElement;
    const matchStatus = screen.querySelector("#match-status") as HTMLElement;
    const matchStatusText = screen.querySelector("#match-status-text") as HTMLElement;
    const onlineCount = screen.querySelector("#online-count") as HTMLElement;
    const matchingCount = screen.querySelector("#matching-count") as HTMLElement;
    const cfgKomi = screen.querySelector("#cfg-komi") as HTMLElement;
    const cfgPieces = screen.querySelector("#cfg-pieces") as HTMLElement;
    const cfgTimer = screen.querySelector("#cfg-timer") as HTMLElement;
    const cfgDeploy = screen.querySelector("#cfg-deploy") as HTMLElement;

    try {
      const { SocketClient } = await import("./net/SocketClient.js");
      const client = new SocketClient();

      client.onLobbyUpdate = (payload) => {
        onlineCount.textContent = String(payload.onlineCount);
        matchingCount.textContent = String(payload.matchingCount);
      };

      client.onMatchFound = (payload) => {
        matchStatus.classList.add("hidden");
        matchArea.classList.remove("hidden");
        this._showMatchConfirm(client, payload, name);
      };

      client.onMatchCancelled = () => {
        matchStatus.classList.add("hidden");
        matchArea.classList.remove("hidden");
      };

      client.onGameStart = (payload) => {
        this._showOnlineGame(client, payload);
      };

      client.onError = (payload) => {
        this._showToast(payload.message);
      };

      await client.connect();
      client.joinLobby(name);

      // 拉取服务器当前游戏设置（大厅展示）
      client
        .fetchConfig()
        .then((cfg) => {
          cfgKomi.textContent = tpl("komiUnit", cfg.komi);
          cfgPieces.textContent = tpl("stonesUnit", cfg.pieceLimit);
          cfgTimer.textContent = tpl("byoRule", this._fmtDuration(cfg.timerBaseSec), cfg.byoCount, cfg.byoPeriodSec);
          cfgDeploy.textContent = this._fmtDuration(cfg.deployTimerSec);
        })
        .catch((err) => {
          console.warn("获取游戏设置失败", err);
        });

      matchBtn.addEventListener("click", () => {
        matchArea.classList.add("hidden");
        matchStatus.classList.remove("hidden");
        matchStatusText.textContent = t("matchingDots");
        client.requestMatch();
      });
    } catch (err) {
      this._showToast(t("connFailed"));
      console.error(err);
    }
  }

  private _showMatchConfirm(client: SocketClient, payload: MatchFoundPayload, _ownName: string): void {
    const modal = document.createElement("div");
    modal.className = "modal-overlay";
    modal.innerHTML = `
      <div class="modal">
        <h2>${t("matchFound")}</h2>
        <div class="modal-body">
          <p>${tpl("opponentLabel", this._escape(payload.opponentName))}</p>
          <p>${tpl("yourColor", t(payload.ownColor === 1 ? "black" : "white"))}</p>
          <div class="countdown" id="countdown">${payload.confirmTimeoutSec}</div>
          <p style="font-size:12px; color:var(--text-dim);">${t("confirmIn")}</p>
        </div>
        <div class="modal-actions">
          <button class="btn btn-primary" id="confirm-btn">${t("startGame")}</button>
          <button class="btn btn-danger" id="decline-btn">${t("decline")}</button>
        </div>
      </div>
    `;
    document.body.appendChild(modal);

    let count = payload.confirmTimeoutSec;
    const countdownEl = modal.querySelector("#countdown")!;
    const timer = setInterval(() => {
      count--;
      countdownEl.textContent = String(count);
      if (count <= 0) {
        clearInterval(timer);
        modal.remove();
      }
    }, 1000);

    modal.querySelector("#confirm-btn")!.addEventListener("click", () => {
      clearInterval(timer);
      client.confirmMatch();
      modal.remove();
    });
    modal.querySelector("#decline-btn")!.addEventListener("click", () => {
      clearInterval(timer);
      client.declineMatch();
      modal.remove();
    });
  }

  private _showOnlineGame(client: SocketClient, payload: GameStartPayload): void {
    this._clearScreen();
    const game = new OnlineGameScreen(client, payload);
    this.root.appendChild(game.el);
    this.currentScreen = { el: game.el, destroy: () => game.destroy() };
  }

  private _clearScreen(): void {
    if (this.currentScreen) {
      this.currentScreen.destroy?.();
      this.currentScreen.el.remove();
      this.currentScreen = null;
    }
    // 清理可能残留的弹窗（对局结束 / 匹配确认），避免盖住新界面
    document.querySelectorAll(".modal-overlay").forEach((m) => m.remove());
  }

  private _showToast(msg: string): void {
    const toast = document.createElement("div");
    toast.className = "toast";
    toast.textContent = msg;
    document.body.appendChild(toast);
    setTimeout(() => toast.remove(), 3000);
  }

  private _fmtDuration(sec: number): string {
    if (sec >= 60 && sec % 60 === 0) return tpl("fmt.min", sec / 60);
    if (sec >= 60) return tpl("fmt.minSec", Math.floor(sec / 60), sec % 60);
    return tpl("fmt.sec", sec);
  }

  private _escape(s: string): string {
    const div = document.createElement("div");
    div.textContent = s;
    return div.innerHTML;
  }
}

const app = new App();
app.start();
