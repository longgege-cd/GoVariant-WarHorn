extends RefCounted
# 分数条动态基准测试：验证 ScoreBarTracker 用固定参考上限计算条形长度
# 分数从0增长时 ratio 从0增长，达到参考上限时 ratio=1.0，超出时 clamp 到1.0

func run(t: TestFramework) -> void:
	t.suite("分数条动态基准")

	var Tracker = preload("res://scripts/ui/ScoreBarTracker.gd")
	var tracker := Tracker.new()

	# ===== 1. 固定参考上限 =====
	t.expect_eq(tracker.get_max("occ"), 80, "occ 参考上限=80")
	t.expect_eq(tracker.get_max("def"), 40, "def 参考上限=40")
	t.expect_eq(tracker.get_max("cas"), 30, "cas 参考上限=30")

	# ===== 2. 分数从0增长 → ratio 从0增长（动态增长效果）=====
	t.expect_eq(tracker.get_ratio("occ", 0), 0.0, "occ=0 → ratio=0.0（空条）")
	t.expect_eq(tracker.get_ratio("occ", 20), 0.25, "occ=20 → ratio=0.25（1/4）")
	t.expect_eq(tracker.get_ratio("occ", 40), 0.5, "occ=40 → ratio=0.5（半条）")
	t.expect_eq(tracker.get_ratio("occ", 60), 0.75, "occ=60 → ratio=0.75（3/4）")
	t.expect_eq(tracker.get_ratio("occ", 80), 1.0, "occ=80 → ratio=1.0（满条）")

	# ===== 3. 超过参考上限 → clamp 到1.0 =====
	t.expect_eq(tracker.get_ratio("occ", 100), 1.0, "occ=100 > 80 → clamp 1.0")
	t.expect_eq(tracker.get_ratio("occ", 171), 1.0, "occ=171 > 80 → clamp 1.0")

	# ===== 4. 防御分与战损分 =====
	t.expect_eq(tracker.get_ratio("def", 0), 0.0, "def=0 → 0.0")
	t.expect_eq(tracker.get_ratio("def", 20), 0.5, "def=20 → 0.5")
	t.expect_eq(tracker.get_ratio("def", 40), 1.0, "def=40 → 1.0")
	t.expect_eq(tracker.get_ratio("def", 60), 1.0, "def=60 > 40 → clamp 1.0")
	t.expect_eq(tracker.get_ratio("cas", 15), 0.5, "cas=15 → 0.5")
	t.expect_eq(tracker.get_ratio("cas", 30), 1.0, "cas=30 → 1.0")

	# ===== 5. 负值与边界 =====
	t.expect_eq(tracker.get_ratio("occ", -5), 0.0, "occ=-5 → clamp 0.0")
	t.expect_eq(tracker.get_ratio("def", -10), 0.0, "def=-10 → clamp 0.0")

	# ===== 6. reset() 无副作用（固定上限无需重置）=====
	tracker.reset()
	t.expect_eq(tracker.get_max("occ"), 80, "reset() 后 occ 上限不变=80")
	t.expect_eq(tracker.get_ratio("occ", 40), 0.5, "reset() 后 ratio 计算正常")

	# ===== 7. 真实对局场景模拟：分数逐手增长，条形动态变长 =====
	var s := GameSession.new(Const.KOMI_DEFAULT, false)
	# 开局：黑未下子，occ=0 → 空条
	var sc = s.scores()
	t.expect_eq(tracker.get_ratio("occ", sc.black.occupation()), 0.0, "开局黑 occ=0 → 空条")
	# 黑下白境(10,10)：occ=1 → ratio=0.0125（条形开始出现）
	s.play_move(Const.BLACK, 10, 10)
	sc = s.scores()
	var r1: float = tracker.get_ratio("occ", sc.black.occupation())
	t.expect(r1 > 0.0, "黑(10,10) occ=1 → ratio>0（条形出现）")
	# 黑再下白境(11,11)：occ=2 → ratio 增大
	s.play_move(Const.WHITE, 0, 0)
	s.play_move(Const.BLACK, 11, 11)
	sc = s.scores()
	var r2: float = tracker.get_ratio("occ", sc.black.occupation())
	t.expect(r2 > r1, "黑(11,11) occ=2 → ratio 增大（条形变长）")
	# 黑再下白境(12,12)：occ=3 → ratio 继续增大
	s.play_move(Const.WHITE, 0, 1)
	s.play_move(Const.BLACK, 12, 12)
	sc = s.scores()
	var r3: float = tracker.get_ratio("occ", sc.black.occupation())
	t.expect(r3 > r2, "黑(12,12) occ=3 → ratio 继续增大（条形继续变长）")
	# 确认条形长度序列递增
	t.expect(r3 > r2 and r2 > r1 and r1 > 0.0, "条形长度递增: 0 < %.4f < %.4f < %.4f" % [r1, r2, r3])
