extends Node

const PhPaths := preload("ph_paths.gd")

## What this game makes a noise about, and the noise, on the client.
##
## [b]In a hiding game the sounds ARE the game.[/b] A taunt is the only thing that says where a
## prop is, so it is heard where the prop is, as loud as the server allows and no further; a
## prop found has a noise of its own, so a hunter in the next room knows somebody else got one;
## the hunters' release is a horn every prop hears wherever they are hiding.
##
## [b]A catalogue of ids and a table of stand-ins, which is the family's shape.[/b] dot-audio
## decides what is audible, how many at once and how far; [method sound_catalogue] is those
## decisions, naming paths under `audio/`, and [method sound_recipes] says which synthesised
## voice stands in for each until a real `.ogg` is dropped in — [DotAudioSinkGodot] consults
## the file before the stand-in.
##
## [b]Taunts are files, and they are played from the prop.[/b] They are CC0 voice lines and
## jingles in `taunts/` (see its README), listed in `taunts/taunts.json`; a taunt is an
## [AudioStreamPlayer3D] parented to the player who made it, so it moves with a prop that
## runs, and dies with one that is found.
##
## [b]Never on a server, and never deciding anything.[/b]

const CHANNEL := "ph.audio"

static var SOUND_DIR := PhPaths.rebase("res://audio")

## A round begins and the props scatter.
const HIDE := &"hide"
## The hunters are let go.
const SEEK := &"seek"
## The last seconds of hiding.
const COUNTDOWN := &"countdown"
## A prop found, somewhere. Positional.
const PROP_FOUND := &"prop_found"
## A hunter beaten by the furniture. Positional.
const HUNTER_DOWN := &"hunter_down"
## You, out. Flat.
const YOU_ARE_OUT := &"you_are_out"
const ROUND_WON := &"round_won"
const ROUND_LOST := &"round_lost"
## Becoming something, and showing your face. Positional, quiet, short: a prop that changes
## shape in front of a hunter should be heard doing it.
const DISGUISE := &"disguise"
const REVEAL := &"reveal"
## The furniture biting back.
const DECOY := &"decoy"
const WEAPON_SHOT := &"weapon_shot"
const WEAPON_SWING := &"weapon_swing"
const WEAPON_LAUNCH := &"weapon_launch"
const WEAPON_BEAM := &"weapon_beam"
const WEAPON_THROW := &"weapon_throw"
const UI_CLICK := &"ui_click"
const UI_DENY := &"ui_deny"

var manager: DotAudioManager = null

## path -> AudioStream, the taunts loaded so far.
var _taunts: Dictionary = {}


static func ids() -> Array[StringName]:
	return [
		HIDE, SEEK, COUNTDOWN, PROP_FOUND, HUNTER_DOWN, YOU_ARE_OUT, ROUND_WON, ROUND_LOST,
		DISGUISE, REVEAL, DECOY, WEAPON_SHOT, WEAPON_SWING, WEAPON_LAUNCH, WEAPON_BEAM,
		WEAPON_THROW, UI_CLICK, UI_DENY,
	]


static func sound_catalogue() -> DotAudioCatalogue:
	var c := DotAudioCatalogue.new()

	c.add(_flat(HIDE, &"UI", 1, 85))
	c.add(_flat(SEEK, &"UI", 1, 90))
	var beep := _flat(COUNTDOWN, &"UI", 1, 70)
	beep.cooldown_ms = 400
	c.add(beep)
	c.add(_placed(PROP_FOUND, 60.0, 10.0, 3, 70, 0.95, 1.05))
	c.add(_placed(HUNTER_DOWN, 60.0, 10.0, 3, 70, 0.95, 1.05))
	c.add(_flat(YOU_ARE_OUT, &"SFX", 1, 100))
	c.add(_flat(ROUND_WON, &"UI", 1, 80))
	c.add(_flat(ROUND_LOST, &"UI", 1, 80))
	c.add(_placed(DISGUISE, 18.0, 4.0, 3, 50, 0.9, 1.1))
	c.add(_placed(REVEAL, 18.0, 4.0, 3, 50, 0.9, 1.1))
	var decoy := _flat(DECOY, &"SFX", 1, 75)
	decoy.cooldown_ms = 120
	c.add(decoy)

	var shot := _placed(WEAPON_SHOT, 110.0, 14.0, 3, 80, 0.94, 1.06)
	shot.tags = [&"weapon"]
	c.add(shot)
	var swing := _placed(WEAPON_SWING, 30.0, 6.0, 2, 55, 0.9, 1.1)
	swing.tags = [&"weapon"]
	c.add(swing)
	var launch := _placed(WEAPON_LAUNCH, 140.0, 16.0, 2, 82, 0.95, 1.05)
	launch.tags = [&"weapon"]
	c.add(launch)
	var beam := _placed(WEAPON_BEAM, 90.0, 12.0, 1, 75, 1.0, 1.0)
	beam.cooldown_ms = 180
	beam.tags = [&"weapon"]
	c.add(beam)
	var throw := _placed(WEAPON_THROW, 40.0, 8.0, 2, 55, 0.95, 1.05)
	throw.tags = [&"weapon"]
	c.add(throw)

	var click := _flat(UI_CLICK, &"UI", 2, 60)
	click.cooldown_ms = 60
	c.add(click)
	var deny := _flat(UI_DENY, &"UI", 1, 60)
	deny.cooldown_ms = 250
	c.add(deny)
	return c


static func sound_recipes() -> Dictionary:
	return {
		HIDE: DotAudioSynth.Voice.SPAWN,
		SEEK: DotAudioSynth.Voice.SHOT_HEAVY,
		COUNTDOWN: DotAudioSynth.Voice.BLIP,
		PROP_FOUND: DotAudioSynth.Voice.HURT,
		HUNTER_DOWN: DotAudioSynth.Voice.HURT,
		YOU_ARE_OUT: DotAudioSynth.Voice.DIE,
		ROUND_WON: DotAudioSynth.Voice.PICKUP,
		ROUND_LOST: DotAudioSynth.Voice.DENY,
		# Becoming something is arriving as it: an upward sweep. A click (the first choice) is
		# 30 ms long, which tools/audio_probe refuses as too short to be heard as a cue.
		DISGUISE: DotAudioSynth.Voice.SPAWN,
		REVEAL: DotAudioSynth.Voice.PICKUP,
		DECOY: DotAudioSynth.Voice.HURT,
		WEAPON_SHOT: DotAudioSynth.Voice.SHOT,
		WEAPON_SWING: DotAudioSynth.Voice.STEP,
		WEAPON_LAUNCH: DotAudioSynth.Voice.SHOT_HEAVY,
		WEAPON_BEAM: DotAudioSynth.Voice.SHOT_TIGHT,
		WEAPON_THROW: DotAudioSynth.Voice.CLICK,
		UI_CLICK: DotAudioSynth.Voice.CLICK,
		UI_DENY: DotAudioSynth.Voice.DENY,
	}


static func weapon_sound(kind: int) -> StringName:
	match kind:
		ZeeWeaponNet.KIND_SHOT:
			return WEAPON_SHOT
		ZeeWeaponNet.KIND_SWING:
			return WEAPON_SWING
		ZeeWeaponNet.KIND_SPAWN:
			return WEAPON_LAUNCH
		ZeeWeaponNet.KIND_BEAM:
			return WEAPON_BEAM
		ZeeWeaponNet.KIND_THROW:
			return WEAPON_THROW
		_:
			return &""


static func _placed(
	id: StringName, max_distance: float, unit_size: float, concurrent: int, priority: int,
	pitch_min: float, pitch_max: float
) -> DotAudioDef:
	var def := DotAudioDef.new()
	def.id = id
	def.path = "%s/%s.ogg" % [SOUND_DIR, String(id)]
	def.kind = DotAudioDef.Kind.POSITIONAL_3D
	def.bus = &"SFX"
	def.max_distance = max_distance
	def.unit_size = unit_size
	def.max_concurrent = concurrent
	def.priority = priority
	def.pitch_min = pitch_min
	def.pitch_max = pitch_max
	return def


static func _flat(id: StringName, bus: StringName, concurrent: int, priority: int) -> DotAudioDef:
	var def := DotAudioDef.new()
	def.id = id
	def.path = "%s/%s.ogg" % [SOUND_DIR, String(id)]
	def.bus = bus
	def.max_concurrent = concurrent
	def.priority = priority
	return def


func setup() -> DotResult:
	manager = DotAudioManager.new()
	manager.name = "Audio"
	manager.catalogue = sound_catalogue()
	manager.mixer = DotAudioMixer.new()
	manager.register_as_service = false
	manager.voices = 24
	add_child(manager)

	var ready_now := manager.setup()

	if not ready_now.ok:
		return ready_now.wrap("prophunt audio")

	var godot_sink := manager.sink as DotAudioSinkGodot

	if godot_sink != null:
		godot_sink.bank = DotAudioSynth.bank(manager.catalogue, sound_recipes())
		DotLog.info(CHANNEL, "no audio files; synthesised stand-ins are in use", {
			"ids": sound_recipes().size(), "dir": SOUND_DIR,
		})

	return DotResult.success(null)


func listen_from(at: Vector3) -> void:
	if manager != null:
		manager.listener_position = at


## A taunt from [param from], which it follows. [param sound] is the path in the taunt list,
## relative to this game's root; [param range_metres] is how far it carries. Returns the player
## made, or null when there was nothing to play.
func taunt(from: Node3D, sound: String, range_metres: float) -> AudioStreamPlayer3D:
	if from == null or sound == "":
		return null

	var stream := _taunt_stream(sound)

	if stream == null:
		return null

	var voice := AudioStreamPlayer3D.new()
	voice.name = "Taunt"
	voice.stream = stream
	voice.bus = &"SFX"
	voice.max_distance = range_metres
	voice.unit_size = range_metres * 0.18
	voice.position = Vector3(0.0, 0.6, 0.0)
	from.add_child(voice)
	voice.finished.connect(voice.queue_free)

	if voice.is_inside_tree():
		voice.play()

	return voice


func _taunt_stream(sound: String) -> AudioStream:
	if _taunts.has(sound):
		return _taunts[sound]

	var path := PhPaths.rebase("res://" + sound.trim_prefix("res://"))
	var stream: AudioStream = load(path) as AudioStream if ResourceLoader.exists(path) else null

	if stream == null:
		DotLog.warn(CHANNEL, "a taunt's sound is missing", {"path": path})

	_taunts[sound] = stream
	return stream


func on_hide() -> bool:
	return _flat_play(HIDE)


func on_seek() -> bool:
	return _flat_play(SEEK)


func on_countdown() -> bool:
	return _flat_play(COUNTDOWN)


func on_death(at: Vector3, mine: bool, was_hunter: bool) -> bool:
	if mine:
		return _flat_play(YOU_ARE_OUT)

	return _at(HUNTER_DOWN if was_hunter else PROP_FOUND, at)


func on_round_end(won: bool) -> bool:
	return _flat_play(ROUND_WON if won else ROUND_LOST)


func on_disguise(at: Vector3, revealed: bool) -> bool:
	return _at(REVEAL if revealed else DISGUISE, at)


func on_decoy() -> bool:
	return _flat_play(DECOY)


func on_weapon(at: Vector3, kind: int) -> bool:
	var id := weapon_sound(kind)
	return _at(id, at) if id != &"" else false


func click() -> bool:
	return _flat_play(UI_CLICK)


func deny() -> bool:
	return _flat_play(UI_DENY)


func _at(id: StringName, at: Vector3, volume: float = 1.0) -> bool:
	return manager != null and manager.play_at(id, at, volume) != 0


func _flat_play(id: StringName) -> bool:
	return manager != null and manager.play(id) != 0


func describe() -> Dictionary:
	return {
		"ids": ids().size(),
		"taunts_loaded": _taunts.size(),
		"device": manager != null and manager.sink is DotAudioSinkGodot,
	}
