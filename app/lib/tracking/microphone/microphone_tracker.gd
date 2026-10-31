## Lip sync from the microphone. The VoiceInput bus carries the microphone (muted afterwards) through a
## spectrum analyzer; from it every frame:
## - VoiceVolume: the bus peak with gain, a noise gate (below it is silence) and smoothing
## - VoiceFrequency: how bright the voice is (spectral centroid, 400 Hz to 2.5 kHz mapped to 0..1)
## - VoiceA, VoiceI, VoiceU, VoiceE, VoiceO: which vowel it sounds like. The spectrum is tilted up 6 dB per
##   octave (a voice falls off about that much), the first two formants are the strongest peaks in their
##   ranges, and each vowel gets a share by how close they are to its own; the shares add up to the volume.
##   VoiceSilence is the rest.
extends "res://lib/tracking/tracker.gd"

static func _static_init() -> void:
	Registry.add_parameter("VoiceVolume", Vector2(0, 1), 0.0, "Microphone")
	Registry.add_parameter("VoiceFrequency", Vector2(0, 1), 0.0, "Microphone")
	Registry.add_parameter("VoiceVolumePlusMouthOpen", Vector2(0, 1), 0.0, "Microphone")
	Registry.add_parameter("VoiceFrequencyPlusMouthSmile", Vector2(0, 1), 0.0, "Microphone")

	Registry.add_parameter("VoiceA", Vector2(0, 1), 0.0, "Microphone")
	Registry.add_parameter("VoiceE", Vector2(0, 1), 0.0, "Microphone")
	Registry.add_parameter("VoiceI", Vector2(0, 1), 0.0, "Microphone")
	Registry.add_parameter("VoiceO", Vector2(0, 1), 0.0, "Microphone")
	Registry.add_parameter("VoiceU", Vector2(0, 1), 0.0, "Microphone")
	Registry.add_parameter("VoiceSilence", Vector2(0, 1), 0.0, "Microphone")

## first and second formant (Hz) of each vowel, an average adult voice
const VOWELS = {
	"VoiceA": Vector2(750, 1250),
	"VoiceI": Vector2(300, 2300),
	"VoiceU": Vector2(350, 1250),
	"VoiceE": Vector2(480, 1900),
	"VoiceO": Vector2(500, 850),
}
## how far (natural log of the frequency ratio) a formant may sit from a vowel's and still count
const F1_SPREAD = 0.28
const F2_SPREAD = 0.22
## volume above the gate that counts as full (dB)
const VOLUME_SPAN_DB = 30.0
## log-spaced bands the spectrum is read in
const BANDS = 48
const LOW_HZ = 90.0
const HIGH_HZ = 4000.0

@onready var bus = AudioServer.get_bus_index("VoiceInput")
@onready var mic = $AudioStreamPlayer

var enabled = true :
	set(v):
		var bus = AudioServer.get_bus_index("VoiceInput")
		AudioServer.set_bus_effect_enabled(bus, 0, v)
		mic.playing = v
		set_process(v)
	get():
		return mic.playing

var device: String = "Default" :
	set(v):
		device = v
		AudioServer.input_device = v

## added to the microphone level (dB)
var gain_db := 0.0
## quieter than this is silence (dB, after gain)
var gate_db := -45.0
## 0 follows the voice instantly, 1 is very slow
var smoothing := 0.4
## the level before the gate, for the meter in the settings (dB after gain)
var level_db := -80.0

## the first two formants found last frame (Hz), for tests and a future display
var formants := Vector2.ZERO
var _analyzer: AudioEffectSpectrumAnalyzerInstance
var _smoothed := {}

func create_config() -> Node:
	var config = preload("res://lib/tracking/microphone/config.tscn").instantiate()
	config.tracker = self
	return config

## plays a file through the voice bus instead of the microphone (automation and tests)
func use_file(path: String) -> void:
	var stream := AudioStreamWAV.load_from_file(path)
	if stream == null:
		push_error("[microphone] cannot read %s" % path)
		return
	mic.stream = stream
	mic.play()
	set_process(true)

func _process(delta: float) -> void:
	if _analyzer == null:
		_analyzer = AudioServer.get_bus_effect_instance(bus, 1)
	level_db = AudioServer.get_bus_peak_volume_left_db(bus, 0) + gain_db
	var volume := clampf((level_db - gate_db) / VOLUME_SPAN_DB, 0.0, 1.0)

	var bands := _bands()
	var total := 0.0
	var centroid := 0.0
	for b in bands:
		total += b.y
		centroid += b.x * b.y
	var frequency := 0.0
	if total > 0.0 and volume > 0.0:
		centroid /= total
		frequency = clampf(inverse_lerp(log(400.0), log(2500.0), log(maxf(centroid, 1.0))), 0.0, 1.0)

	var out := {"VoiceVolume": volume, "VoiceFrequency": frequency}
	formants = _formants(bands)
	var scores := {}
	var score_sum := 0.0
	for v in VOWELS:
		var f: Vector2 = VOWELS[v]
		var d1 := log(formants.x / f.x) / F1_SPREAD
		var d2 := log(formants.y / f.y) / F2_SPREAD
		var s := exp(-0.5 * (d1 * d1 + d2 * d2)) if formants != Vector2.ZERO else 0.0
		scores[v] = s
		score_sum += s
	for v in VOWELS:
		out[v] = volume * (scores[v] / score_sum if score_sum > 0.0 else 0.0)
	out["VoiceSilence"] = 1.0 - volume

	# smoothing: the mouth opens quickly and closes a little slower
	var rate := lerpf(60.0, 4.0, clampf(smoothing, 0.0, 1.0))
	for k in out:
		var prev: float = _smoothed.get(k, out[k])
		var speed := rate if out[k] > prev else rate * 0.6
		_smoothed[k] = lerpf(prev, out[k], clampf(speed * delta, 0.0, 1.0))
	update(_smoothed)

## [Vector2(center Hz, magnitude)] in log-spaced bands
func _bands() -> Array[Vector2]:
	var out: Array[Vector2] = []
	if _analyzer == null:
		return out
	var step := pow(HIGH_HZ / LOW_HZ, 1.0 / BANDS)
	var f := LOW_HZ
	for i in BANDS:
		var m := _analyzer.get_magnitude_for_frequency_range(f, f * step, AudioEffectSpectrumAnalyzerInstance.MAGNITUDE_AVERAGE)
		var center := sqrt(f * f * step)
		# tilt up 6 dB per octave so the higher formants are not drowned by the low ones
		out.append(Vector2(center, (m.x + m.y) * 0.5 * center / 1000.0))
		f *= step
	return out

## first and second formant (Hz): the strongest peak of the smoothed spectrum between 250 and 950 Hz, then
## the strongest peak between 1.4 times that and 2.8 kHz; zero when there is no spectrum
func _formants(bands: Array[Vector2]) -> Vector2:
	if bands.size() < 3:
		return Vector2.ZERO
	var smooth: Array[float] = []
	for i in bands.size():
		var a := bands[maxi(i - 1, 0)].y
		var b := bands[mini(i + 1, bands.size() - 1)].y
		smooth.append(0.25 * a + 0.5 * bands[i].y + 0.25 * b)
	var f1 := _peak(bands, smooth, 250.0, 950.0)
	if f1 <= 0.0:
		return Vector2.ZERO
	var f2 := _peak(bands, smooth, maxf(f1 * 1.4, 700.0), 2800.0)
	return Vector2(f1, f2) if f2 > 0.0 else Vector2.ZERO

## the strongest local maximum in the range, so the falling edge of a lower peak never counts
func _peak(bands: Array[Vector2], values: Array[float], lo: float, hi: float) -> float:
	var best := -1.0
	var at := 0.0
	for i in range(1, bands.size() - 1):
		if bands[i].x < lo or bands[i].x > hi:
			continue
		if values[i] >= values[i - 1] and values[i] >= values[i + 1] and values[i] > best:
			best = values[i]
			at = bands[i].x
	return at if best > 0.0 else 0.0
