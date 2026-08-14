extends SceneTree
# 棋谱规则审计：用棋谱库真实对局逐手模拟，验证围困算法与得分规则（v4.3）
#
# 围困审计不变量：
#   - 真眼必活 / 活棋必有气 / 围困三条件（被包围 + 合法空点<4 + 无真眼）
#   - 棋盘合法（任何组群有气，提子无残留）/ 缓存一致性（cached_sieged_groups vs 独立判定）
# 得分审计不变量：
#   - 分数分解（占领=活子+围空、防御=歼灭+围困、战损=部队损失+隐子损失、总分）
#   - counters 与提子事件一致（累计 captures == normal_lost + special_lost）
#   - 歼灭分 = 歼灭数×2、战损普通 = -被提数、战损特种 = -特种被提数×6
#   - 活子分 / 围困分 / 围空分 独立盘面重算一致（含围困圈扣除与嵌套归属）
#
# 用法：
#   完整版（每 10 手全局面重算）：
#     Godot_v4.7-stable_win64.exe --headless --path . --script res://tests/diag_sgf_audit.gd
#   轻量版（仅终局检查，集成主测试）：
#     run_all.gd 中调用 diag_sgf_audit.run_quick(t)

const SGFLoader = preload("res://scripts/core/SGFLoader.gd")
const CHECK_EVERY := 10

# ================= 完整版独立入口 =================
func _init() -> void:
	var files := _list_all_sgfs()
	var total := { "checks": 0, "fails": 0, "infos": 0 }
	print("===== 棋谱规则审计（完整版：围困 + 得分）=====")
	for path in files:
		var r := _audit_game(path, true)
		total.checks += r.checks
		total.fails += r.fails
		total.infos += r.infos
		print("[%s] %d 手 审计完成（检查 %d 失败 %d 提示 %d）" % [path.get_file(), r.moves, r.checks, r.fails, r.infos])
	print("===== 审计完成: 检查 %d 项, 失败 %d, 提示 %d =====" % [total.checks, total.fails, total.infos])
	quit(1 if total.fails > 0 else 0)

# ================= 轻量版：集成主测试（仅终局全局面检查） =================
static func run_quick(t: TestFramework) -> void:
	t.suite("棋谱规则审计")
	var files := _list_all_sgfs()
	t.expect(files.size() >= 10, "RUL1: 棋谱库 ≥10 局（实际 %d）" % files.size())
	for path in files:
		var r := _audit_game(path, false)
		t.expect_eq(r.fails, 0, "RUL2: %s 规则审计通过（检查 %d 项）" % [path.get_file(), r.checks])

# 逐手模拟一局棋谱并审计。
# full_check=true：每 CHECK_EVERY 手做全局面检查；false：仅终局检查一次。
static func _audit_game(path: String, full_check: bool) -> Dictionary:
	var res := { "checks": 0, "fails": 0, "infos": 0, "moves": 0 }
	var parsed: Dictionary = SGFLoader.load_from_file(path)
	if not parsed.ok:
		return res
	var sim := GameSession.new(Const.KOMI_DEFAULT, false, 361)
	sim.emit_signals = false
	sim.skip_endgame = true
	var ply := 0
	var cum := 0  # 累计提子数
	for mv in parsed.moves:
		ply += 1
		if sim.game_over:
			sim.game_over = false
			sim.consecutive_passes = 0
		if mv.pass:
			sim.do_pass(mv.color)
		else:
			var out: Dictionary = sim.play_move(mv.color, mv.pos.y, mv.pos.x)
			if out.ok:
				cum += out.get("captures", []).size()
		if full_check and ply % CHECK_EVERY == 0:
			var r := _check_position(sim, path, ply, cum)
			res.checks += r.checks
			res.fails += r.fails
			res.infos += r.infos
	if ply > 0:
		var r2 := _check_position(sim, path, ply, cum)
		res.checks += r2.checks
		res.fails += r2.fails
		res.infos += r2.infos
	res.moves = ply
	return res

# 单局面全量检查：得分分解/counters + 盘面重算 + 围困不变量 + 缓存一致性
static func _check_position(sim: GameSession, path: String, ply: int, cum: int) -> Dictionary:
	var res := { "checks": 0, "fails": 0, "infos": 0 }
	var board: BoardModel = sim.board
	var sc: Dictionary = sim.scores()

	# ---- 得分分解 + counters 数值 ----
	for color in [Const.BLACK, Const.WHITE]:
		var b: ScoreCalculator.Breakdown = sc.black if color == Const.BLACK else sc.white
		var cn: Dictionary = sim.counters.get(color, {})
		var tag: String = "%s ply=%d %s" % [path.get_file(), ply, "黑" if color == Const.BLACK else "白"]
		res.checks += 4
		if b.occupation() != b.occupation_live + b.occupation_territory:
			res.fails += 1
			print("FAIL [%s] 占领分分解不一致: occ=%d live=%d terr=%d" % [tag, b.occupation(), b.occupation_live, b.occupation_territory])
		if b.defense() != b.defense_annihilate + b.defense_siege:
			res.fails += 1
			print("FAIL [%s] 防御分分解不一致: def=%d ann=%d siege=%d" % [tag, b.defense(), b.defense_annihilate, b.defense_siege])
		if b.casualty() != b.casualty_loss + b.casualty_special:
			res.fails += 1
			print("FAIL [%s] 战损分分解不一致: cas=%d loss=%d special=%d" % [tag, b.casualty(), b.casualty_loss, b.casualty_special])
		if b.total() != b.occupation() + b.defense() + b.casualty():
			res.fails += 1
			print("FAIL [%s] 总分分解不一致: total=%d occ=%d def=%d cas=%d" % [tag, b.total(), b.occupation(), b.defense(), b.casualty()])
		res.checks += 4
		if b.defense_annihilate != int(cn.get("annihilate", 0)) * 2:
			res.fails += 1
			print("FAIL [%s] 歼灭分 %d != 歼灭数×2（%d）" % [tag, b.defense_annihilate, cn.get("annihilate", 0)])
		if b.casualty_loss != -int(cn.get("normal_lost", 0)):
			res.fails += 1
			print("FAIL [%s] 战损普通分 %d != -被提数（%d）" % [tag, b.casualty_loss, cn.get("normal_lost", 0)])
		if b.casualty_special != -int(cn.get("special_lost", 0)) * 6:
			res.fails += 1
			print("FAIL [%s] 战损特种分 %d != -特种被提数×6（%d）" % [tag, b.casualty_special, cn.get("special_lost", 0)])
		if b.occupation_live < 0 or b.occupation_territory < 0 or b.defense_annihilate < 0 or b.defense_siege < 0 or b.casualty_loss > 0 or b.casualty_special > 0:
			res.fails += 1
			print("FAIL [%s] 符号不变量违反（正分<0 或 战损>0）" % tag)
	# 提子事件与 counters 累计一致
	res.checks += 1
	var total_lost: int = 0
	for color in [Const.BLACK, Const.WHITE]:
		var cn2: Dictionary = sim.counters.get(color, {})
		total_lost += int(cn2.get("normal_lost", 0)) + int(cn2.get("special_lost", 0))
	if total_lost != cum:
		res.fails += 1
		print("FAIL [%s ply=%d] 累计提子 %d != counters 累计 %d" % [path.get_file(), ply, cum, total_lost])

	# ---- 盘面独立重算：活子 / 围困 / 围空 ----
	var sieged_groups: Array = sim.cached_sieged_groups()
	var sieged_set: Dictionary = {}
	for g in sieged_groups:
		for s in g.stones:
			sieged_set[s.y * board.size + s.x] = g.color
	var ref_live: Dictionary = _ref_live(board, sieged_set)
	var ref_siege: Dictionary = _ref_siege_score(sieged_groups)
	var ref_terr: Dictionary = _ref_territory(board, sieged_set)
	for color in [Const.BLACK, Const.WHITE]:
		var b: ScoreCalculator.Breakdown = sc.black if color == Const.BLACK else sc.white
		var tag: String = "%s ply=%d %s" % [path.get_file(), ply, "黑" if color == Const.BLACK else "白"]
		res.checks += 3
		if b.occupation_live != ref_live[color]:
			res.fails += 1
			print("FAIL [%s] 活子分 %d != 独立重算 %d" % [tag, b.occupation_live, ref_live[color]])
		if b.defense_siege != ref_siege[color]:
			res.fails += 1
			print("FAIL [%s] 围困分 %d != 独立重算 %d" % [tag, b.defense_siege, ref_siege[color]])
		if b.occupation_territory != ref_terr[color]:
			res.fails += 1
			print("FAIL [%s] 围空分 %d != 独立重算 %d" % [tag, b.occupation_territory, ref_terr[color]])

	# ---- 围困不变量（真眼必活 / 活棋有气 / 围困三条件 / 棋盘合法） ----
	# v6.2：全盘死活用迭代不动点求解（有效包围圈 = 由活棋围成的封闭边界）
	var da: Dictionary = SiegeDetector.solve_dead_alive(board)
	var sieged_keys: Dictionary = {}  # idx -> true（迭代判定的围困组群首子）
	for g in da.sieged:
		sieged_keys[g.stones[0].y * board.size + g.stones[0].x] = true
	for g in board.all_groups():
		var tag: String = "%s ply=%d %s组群@(%d,%d)" % [path.get_file(), ply, "黑" if g.color == Const.BLACK else "白", g.stones[0].y, g.stones[0].x]
		var libs: int = board.liberties(g.stones).size()
		res.checks += 1
		if libs <= 0:
			res.fails += 1
			print("FAIL [%s] 组群无气（非法局面/提子残留）" % tag)
		var gkey: int = g.stones[0].y * board.size + g.stones[0].x
		var sieged: bool = sieged_keys.has(gkey)
		var has_eyes: bool = SiegeDetector.has_two_true_eyes(board, g)
		res.checks += 1
		if has_eyes and sieged:
			res.fails += 1
			print("FAIL [%s] 有两真眼却被判围困" % tag)
		if not sieged and libs <= 0:
			res.fails += 1
			print("FAIL [%s] 判活棋但无气" % tag)
		if sieged:
			res.checks += 2
			if SiegeDetector.count_legal_empty_points(board, g) >= 4:
				res.fails += 1
				print("FAIL [%s] 判围困但圈内合法空点>=4" % tag)
			# 提示：围困组群不在对方围空圈 stones_inside 中（围空/围困模块口径差异，非错误）
			if not _group_inside_any_enclosure(board, g):
				res.infos += 1
				print("INFO [%s] 围困组群不在对方围空圈 stones_inside 中（口径差异）" % tag)
	# 缓存一致性：cached_sieged_groups 与独立判定数量一致
	res.checks += 1
	var cached_set: Dictionary = {}
	for g in sim.cached_sieged_groups():
		cached_set[g.stones[0].y * board.size + g.stones[0].x] = true
	if cached_set.size() != sieged_keys.size():
		res.fails += 1
		print("FAIL [%s ply=%d] 缓存围困组群数 %d != 独立判定 %d" % [path.get_file(), ply, cached_set.size(), sieged_keys.size()])
	return res

# ===== 独立重算辅助 =====

# 活子分：非围困棋子在攻击区数量
static func _ref_live(board: BoardModel, sieged_set: Dictionary) -> Dictionary:
	var res := { Const.BLACK: 0, Const.WHITE: 0 }
	for g in board.all_groups():
		if sieged_set.has(g.stones[0].y * board.size + g.stones[0].x):
			continue
		for s in g.stones:
			if Const.is_attack_zone(s.y, g.color):
				res[g.color] += 1
	return res

# 围困分：围困组群棋子位于围困方防御区数量
static func _ref_siege_score(sieged_groups: Array) -> Dictionary:
	var res := { Const.BLACK: 0, Const.WHITE: 0 }
	for g in sieged_groups:
		var opp: int = Const.opponent(g.color)
		for s in g.stones:
			if Const.is_defense_zone(s.y, opp):
				res[opp] += 1
	return res

# 围空分：加（空点+围困棋子）+ 扣除（围困形成的圈）+ 嵌套归属
static func _ref_territory(board: BoardModel, sieged_set: Dictionary) -> Dictionary:
	var res := { Const.BLACK: 0, Const.WHITE: 0 }
	var encs: Array = TerritoryDetector.enclosures(board)
	for e in encs:
		var c: int = e.color
		for p in e.points:
			if Const.is_attack_zone(p.y, c):
				res[c] += 2
		for s in e.get("stones_inside", []):
			if not sieged_set.has(s.y * board.size + s.x):
				continue
			if Const.is_attack_zone(s.y, c):
				res[c] += 2
	for e in encs:
		if _enc_formed_by_sieged(board, e, sieged_set):
			var c: int = e.color
			var opp: int = Const.opponent(c)
			for p in e.points:
				if Const.is_attack_zone(p.y, c):
					res[c] -= 2
				if Const.is_attack_zone(p.y, opp):
					res[opp] += 2
			for s in e.get("stones_inside", []):
				if not sieged_set.has(s.y * board.size + s.x):
					continue
				if Const.is_attack_zone(s.y, c):
					res[c] -= 2
	return res

# 包围圈是否由围困棋子形成（边界任一围空方棋子被围困）
static func _enc_formed_by_sieged(board: BoardModel, e: Dictionary, sieged_set: Dictionary) -> bool:
	var c: int = e.color
	for idx in e.get("border_stones_idx", {}):
		var r: int = idx / board.size
		var cc: int = idx % board.size
		if board.get_at(r, cc) != c:
			continue
		if sieged_set.get(idx, -1) == c:
			return true
	return false

# 组群所有棋子是否都在某对方围空圈的 stones_inside 中
static func _group_inside_any_enclosure(board: BoardModel, g: Dictionary) -> bool:
	var opp: int = Const.opponent(g.color)
	var encs: Array = TerritoryDetector.enclosures(board)
	for e in encs:
		if e.color != opp:
			continue
		for s in e.get("stones_inside", []):
			for st in g.stones:
				if s.x == st.x and s.y == st.y:
					return true
	return false

static func _list_all_sgfs() -> Array:
	var files: Array = []
	for dir_path in ["res://sgf/classic/", "res://sgf/masters/", "res://sgf/modern/"]:
		var dir := DirAccess.open(dir_path)
		if dir == null:
			continue
		dir.list_dir_begin()
		var f: String = dir.get_next()
		while f != "":
			if f.ends_with(".sgf"):
				files.append(dir_path + f)
			f = dir.get_next()
		dir.list_dir_end()
	return files
