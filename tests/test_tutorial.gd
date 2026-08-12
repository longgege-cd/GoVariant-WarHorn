extends RefCounted
# 教程模块测试：关卡数据完整性 + 完成判定逻辑 + 进度解锁链
#
# 注意：TutorialProgress 会写 user://tutorial_progress.json，
# 测试前备份、结束后恢复，避免污染真实游戏进度。

func run(t: TestFramework) -> void:
	t.suite("教程·关卡数据")
	_test_lesson_data(t)
	t.suite("教程·完成判定")
	_test_checks(t)
	t.suite("教程·进度解锁")
	_test_progress(t)

# ===== 1. 关卡数据完整性 =====
func _test_lesson_data(t: TestFramework) -> void:
	var lessons: Array = LessonData.LESSONS
	t.expect_eq(lessons.size(), 14, "共 14 关")
	t.expect_eq(lessons.size(), TutorialProgress.TOTAL_LESSONS, "与进度常量一致")
	var required: Array = ["id", "stage", "title", "goal", "explain", "setup", "target"]
	var ids: Dictionary = {}
	var seen_pos: Dictionary = {}
	for i in lessons.size():
		var l: Dictionary = lessons[i]
		var tag: String = "关卡%d(%s)" % [i, l.get("id", "?")]
		for k in required:
			t.expect(l.has(k), "%s 缺少字段 %s" % [tag, k])
		t.expect(l.get("explain", []).size() > 0, "%s 有讲解内容" % tag)
		# id 唯一
		t.expect(not ids.has(l.get("id", "")), "%s id 重复" % tag)
		ids[l.get("id", "")] = true
		# 每关都有 stage
		t.expect(not str(l.get("stage", "")).is_empty(), "%s 有阶段" % tag)
		# setup 合法性：坐标越界 / 棋色 / 无重叠
		seen_pos.clear()
		for s in l.get("setup", []):
			var r: int = s[0]
			var c: int = s[1]
			var col: int = s[2]
			t.expect(r >= 0 and r < 19 and c >= 0 and c < 19, "%s setup 越界 (%d,%d)" % [tag, r, c])
			t.expect(col == Const.BLACK or col == Const.WHITE, "%s setup 棋色非法" % tag)
			var key: Vector2i = Vector2i(c, r)
			t.expect(not seen_pos.has(key), "%s setup 位置重叠 (%d,%d)" % [tag, r, c])
			seen_pos[key] = true
	# hint 合法性
	for i in lessons.size():
		var l: Dictionary = lessons[i]
		var tag: String = "关卡%d(%s)" % [i, l.get("id", "?")]
		for h in l.get("hint", []):
			t.expect(h[0] >= 0 and h[0] < 19 and h[1] >= 0 and h[1] < 19, "%s hint 越界" % tag)
	# 各阶段覆盖
	var stages: Dictionary = {}
	for l in lessons:
		stages[l.get("stage", "")] = true
	t.expect(stages.has("基础") and stages.has("核心") and stages.has("进阶"), "包含基础/核心/进阶阶段")

# ===== 2. 完成判定逻辑 =====
func _session_with_setup(lesson: Dictionary) -> GameSession:
	var s := GameSession.new(Const.KOMI_DEFAULT, true)
	for st in lesson.get("setup", []):
		s.board.set_at(st[0], st[1], st[2])
	return s

func _test_checks(t: TestFramework) -> void:
	# zone_of 区域划分
	t.expect_eq(TutorialChecks.zone_of(8), 0, "行8=黑方领土")
	t.expect_eq(TutorialChecks.zone_of(9), 1, "行9=边境线")
	t.expect_eq(TutorialChecks.zone_of(10), 2, "行10=白方领土")

	# place：落一手即完成
	var s := GameSession.new(Const.KOMI_DEFAULT, true)
	t.expect(not TutorialChecks.is_complete("place", s, Const.BLACK), "未落子未完成")
	s.play_move(Const.BLACK, 9, 9)
	t.expect(TutorialChecks.is_complete("place", s, Const.BLACK), "落一手完成")

	# capture：1-3 提吃白子
	var l := LessonData.get_lesson(2)
	s = _session_with_setup(l)
	var out := s.play_move(Const.BLACK, 3, 2)
	t.expect(out.ok, "1-3 落子封气合法")
	t.expect_eq(out.captures.size(), 1, "1-3 提吃 1 子")
	t.expect(TutorialChecks.is_complete("capture", s, Const.BLACK, {"last_outcome": out}), "capture 判定完成")
	# 未提吃时不完成
	s = _session_with_setup(LessonData.get_lesson(2))
	var out_no := s.play_move(Const.BLACK, 0, 0)
	t.expect(not TutorialChecks.is_complete("capture", s, Const.BLACK, {"last_outcome": out_no}), "未提吃不完成")

	# annihilate：2-4 己方领土提吃
	l = LessonData.get_lesson(6)
	s = _session_with_setup(l)
	out = s.play_move(Const.BLACK, 3, 5)
	t.expect(out.ok, "2-4 落子合法")
	t.expect_eq(out.captures.size(), 1, "2-4 提吃 1 子")
	t.expect_eq(int(s.counters[Const.BLACK].annihilate), 1, "2-4 歼灭计数 +1")
	t.expect(TutorialChecks.is_complete("annihilate", s, Const.BLACK), "annihilate 判定完成")

	# annihilate 判定跟随 player_color（玩家切白后白方歼灭也应判定）
	s = GameSession.new(Const.KOMI_DEFAULT, true)
	s.to_move = Const.WHITE
	# 白方领土（行>=10）内围黑：白封气提吃黑子
	s.board.set_at(12, 6, Const.WHITE)
	s.board.set_at(14, 6, Const.WHITE)
	s.board.set_at(13, 7, Const.WHITE)
	s.board.set_at(13, 6, Const.BLACK)
	out = s.play_move(Const.WHITE, 13, 5)
	t.expect(out.ok, "白方提吃合法")
	t.expect_eq(out.captures.size(), 1, "白提 1 子")
	t.expect_eq(int(s.counters[Const.WHITE].annihilate), 1, "白歼灭计数 +1")
	t.expect(TutorialChecks.is_complete("annihilate", s, Const.WHITE), "annihilate 判定跟随白方")
	t.expect(not TutorialChecks.is_complete("annihilate", s, Const.BLACK), "黑方视角无歼灭不完成")

	# enclosure：2-1 封口形成包围圈
	l = LessonData.get_lesson(3)
	s = _session_with_setup(l)
	t.expect(not TutorialChecks.is_complete("enclosure", s, Const.BLACK), "未封口无围空")
	out = s.play_move(Const.BLACK, 12, 11)
	t.expect(out.ok, "2-1 封口落子合法")
	t.expect(TutorialChecks.is_complete("enclosure", s, Const.BLACK), "enclosure 判定完成")

	# siege：2-3 压缩空点 4→3 触发围困
	l = LessonData.get_lesson(5)
	s = _session_with_setup(l)
	t.expect(not TutorialChecks.is_complete("siege", s, Const.BLACK), "4 空点未围困")
	out = s.play_move(Const.BLACK, 11, 10)
	t.expect(out.ok, "2-3 压缩落子合法")
	t.expect(TutorialChecks.has_siege(s), "2-3 出现围困组群")
	t.expect(TutorialChecks.is_complete("siege", s, Const.BLACK), "siege 判定完成")

	# border_enclosure：3-1 边境双重得分
	l = LessonData.get_lesson(7)
	s = _session_with_setup(l)
	t.expect(not TutorialChecks.is_complete("border_enclosure", s, Const.BLACK), "未封口未完成")
	out = s.play_move(Const.BLACK, 9, 12)
	t.expect(out.ok, "3-1 封口落子合法")
	t.expect(TutorialChecks.is_complete("border_enclosure", s, Const.BLACK), "border_enclosure 判定完成")

	# pass：extra 标记
	t.expect(TutorialChecks.is_complete("pass", s, Const.BLACK, {"pass_done": true}), "pass 判定完成")
	t.expect(not TutorialChecks.is_complete("pass", s, Const.BLACK), "未虚手不完成")

	# ko：3-4 提子形成劫
	l = LessonData.get_lesson(10)
	s = _session_with_setup(l)
	out = s.play_move(Const.BLACK, 1, 2)
	t.expect(out.ok, "3-4 提劫落子合法")
	t.expect_eq(out.captures.size(), 1, "3-4 提吃 1 子")
	t.expect(s.ko_point != GoRules.NO_KO, "3-4 产生劫点")
	t.expect(TutorialChecks.is_complete("ko", s, Const.BLACK), "ko 判定完成")

	# deploy：部署特种
	s = GameSession.new(Const.KOMI_DEFAULT, true)
	s.to_move = Const.BLACK
	out = s.deploy_special(Const.BLACK, 10, 10)
	t.expect(out.ok, "5-1 部署成功")
	t.expect_eq(s.special.pieces.size(), 1, "5-1 已有 1 特种")
	t.expect(TutorialChecks.is_complete("deploy", s, Const.BLACK), "deploy 判定完成")

# ===== 3. 进度解锁链 =====
func _test_progress(t: TestFramework) -> void:
	# 备份真实进度文件
	var real_file: String = TutorialProgress.SAVE_PATH
	var backup: String = "user://tutorial_progress.bak"
	if FileAccess.file_exists(real_file):
		var src := FileAccess.open(real_file, FileAccess.READ)
		if src:
			var dst := FileAccess.open(backup, FileAccess.WRITE)
			if dst:
				dst.store_string(src.get_as_text())
				dst.close()
			src.close()
	# 清空，保证可重复
	TutorialProgress.reset_progress()

	var p: Dictionary = TutorialProgress.load_progress()
	t.expect_eq(p.get("unlocked", []), [0], "初始解锁第 0 关")
	t.expect_eq(p.get("completed", []).size(), 0, "初始无完成")
	t.expect(TutorialProgress.is_unlocked(p, 0), "第 0 关已解锁")
	t.expect(not TutorialProgress.is_unlocked(p, 1), "第 1 关未解锁")
	t.expect(not TutorialProgress.is_completed(p, 0), "第 0 关未完成")

	TutorialProgress.mark_completed(p, 0)
	t.expect(TutorialProgress.is_completed(p, 0), "第 0 关标记完成")
	t.expect(TutorialProgress.is_unlocked(p, 1), "完成第 0 关解锁第 1 关")
	t.expect(not TutorialProgress.is_unlocked(p, 2), "第 2 关仍锁定")

	# 完成至最后一关
	for i in range(1, TutorialProgress.TOTAL_LESSONS):
		TutorialProgress.mark_completed(p, i)
	t.expect(TutorialProgress.is_completed(p, TutorialProgress.TOTAL_LESSONS - 1), "最后一关完成")
	t.expect_eq(p.get("unlocked", []).size(), TutorialProgress.TOTAL_LESSONS, "全部解锁")

	# 持久化回读
	var p2: Dictionary = TutorialProgress.load_progress()
	t.expect_eq(p2.get("completed", []).size(), TutorialProgress.TOTAL_LESSONS, "保存后回读完成数一致")
	t.expect_eq(p2.get("unlocked", []).size(), TutorialProgress.TOTAL_LESSONS, "保存后回读解锁数一致")
	# 防回归：Godot 4.7 JSON.parse_string 把整数解析为 float，
	# 若不归一化，Array.find(int) 找不到 float 元素 → 解锁判定失效
	t.expect_eq(typeof(p2.get("completed", [])[0]), TYPE_INT, "回读 completed 元素为 int（防 float 回归）")
	t.expect_eq(typeof(p2.get("unlocked", [])[0]), TYPE_INT, "回读 unlocked 元素为 int（防 float 回归）")
	t.expect(p2.get("completed", []).find(0) >= 0, "回读后 find(int) 可匹配")

	# 恢复真实进度
	TutorialProgress.reset_progress()
	if FileAccess.file_exists(backup):
		var src2 := FileAccess.open(backup, FileAccess.READ)
		if src2:
			var dst2 := FileAccess.open(real_file, FileAccess.WRITE)
			if dst2:
				dst2.store_string(src2.get_as_text())
				dst2.close()
			src2.close()
		DirAccess.remove_absolute(ProjectSettings.globalize_path(backup))
