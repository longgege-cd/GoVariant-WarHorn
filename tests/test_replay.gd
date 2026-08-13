extends RefCounted
# 棋谱库 + 回放 测试

const SGFLoader = preload("res://scripts/core/SGFLoader.gd")

func run(t: TestFramework) -> void:
	t.suite("棋谱库回放")

	# 1. 经典对局目录有棋谱
	var classic_dir := DirAccess.open("res://sgf/classic/")
	t.expect(classic_dir != null, "REP1: 经典对局目录存在")
	var classic_files := _list_sgfs("res://sgf/classic/")
	t.expect(classic_files.size() > 0, "REP1: 经典对局目录非空")

	# 2. 棋圣名局目录有棋谱
	var masters_files := _list_sgfs("res://sgf/masters/")
	t.expect(masters_files.size() > 0, "REP2: 棋圣名局目录非空")

	# 3. 当代对局目录有棋谱
	var modern_files := _list_sgfs("res://sgf/modern/")
	t.expect(modern_files.size() > 0, "REP3: 当代对局目录非空")

	# 4. 验证所有棋谱能解析且手数 > 0
	var all_files: Array = []
	for f in classic_files:
		all_files.append("res://sgf/classic/" + f)
	for f in masters_files:
		all_files.append("res://sgf/masters/" + f)
	for f in modern_files:
		all_files.append("res://sgf/modern/" + f)
	var total_games := all_files.size()
	t.expect(total_games >= 5, "REP4: 棋谱库总数 >= 5 (实际 %d)" % total_games)
	for path in all_files:
		var parsed: Dictionary = SGFLoader.load_from_file(path)
		t.expect(parsed.ok, "REP4: %s 解析成功" % path)
		t.expect(parsed.moves.size() > 0, "REP4: %s 手数 > 0" % path)

	# 5. 每个棋谱能基本回放（回放不受兵力限制，使用 361 上限；允许少量非法手，打劫等可能被跳过）
	for path in all_files:
		var parsed: Dictionary = SGFLoader.load_from_file(path)
		if not parsed.ok:
			continue
		var sim := GameSession.new(Const.KOMI_DEFAULT, false, 361)  # 回放不受 112 兵力限制
		sim.emit_signals = false  # 禁用信号发射，跳过每步 scores() 计算（性能优化）
		sim.skip_endgame = true   # 跳过 do_pass 终局判定（避免终局结算的 O(N⁴) 开销）
		var ok_count: int = 0
		var fail_count: int = 0
		for mv in parsed.moves:
			# 回放中若上一手触发了终局（双方连续虚手），重置以允许继续
			if sim.game_over:
				sim.game_over = false
			if mv.pass:
				sim.do_pass(mv.color)
				ok_count += 1
			else:
				var out = sim.play_move(mv.color, mv.pos.y, mv.pos.x)
				if out.ok:
					ok_count += 1
				else:
					fail_count += 1
		# 允许少量非法手（边境线规则与标准围棋有差异，打劫等手可能被跳过），成功率应 > 70%
		var success_rate: float = float(ok_count) / float(parsed.moves.size())
		t.expect(success_rate > 0.70, "REP5: %s 回放成功率 > 70%%（成功 %d / 失败 %d / 总 %d）" % [
			path, ok_count, fail_count, parsed.moves.size()])

	# 6. 回放后能计算每步分数
	var sample_path: String = all_files[0]
	var parsed6: Dictionary = SGFLoader.load_from_file(sample_path)
	var sim6 := GameSession.new(Const.KOMI_DEFAULT, false, 361)  # 回放不受兵力限制
	sim6.emit_signals = false  # 性能优化
	sim6.skip_endgame = true   # 跳过终局判定（性能优化）
	var score_history: Array = []
	var sc0: Dictionary = sim6.scores()
	score_history.append({"black": sc0.black.total(), "white": sc0.white.total()})
	for mv in parsed6.moves:
		if sim6.game_over:
			sim6.game_over = false
		if mv.pass:
			sim6.do_pass(mv.color)
		else:
			sim6.play_move(mv.color, mv.pos.y, mv.pos.x)
		var sc: Dictionary = sim6.scores()
		score_history.append({"black": sc.black.total(), "white": sc.white.total()})
	t.expect_eq(score_history.size(), parsed6.moves.size() + 1, "REP6: 分数历史长度 = 手数+1")

	# 7. 跳转到任意 ply 能正确重建局面
	for target_ply in [0, 10, 30, 50, parsed6.moves.size()]:
		var sim7 := GameSession.new(Const.KOMI_DEFAULT, false, 361)  # 回放不受兵力限制
		sim7.emit_signals = false  # 性能优化
		sim7.skip_endgame = true   # 跳过终局判定（性能优化）
		for i in min(target_ply, parsed6.moves.size()):
			var mv: Dictionary = parsed6.moves[i]
			if sim7.game_over:
				sim7.game_over = false
			if mv.pass:
				sim7.do_pass(mv.color)
			else:
				sim7.play_move(mv.color, mv.pos.y, mv.pos.x)
		# 验证重建后分数与顺序回放一致
		var sc_replay: Dictionary = sim7.scores()
		var sc_expected: Dictionary = score_history[target_ply]
		t.expect_eq(sc_replay.black.total(), sc_expected.black, "REP7: ply=%d 黑分一致" % target_ply)
		t.expect_eq(sc_replay.white.total(), sc_expected.white, "REP7: ply=%d 白分一致" % target_ply)

	# 8. 棋谱元数据完整
	var cosmic: Dictionary = SGFLoader.load_from_file("res://sgf/masters/cosmic_flow.sgf")
	t.expect(cosmic.ok, "REP8: cosmic_flow.sgf 解析成功")
	t.expect(cosmic.black_player != "", "REP8: 宇宙流黑方有名称（%s）" % cosmic.black_player)
	t.expect(cosmic.white_player != "", "REP8: 宇宙流白方有名称（%s）" % cosmic.white_player)

	var kejie: Dictionary = SGFLoader.load_from_file("res://sgf/modern/23.5.2017-Wuzhen-KeJie-Alphago.sgf")
	t.expect(kejie.ok, "REP8: 乌镇首局 sgf 解析成功")
	t.expect(kejie.black_player != "", "REP8: 柯洁对局黑方有名称（%s）" % kejie.black_player)
	t.expect(kejie.white_player != "", "REP8: 柯洁对局白方有名称（%s）" % kejie.white_player)
	t.expect_eq(kejie.result, "W+0.5", "REP8: 首局结果为 AlphaGo 白胜半目（W+0.5）")
	var kejie2: Dictionary = SGFLoader.load_from_file("res://sgf/modern/25.5.2017-Wuzhen-KeJie-Alphago.sgf")
	t.expect(kejie2.ok, "REP8: 乌镇次局 sgf 解析成功")
	var kejie3: Dictionary = SGFLoader.load_from_file("res://sgf/modern/27.5.2017-Wuzhen-KeJie-Alphago.sgf")
	t.expect(kejie3.ok, "REP8: 乌镇决胜局 sgf 解析成功")

	# 9. 回放不受兵力限制：piece_limit=361 时全谱 289 手全部合法（默认 112 会在第 113 手起失败）
	var sim_full := GameSession.new(Const.KOMI_DEFAULT, false, 361)
	sim_full.emit_signals = false
	sim_full.skip_endgame = true
	var illegal_cnt: int = 0
	for mv in kejie.moves:
		if mv.pass:
			sim_full.do_pass(mv.color)
		else:
			var out := sim_full.play_move(mv.color, mv.pos.y, mv.pos.x)
			if not out.ok:
				illegal_cnt += 1
	t.expect_eq(illegal_cnt, 0, "REP9: 361 限制下乌镇首局 %d 手全部合法（非法 %d）" % [kejie.moves.size(), illegal_cnt])
	t.expect(sim_full.stones_placed[Const.BLACK] > 112, "REP9: 黑方落子 %d 子已超默认兵力 112，回放不再受限" % sim_full.stones_placed[Const.BLACK])
	var sim_limited := GameSession.new(Const.KOMI_DEFAULT, false, Const.PIECE_LIMIT)
	sim_limited.emit_signals = false
	sim_limited.skip_endgame = true
	var blocked: int = 0
	for mv in kejie.moves:
		if mv.pass:
			sim_limited.do_pass(mv.color)
		else:
			var out2 := sim_limited.play_move(mv.color, mv.pos.y, mv.pos.x)
			if not out2.ok:
				blocked += 1
	t.expect(blocked > 0, "REP9: 默认 112 兵力下播放同一棋谱存在非法手（blocked=%d），证明限制确实生效" % blocked)

	# 10. AlphaGo 五番棋（CGoban 解说版）：主谱必须完整不截断
	# 此格式每个主谱手后带 C[..] 注释与 (...) 变着，旧解析器会回退导致仅剩数手
	var lee_games := [
		["res://sgf/modern/2016.03.09-AlphaGo-Lee_Sedol.sgf", "W+Resign", 186],
		["res://sgf/modern/2016.03.10-Lee_Sedol-AlphaGo.sgf", "B+Resign", 211],
		["res://sgf/modern/2016.03.12-AlphaGo-Lee_Sedol.sgf", "W+Resign", 176],
		["res://sgf/modern/2016.03.13-Lee_Sedol-Alphago.sgf", "W+Resign", 180],
		["res://sgf/modern/2016.03.15-AlphaGo-Lee_Sedol.sgf", "W+Resign", 280],
	]
	for entry in lee_games:
		var lp: Dictionary = SGFLoader.load_from_file(entry[0])
		t.expect(lp.ok, "REP10: %s 解析成功" % entry[0].get_file())
		t.expect_eq(lp.result, entry[1], "REP10: %s 结果 %s" % [entry[0].get_file(), entry[1]])
		t.expect_eq(lp.moves.size(), entry[2], "REP10: %s 主谱完整 %d 手（解说变着不截断）" % [entry[0].get_file(), entry[2]])

# 列出目录下所有 .sgf 文件
func _list_sgfs(dir_path: String) -> Array:
	var files: Array = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return files
	dir.list_dir_begin()
	var f: String = dir.get_next()
	while f != "":
		if f.ends_with(".sgf"):
			files.append(f)
		f = dir.get_next()
	dir.list_dir_end()
	return files
