# 音频管理器（autoload）—— 用代码动态生成音效，无需外部音频文件
#
# 设计：
#   - 使用 AudioStreamWAG + 16-bit PCM 代码合成音效
#   - 多通道 AudioStreamPlayer 避免音效截断
#   - 提供落子、提子、围空、部署、终局等音效
#   - sound_enabled 开关（通过 EffectsPlayer 控制）
extends Node

var _players: Array[AudioStreamPlayer] = []
var _player_idx: int = 0
const _MAX_PLAYERS: int = 8

# 预生成的音效缓存
var _sounds: Dictionary = {}  # name -> AudioStreamWAV

func _ready() -> void:
	# 创建多通道播放器
	for i in _MAX_PLAYERS:
		var p := AudioStreamPlayer.new()
		p.bus = "Master"
		add_child(p)
		_players.append(p)
	# 预生成所有音效
	_generate_all_sounds()

# 获取一个可用的播放器（轮询）
func _get_player() -> AudioStreamPlayer:
	var p: AudioStreamPlayer = _players[_player_idx]
	_player_idx = (_player_idx + 1) % _MAX_PLAYERS
	return p

# 播放指定音效
func play(name: String, volume_db: float = 0.0) -> void:
	if not _sounds.has(name):
		Log.w("音效不存在: %s" % name)
		return
	var p := _get_player()
	p.stream = _sounds[name]
	p.volume_db = volume_db
	p.play()

# ===== 音效合成 =====

func _generate_all_sounds() -> void:
	_sounds["place"] = _gen_place_sound()       # 落子：短促"啪"
	_sounds["capture"] = _gen_capture_sound()   # 提子：爆裂声
	_sounds["territory"] = _gen_territory_sound() # 围空：柔和"叮"
	_sounds["deploy"] = _gen_deploy_sound()     # 部署：金属"锵"
	_sounds["siege"] = _gen_siege_sound()       # 围困：低沉"嗡"
	_sounds["game_end"] = _gen_game_end_sound() # 终局：号角

# 落子音：800Hz 正弦波 + 1200Hz 泛音，0.08秒，快速衰减
func _gen_place_sound() -> AudioStreamWAV:
	var sample_rate: int = 22050
	var duration: float = 0.08
	var samples: int = int(sample_rate * duration)
	var data: PackedByteArray = PackedByteArray()
	data.resize(samples * 2)  # 16-bit = 2 bytes/sample
	for i in samples:
		var t: float = float(i) / sample_rate
		var env: float = exp(-t * 30.0)  # 快速衰减
		var wave: float = 0.6 * sin(t * TAU * 800) + 0.3 * sin(t * TAU * 1200)
		var val: int = int(wave * env * 32767)
		val = clamp(val, -32768, 32767)
		_encode_s16(data, i * 2, val)
	return _make_wav(data, sample_rate)

# 提子音：白噪声 + 150Hz 低频，0.35秒，中速衰减
func _gen_capture_sound() -> AudioStreamWAV:
	var sample_rate: int = 22050
	var duration: float = 0.35
	var samples: int = int(sample_rate * duration)
	var data: PackedByteArray = PackedByteArray()
	data.resize(samples * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 42  # 固定种子保证一致性
	for i in samples:
		var t: float = float(i) / sample_rate
		var env: float = exp(-t * 8.0)
		var noise: float = rng.randf_range(-1.0, 1.0) * 0.5
		var low: float = sin(t * TAU * 150) * 0.4
		var val: int = int((noise + low) * env * 32767)
		val = clamp(val, -32768, 32767)
		_encode_s16(data, i * 2, val)
	return _make_wav(data, sample_rate)

# 围空音：880Hz + 1320Hz 和弦，0.5秒，慢衰减
func _gen_territory_sound() -> AudioStreamWAV:
	var sample_rate: int = 22050
	var duration: float = 0.5
	var samples: int = int(sample_rate * duration)
	var data: PackedByteArray = PackedByteArray()
	data.resize(samples * 2)
	for i in samples:
		var t: float = float(i) / sample_rate
		var env: float = exp(-t * 4.0)
		var wave: float = 0.3 * sin(t * TAU * 880) + 0.2 * sin(t * TAU * 1320)
		var val: int = int(wave * env * 32767)
		val = clamp(val, -32768, 32767)
		_encode_s16(data, i * 2, val)
	return _make_wav(data, sample_rate)

# 部署音：500Hz 方波 + 1000Hz，0.15秒，快速衰减（金属感）
func _gen_deploy_sound() -> AudioStreamWAV:
	var sample_rate: int = 22050
	var duration: float = 0.15
	var samples: int = int(sample_rate * duration)
	var data: PackedByteArray = PackedByteArray()
	data.resize(samples * 2)
	for i in samples:
		var t: float = float(i) / sample_rate
		var env: float = exp(-t * 12.0)
		var sq: float = 0.4 if sin(t * TAU * 500) > 0 else -0.4  # 方波
		var sine: float = 0.3 * sin(t * TAU * 1000)
		var val: int = int((sq + sine) * env * 32767)
		val = clamp(val, -32768, 32767)
		_encode_s16(data, i * 2, val)
	return _make_wav(data, sample_rate)

# 围困音：200Hz 低频，0.4秒，中速衰减
func _gen_siege_sound() -> AudioStreamWAV:
	var sample_rate: int = 22050
	var duration: float = 0.4
	var samples: int = int(sample_rate * duration)
	var data: PackedByteArray = PackedByteArray()
	data.resize(samples * 2)
	for i in samples:
		var t: float = float(i) / sample_rate
		var env: float = exp(-t * 5.0)
		var wave: float = 0.5 * sin(t * TAU * 200) + 0.2 * sin(t * TAU * 100)
		var val: int = int(wave * env * 32767)
		val = clamp(val, -32768, 32767)
		_encode_s16(data, i * 2, val)
	return _make_wav(data, sample_rate)

# 终局音：号角（渐强后渐弱的和弦），1.2秒
func _gen_game_end_sound() -> AudioStreamWAV:
	var sample_rate: int = 22050
	var duration: float = 1.2
	var samples: int = int(sample_rate * duration)
	var data: PackedByteArray = PackedByteArray()
	data.resize(samples * 2)
	for i in samples:
		var t: float = float(i) / sample_rate
		# 渐强后渐弱包络
		var env: float
		if t < 0.3:
			env = t / 0.3  # 渐强
		else:
			env = exp(-(t - 0.3) * 2.0)  # 渐弱
		# 和弦：392Hz(军号) + 523Hz(高八度) + 196Hz(低八度)
		var wave: float = 0.3 * sin(t * TAU * 392) + 0.2 * sin(t * TAU * 523) + 0.15 * sin(t * TAU * 196)
		var val: int = int(wave * env * 32767)
		val = clamp(val, -32768, 32767)
		_encode_s16(data, i * 2, val)
	return _make_wav(data, sample_rate)

# ===== 工具函数 =====

# 小端编码 16-bit 有符号整数
func _encode_s16(buf: PackedByteArray, offset: int, val: int) -> void:
	var u: int = val if val >= 0 else val + 65536
	buf[offset] = u & 0xFF
	buf[offset + 1] = (u >> 8) & 0xFF

# 构建 AudioStreamWAV
func _make_wav(data: PackedByteArray, sample_rate: int) -> AudioStreamWAV:
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = sample_rate
	wav.stereo = false
	wav.data = data
	return wav
