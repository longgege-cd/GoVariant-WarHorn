extends RefCounted
# SGF 加载器 测试

const SGFLoader = preload("res://scripts/core/SGFLoader.gd")

func run(t: TestFramework) -> void:
	t.suite("SGF 加载器")

	# 1. 基本解析：单步落子
	var text1 := "(;GM[1]FF[4]SZ[19];B[pd];W[dp])"
	var r1: Dictionary = SGFLoader.parse(text1)
	t.expect(r1.ok, "SGF1: 解析成功")
	t.expect_eq(r1.size, 19, "SGF1: 棋盘 19")
	t.expect_eq(r1.moves.size(), 2, "SGF1: 2 手棋")
	t.expect_eq(r1.moves[0].color, Const.BLACK, "SGF1: 第1手黑")
	# SGF 'p'=15, 'd'=3 → Vector2i(x=col=15, y=row=3)
	t.expect_eq(r1.moves[0].pos, Vector2i(15, 3), "SGF1: B[pd]=(col15,row3)")
	t.expect(not r1.moves[0].pass, "SGF1: 第1手非虚手")
	t.expect_eq(r1.moves[1].color, Const.WHITE, "SGF1: 第2手白")
	# SGF 'd'=3, 'p'=15 → Vector2i(x=col=3, y=row=15)
	t.expect_eq(r1.moves[1].pos, Vector2i(3, 15), "SGF1: W[dp]=(col3,row15)")

	# 2. 玩家名 + 结果
	var text2 := "(;PB[黑方]PW[白方]RE[B+2.5];B[aa];W[bb])"
	var r2: Dictionary = SGFLoader.parse(text2)
	t.expect_eq(r2.black_player, "黑方", "SGF2: 黑方名")
	t.expect_eq(r2.white_player, "白方", "SGF2: 白方名")
	t.expect_eq(r2.result, "B+2.5", "SGF2: 结果")

	# 3. 虚手
	var text3 := "(;B[];W[tt])"
	var r3: Dictionary = SGFLoader.parse(text3)
	t.expect_eq(r3.moves.size(), 2, "SGF3: 2 手（虚手）")
	t.expect(r3.moves[0].pass, "SGF3: 第1手虚手")
	t.expect(r3.moves[1].pass, "SGF3: 第2手虚手（tt 越界）")

	# 4. 子分支跳过（标准形式：主分支连续 ';'，变着用 ()）
	var text4 := "(;B[pd];W[dp](;B[qq])(;B[rr]))"
	var r4: Dictionary = SGFLoader.parse(text4)
	t.expect_eq(r4.moves.size(), 2, "SGF4: 主分支 2 手（跳过变着）")
	t.expect_eq(r4.moves[1].pos, Vector2i(3, 15), "SGF4: 第2手 W[dp]")

	# 5. 让子局面（AB/AW）
	var text5 := "(;AB[aa][bb][cc]AW[qq];B[dd];W[ee])"
	var r5: Dictionary = SGFLoader.parse(text5)
	t.expect_eq(r5.setup_black.size(), 3, "SGF5: 黑让子 3 子")
	t.expect_eq(r5.setup_white.size(), 1, "SGF5: 白让子 1 子")
	t.expect_eq(r5.setup_black[0], Vector2i(0, 0), "SGF5: AB[aa]=(0,0)")

	# 6. 注释跳过
	var text6 := "(;B[pd]C[这是注释];W[dp]C[另一条注释])"
	var r6: Dictionary = SGFLoader.parse(text6)
	t.expect_eq(r6.moves.size(), 2, "SGF6: 跳过注释后 2 手")

	# 7. 文件加载
	var r7: Dictionary = SGFLoader.load_from_file("res://sgf/sample_game.sgf")
	t.expect(r7.ok, "SGF7: 示例文件加载成功")
	t.expect(r7.moves.size() > 50, "SGF7: 示例棋谱 > 50 手")

	# 8. 边界情况：空字符串
	var r8: Dictionary = SGFLoader.parse("")
	t.expect(not r8.ok, "SGF8: 空字符串解析失败")

	# 9. 转义字符
	var text9 := "(;C[含\\]右括号];B[pd])"
	var r9: Dictionary = SGFLoader.parse(text9)
	t.expect(r9.ok, "SGF9: 含转义字符解析成功")
	t.expect_eq(r9.moves.size(), 1, "SGF9: 1 手棋")
