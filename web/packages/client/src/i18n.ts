// 轻量 i18n：主菜单 + 游戏对局界面中英切换
export type Lang = "zh" | "en";

const STORAGE_KEY = "warhorn-lang";

const dict: Record<string, { zh: string; en: string }> = {
  // 主菜单
  "logo": { zh: "战争号角", en: "War Horn" },
  "subtitle": { zh: "围棋变体 · 在线对战平台", en: "Go Variant · Online Battle Platform" },
  "lang": { zh: "语言", en: "Language" },
  "mode.local": { zh: "本地对战", en: "Local Game" },
  "mode.ai": { zh: "人机对战", en: "vs AI" },
  "mode.online": { zh: "在线对战", en: "Online" },
  "mode.puzzle": { zh: "死活题闯关", en: "Life-Death" },
  "ai.difficulty": { zh: "AI 难度", en: "AI Difficulty" },
  "ai.easy": { zh: "简单", en: "Easy" },
  "ai.normal": { zh: "普通", en: "Normal" },
  "ai.hard": { zh: "困难", en: "Hard" },
  "ai.master": { zh: "大师", en: "Master" },
  "name.placeholder": { zh: "输入你的名字", en: "Enter your name" },
  "name.black": { zh: "黑方名字", en: "Black player name" },
  "name.white": { zh: "白方名字", en: "White player name" },
  "name.ai": { zh: "你的名字（执黑）", en: "Your name (Black)" },
  "name.local2": { zh: "对手名字（本地对战）", en: "Opponent name (local)" },
  "name.default.black": { zh: "黑方", en: "Black" },
  "name.default.white": { zh: "白方", en: "White" },
  "name.default.player": { zh: "玩家", en: "Player" },
  "start": { zh: "开始", en: "Start" },
  // 规则说明
  "rules.btn": { zh: "游戏规则", en: "Game Rules" },
  "rules.title": { zh: "游戏规则", en: "Rules" },
  "deployBanner": { zh: "布局阶段", en: "Deployment" },
  "rules.1": { zh: "棋盘 19×19，中央第 10 行为边境线。", en: "19×19 board; row 10 is the border line." },
  "rules.2": { zh: "布局阶段：前4手各自在己方领土落 2 子。", en: "Deployment: first 4 moves, each side places 2 stones in its own half." },
  "rules.3": { zh: "占领分：围住对方半场/边境空点 +2/点；有效围空≥4点每4点+2效率奖励；无活子分。", en: "Occupation: +2 per enclosed empty point in enemy half/border; +2 efficiency per 4 valid points; no live points." },
  "rules.4": { zh: "防御分：己方领土/边境提子 +3/子；己方领土/边境围困对方棋子 +2/子。", en: "Defense: +3 per stone captured in your own half/border; +2 per enemy stone sieged in your own half/border." },
  "rules.5": { zh: "围困：将对方棋子有效包围、无两眼且圈内合法落子空点<4 即判围困。在己方领土/边境围困对方棋子 +2/子。", en: "Siege: a group fully enclosed, with no two eyes and <4 legal empty points inside is sieged. +2 per enemy stone sieged in your own half/border." },
  "rules.6": { zh: "战损分：己方被提或被围困的棋子扣分。", en: "Casualty: your own captured/sieged stones lose points." },
  "rules.7": { zh: "每方每局可虚手 2 次，不可连续虚手；双方连续虚手自动终局。", en: "2 passes per side, no consecutive passes; two consecutive passes end the game." },
  "rules.8": { zh: "总分 = 占领 + 防御 − 战损；白方 +0.5 贴目（仅终局胜负判定）。", en: "Total = occupation + defense − casualty; White gets +0.5 komi for final result." },
  // 战争迷雾（可选规则）
  "fog.toggle": { zh: "战争迷雾", en: "Fog of War" },
  "fog.hint": { zh: "（布局阶段起视野受限，第30手后全盘可见）", en: "(Vision limited from deployment; fully revealed after move 30)" },
  "fog.encounterBounce": { zh: "遭遇隐藏敌人！棋子弹至相邻位置", en: "Hidden enemy found! Stone bounced to a nearby cell" },
  "fog.encounterDestroy": { zh: "遭遇隐藏敌人！棋子被消灭", en: "Hidden enemy found! Stone destroyed" },
  "fog.dawn": { zh: "黎明降临！战争迷雾已消散，全盘可见", en: "Dawn breaks! The fog lifts and the whole board is revealed" },
  // 通用对局
  "black": { zh: "黑方", en: "Black" },
  "white": { zh: "白方", en: "White" },
  "mover.black": { zh: "黑", en: "Black" },
  "mover.white": { zh: "白", en: "White" },
  "back": { zh: "返回", en: "Back" },
  "undo": { zh: "悔棋", en: "Undo" },
  "pass": { zh: "虚手", en: "Pass" },
  "resign": { zh: "认输", en: "Resign" },
  "newGame": { zh: "新局", en: "New Game" },
  "total": { zh: "总分", en: "Total" },
  "occupation": { zh: "占领", en: "Occupation" },
  "defense": { zh: "防御", en: "Defense" },
  "casualty": { zh: "战损", en: "Casualty" },
  "pieces": { zh: "兵力 {0}/{1}", en: "Pieces {0}/{1}" },
  "scoreLog": { zh: "得分日志", en: "Score Log" },
  "noLog": { zh: "暂无记录", en: "No records" },
  "log.move": { zh: "落子", en: "Move" },
  "log.pass": { zh: "虚手", en: "Pass" },
  "log.deploy": { zh: "部署", en: "Deploy" },
  "log.bounce": { zh: "突破", en: "Breakthrough" },
  "log.capture": { zh: "提{0}", en: "Cap {0}" },
  "influence.on": { zh: "势力热力图已开启（按空格关闭）", en: "Influence map on (Space to close)" },
  "influence.off": { zh: "势力热力图已关闭", en: "Influence map off" },
  "theme.switched": { zh: "已切换主题：{0}", en: "Theme: {0}" },
  "theme.classic": { zh: "经典木质", en: "Classic Wood" },
  "theme.pixel": { zh: "动画像素风", en: "Pixel Anime" },
  "theme.obsidian": { zh: "黑曜石", en: "Obsidian" },
  "theme.porcelain": { zh: "青花瓷", en: "Blue Porcelain" },
  "aiThinking": { zh: "AI 思考中...", en: "AI is thinking..." },
  "battleStart": { zh: "正式开战！", en: "Battle begins!" },
  "passed": { zh: "{0}方虚手", en: "{0} passed" },
  "timeoutLoss": { zh: "超时判负", en: "Loss by timeout" },
  "byo": { zh: "读秒", en: "Byo " },
  "autoDeploy": { zh: "{0}方布局超时，自动布子", en: "{0} deploy timeout, auto-placed" },
  "resignConfirm": { zh: "{0}方确认认输？", en: "Confirm {0} resignation?" },
  "resignConfirmOnline": { zh: "确认认输？", en: "Confirm resignation?" },
  "newConfirm": { zh: "确认开始新对局？当前对局将放弃。", en: "Start a new game? Current game will be abandoned." },
  "undoBlocked": { zh: "AI 思考中，暂不能悔棋", en: "Cannot undo while AI is thinking" },
  "moveFail": { zh: "落子失败", en: "Move failed" },
  "passFail": { zh: "虚手失败", en: "Pass failed" },
  "undoFail": { zh: "悔棋失败", en: "Undo failed" },
  "gameEnded": { zh: "对局已结束", en: "Game over" },
  "deployLeft": { zh: "布局阶段 · {0}方落子（剩 {1} 手）", en: "Deployment · {0} to move ({1} left)" },
  "aiDeployLeft": { zh: "AI 布局中…（剩 {0} 手）", en: "AI deploying… ({0} left)" },
  "deployTurn": { zh: "布局阶段 · {0}方{1} · {2}s", en: "Deployment · {0}{1} · {2}s" },
  "aiDeployTurn": { zh: "AI 布局中… · {0}s", en: "AI deploying… · {0}s" },
  "turn": { zh: "{0}方落子 · 兵力 {1} · 虚手剩余 {2}", en: "{0} to move · pieces {1} · {2} passes left" },
  "turnExhausted": { zh: "{0}方棋子用尽 · 虚手不限", en: "{0} out of pieces · pass unlimited" },
  "turnOnline": { zh: "{0}方落子{1}", en: "{0} to move{1}" },
  "youMark": { zh: "（你）", en: " (you)" },
  "oppMark": { zh: "（对手）", en: " (opponent)" },
  "waitOpponent": { zh: "等待对手落子", en: "Waiting for opponent" },
  "waitOpponentMove": { zh: "等待对手行棋", en: "Waiting for opponent" },
  "title.ai": { zh: "战争号角 · 人机对战", en: "War Horn · vs AI" },
  "title.local": { zh: "战争号角 · 本地对战", en: "War Horn · Local Game" },
  "title.online": { zh: "战争号角 · 在线对战（你执{0}）· 贴目{1} · 兵力{2}", en: "War Horn · Online (You: {0}) · Komi {1} · Pieces {2}" },
  "win": { zh: "{0}胜", en: "{0} wins" },
  "youWin": { zh: "（你赢了）", en: " (you win)" },
  "finalScore": { zh: "最终分", en: "Final Score" },
  "result.title": { zh: "对局结束", en: "Game Over" },
  "result.item": { zh: "项目", en: "Item" },
  "result.territory": { zh: "围空分", en: "Territory" },
  "result.efficiency": { zh: "效率奖励", en: "Efficiency" },
  "result.annihilate": { zh: "歼灭分", en: "Annihilate" },
  "result.siege": { zh: "围困分", en: "Sieged" },
  "result.casualty": { zh: "战损分", en: "Casualty" },
  "result.komi": { zh: "贴目", en: "Komi" },
  "result.new": { zh: "新对局", en: "New Game" },
  "close": { zh: "关闭", en: "Close" },
  "passEnd": { zh: "双方连续虚手，终局", en: "Two consecutive passes, game over" },
  "reason.resign": { zh: "{0}认输", en: "{0} resigned" },
  "reason.bothStuck": { zh: "双方均无法落子", en: "Neither side can move" },
  "reason.piecesExhausted": { zh: "兵力用尽，双方连续虚手", en: "Stones exhausted, double pass" },
  // 匹配 / 大厅
  "matchOpponent": { zh: "匹配对手", en: "Match Opponent" },
  "matchingCancel": { zh: "匹配中…（点按取消）", en: "Matching… (click to cancel)" },
  "matchingWait": { zh: "正在匹配对手，可继续下棋…", en: "Matching… keep playing meanwhile" },
  "connLost": { zh: "连接已断开", en: "Connection lost" },
  "connFailed": { zh: "无法连接服务器，请确认服务器已启动", en: "Cannot connect to server. Is it running?" },
  "lobbyTitle": { zh: "战争号角 · 大厅", en: "War Horn · Lobby" },
  "onlineCount": { zh: "在线人数", en: "Online" },
  "matchingCount": { zh: "匹配中", en: "Matching" },
  "curSettings": { zh: "当前游戏设置", en: "Current Settings" },
  "komi": { zh: "贴目", en: "Komi" },
  "piecesSide": { zh: "每方兵力", en: "Pieces per side" },
  "timing": { zh: "计时", en: "Timing" },
  "deployTime": { zh: "布局时间", en: "Deploy Time" },
  "startMatch": { zh: "开始匹配", en: "Start Matching" },
  "matchingDots": { zh: "正在匹配对手...", en: "Matching..." },
  "practiceHint": { zh: "等待匹配时可进入练习模式（本地自由落子）", en: "Play practice mode while waiting" },
  "matchFound": { zh: "匹配成功！", en: "Match found!" },
  "opponentLabel": { zh: "对手：{0}", en: "Opponent: {0}" },
  "yourColor": { zh: "你的颜色：{0}", en: "Your color: {0}" },
  "confirmIn": { zh: "请在倒计时内确认", en: "Confirm within the countdown" },
  "startGame": { zh: "开始对局", en: "Start Game" },
  "decline": { zh: "放弃", en: "Decline" },
  "backMenu": { zh: "返回主菜单？当前对局将放弃。", en: "Back to menu? Current game will be abandoned." },
  "backLobbyBtn": { zh: "返回大厅", en: "Back to Lobby" },
  "backLobby": { zh: "返回大厅？当前对局将按认输处理。", en: "Back to lobby? Current game counts as a loss." },
  "aiName": { zh: "AI · {0}", en: "AI · {0}" },
  // 死活题闯关
  "puzzle.title": { zh: "战争号角 · 死活题 {0}/{1}", en: "War Horn · Life-Death {0}/{1}" },
  "puzzle.progress": { zh: "关卡进度", en: "Progress" },
  "puzzle.type": { zh: "执子", en: "Color" },
  "puzzle.diff": { zh: "难度", en: "Difficulty" },
  "puzzle.goal": { zh: "这是真实死活题，你执{0}。按正解连续落子，答对才能进入下一题（答错可重试）。", en: "A real tsume-go problem. You are {0}. Play the correct sequence to advance (wrong moves are retried)." },
  "puzzle.turn": { zh: "按正解逐手落子（可连下多手）", en: "Play the correct sequence (multiple moves)" },
  "puzzle.solved": { zh: "✓ 过关！", en: "✓ Solved!" },
  "puzzle.wrong": { zh: "✗ 答错了，请重试", en: "✗ Wrong. Try again." },
  "puzzle.prev": { zh: "上一题", en: "Prev" },
  "puzzle.next": { zh: "下一题", en: "Next" },
  "puzzle.restart": { zh: "重来", en: "Retry" },
  "puzzle.hint": { zh: "提示", en: "Hint" },
  "puzzle.noHint": { zh: "当前无更多正解点（谜题已参观）", en: "No more correct points" },
  "puzzle.hintCount": { zh: "提示：{0} 个正确点已高亮", en: "Hint: {0} correct point(s) highlighted" },
  // 格式
  "fmt.min": { zh: "{0}分钟", en: "{0} min" },
  "fmt.minSec": { zh: "{0}分{1}秒", en: "{0}m {1}s" },
  "fmt.sec": { zh: "{0}秒", en: "{0}s" },
  "komiUnit": { zh: "{0} 目", en: "{0} pts" },
  "stonesUnit": { zh: "{0} 子", en: "{0} stones" },
  "perMove": { zh: "+ 每手{0}秒", en: "+{0}s/move" },
  "byoRule": { zh: "{0} + {1}次读秒×{2}秒", en: "{0} + {1} byo-yomi × {2}s" },
};

let lang: Lang = (localStorage.getItem(STORAGE_KEY) as Lang) || "en";
if (lang !== "zh" && lang !== "en") lang = "en";

export function t(key: string): string {
  return dict[key]?.[lang] ?? key;
}

// 占位符模板：tpl("pieces", 108, 112) → "兵力 108/112"
export function tpl(key: string, ...args: (string | number)[]): string {
  return t(key).replace(/\{(\d+)\}/g, (_, i: string) => String(args[Number(i)] ?? ""));
}

export function getLang(): Lang {
  return lang;
}

// 棋盘主题名 → 翻译（BoardCanvas 主题名为中文，翻译需映射）
const themeKeyMap: Record<string, string> = {
  "经典木质": "theme.classic",
  "动画像素风": "theme.pixel",
  "黑曜石": "theme.obsidian",
  "青花瓷": "theme.porcelain",
};

export function tThemeName(name: string): string {
  return t(themeKeyMap[name] ?? name);
}

export function setLang(l: Lang): void {
  lang = l;
  localStorage.setItem(STORAGE_KEY, l);
}
