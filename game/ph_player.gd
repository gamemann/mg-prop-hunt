extends CharacterBody3D

const PhConfig := preload("ph_config.gd")
const PhController := preload("ph_controller.gd")
const PhFigure := preload("ph_figure.gd")
const PhAvatars := preload("ph_avatars.gd")
const PhProps := preload("ph_props.gd")

## One person: how they move, which side they are on, and — on the props' side — what they are
## hiding as.
##
## [b]A disguise changes the hull, on both ends, from one replicated value.[/b] A player who
## becomes a sofa is swept as a squat capsule half the sofa's depth across; one who becomes a
## bottle as the smallest capsule the rules allow. [method apply_disguise] writes those
## numbers into the controller's own tunables in place — the motor holds them by reference and
## reads them every sweep — and it is called on the server when the disguise is decided and on
## every client when the DISGUISE event says so, from [DotPropDisguise.hull] over the same size.
## So a predicting client sweeps exactly the capsule the server does, which is the whole of
## what keeps a sofa from being corrected on every step.
##
## [b]The hitbox is the prop's box, not the hull.[/b] A hunter shoots what they can see, and a
## sofa's picture is two metres across where its hull is under one. [method _fit_hitboxes]
## turns one box to the prop's turn every tick on the server, which is where shots resolve.

## Metres above a player's feet that their eyes are, in their own body.
const EYE_HEIGHT := 1.6

## A player's own body hull, in metres: the family's.
const BODY_RADIUS := 0.35
const BODY_HEIGHT := 1.8
const BODY_CROUCH := 0.95
const BODY_STEP := 0.4

@export var player_id: StringName = &"local"
@export var display_name: String = "Player"
@export var samples_input: bool = false
@export var is_bot: bool = false

## What this player looks like, as a dot-user-avatar document; null is the stock person.
var avatar: DotAvatar = null

var config: PhConfig = null
var catalogue: PhProps = null
var rules: DotPropDisguiseRules = null

var controller: PhController = null
var sampler: DotFpsSampler = null
var health: DotHealth = null
var hitboxes: DotHitboxSet = null

## A hunter's weapons. Null on a prop.
var weapons: ZeeWeaponRig = null

## Which side they are on this round: [constant PhGame.PROPS] or [constant PhGame.HUNTERS].
var team: int = 0

## Which side they asked for: 0 either, or a side. Server side; read by the draw.
var side_wish: int = 0

var points: int = 0
var ping_ms: int = -1
var entity_id: int = 0

## How many times the server has PUT this player somewhere. Replicated, so a watcher's
## interpolator draws a teleport as one rather than as a flight across the map.
var warps: int = 0

## Sitting this round out, having joined after it started.
var watching: bool = false

## What they are hiding as. Empty: their own body.
var disguise: DotPropDisguise = DotPropDisguise.new()

## The disguise they took off to show their face, kept so the same key puts it back on.
var set_aside: DotPropDisguise = null

## When they last showed their face, and when they may next; simulated seconds. Server side.
var revealed_at: float = -1.0
var reveal_ready_at: float = 0.0

## Points-worth of seconds earned showing their face since the last reveal. Server side.
var reveal_paid: float = 0.0

## Seconds before they may show their face again. Kept by the server, replicated to the owner.
var reveal_wait: float = 0.0

## How full the forced-taunt meter is, 0..1. Server side, replicated to the owner.
var taunt_meter: float = 0.0

## Whether a taunt is playing from them now, which one, and since when. For the drawn mouth.
var taunting_id: StringName = &""

## Whether the rule that gives the last props away has marked them. Server side; replicated
## with an admin's beacon as one flag.
var marked: bool = false

## An administrator's `blind` and `beacon`.
var blinded: bool = false
var beacon: bool = false

var beacon_marker: DotFxBeacon = null

## What other people see this player as: a person, or a prop. Client side.
var figure: PhFigure = null
var prop_model: Node3D = null
var _drawn_prop: StringName = &""

## Which weapon slot they have asked for, from this game's input message.
var wanted_slot: int = 0

## Remote weapon state, for drawing a gun in a watched hunter's hand. See mg-deathrun.
var mirrored: bool = false
var dealt: Array[StringName] = []
var dealt_round: int = -1
var mirror_slot: int = 0
var mirror_switching: bool = false
var mirror_fired: int = 0
var mirror_fire_kind: int = 0
var _seen_fire_seq: int = -1
static var _slots: Dictionary = {}

var tick_rate: int = 64:
	set(value):
		tick_rate = value
		if controller != null:
			controller.tick_rate = value

## The key dot-weapon's player bridge identifies this carrier by.
var player_key: String:
	get:
		return String(player_id)


func _ready() -> void:
	controller = PhController.new()
	controller.name = "Controller"
	controller.tick_rate = tick_rate
	# EXTERNAL even offline: the world owns the tick, which is the shape a dedicated server
	# needs and the one a predicting client replays.
	controller.drive = DotFpsController.Drive.EXTERNAL
	controller.tunables = tunables_for(config)
	controller.admin_abilities = true
	add_child(controller)

	if samples_input:
		sampler = DotFpsSampler.new(controller.tunables)
		register_actions(sampler)


## How a player moves in their own body. Static: a connected client builds a sampler before it
## has a player, and the two must agree.
static func tunables_for(config: PhConfig) -> DotFpsTunables:
	var t := DotFpsTunables.new()
	t.max_speed = config.run_speed if config != null else 6.5
	t.gravity = config.gravity if config != null else 20.0
	t.jump_height = config.jump_height if config != null else 1.15
	t.auto_hop = config.auto_bunny_hop if config != null else false
	t.walk_speed_scale = config.walk_speed_scale if config != null else 0.45
	t.can_walk = true
	t.can_sprint = false
	t.can_crouch = true
	t.crouch_speed_scale = 0.45
	t.accelerate = 10.0
	t.friction = 6.0
	t.stop_speed = 2.5
	t.air_accelerate = config.air_accelerate if config != null else 20.0
	t.max_air_wish_speed = 1.2
	t.coyote_time = 0.1
	t.jump_buffer_time = 0.12
	t.max_slope_angle = 46.0
	t.radius = BODY_RADIUS
	t.stand_height = BODY_HEIGHT
	t.crouch_height = BODY_CROUCH
	t.step_height = BODY_STEP
	return t


## The movement actions, and the slow walk on shift.
static func register_actions(p_sampler: DotFpsSampler = null) -> void:
	var _added := DotFpsSampler.register_default_actions(p_sampler)
	var walk := &"dot_fps_walk"

	if not InputMap.has_action(walk):
		return

	for event in InputMap.action_get_events(walk):
		var key := event as InputEventKey
		if key != null and key.physical_keycode == KEY_SHIFT:
			return

	var shift := InputEventKey.new()
	shift.physical_keycode = KEY_SHIFT
	InputMap.action_add_event(walk, shift)


## One simulated tick. On the server and offline; a client predicts through its behaviour.
func simulate(tick: int, delta: float) -> void:
	if sampler != null:
		controller.apply_command(sampler.sample(delta))

	controller.simulate_tick(tick, delta)
	global_position = controller.state.position


func delta_for_tick() -> float:
	return 1.0 / float(maxi(tick_rate, 1))


# --- The disguise ----------------------------------------------------------

func is_disguised() -> bool:
	return disguise != null and disguise.is_disguised()


## Wears [param next] — or their own body, for an empty one — and moves the hull to match.
##
## [b]The hull is written into the live tunables, not swapped for new ones.[/b] The motor holds
## the tunables it was built with by reference and reads the radius and height on every sweep,
## so writing the numbers in place takes effect on the next tick without rebuilding anything;
## a new tunables object would need the motor rebuilt, and a rebuild mid-round resets the
## state a predicting client is replaying.
func apply_disguise(next: DotPropDisguise) -> void:
	disguise = next if next != null else DotPropDisguise.new()

	var t := controller.tunables if controller != null else null

	if t == null:
		return

	if disguise.is_disguised() and rules != null:
		var hull := DotPropDisguise.hull(disguise.size, rules)
		t.radius = hull.x
		t.stand_height = hull.y
		# A prop does not crouch: it is the height it is. The crouch height equal to the stand
		# height is what tells the motor so, and keeps validate() happy (never shorter than
		# twice the radius).
		t.crouch_height = hull.y
		# A step under the hull's own height, or a bottle steps up onto a table.
		t.step_height = minf(BODY_STEP, hull.y * 0.45)
		t.can_crouch = false
	else:
		t.radius = BODY_RADIUS
		t.stand_height = BODY_HEIGHT
		t.crouch_height = BODY_CROUCH
		t.step_height = BODY_STEP
		t.can_crouch = true

	if body_ready():
		_fit_hitboxes()


## The hull's height now: a prop's, or a person's.
func hull_height() -> float:
	return controller.tunables.stand_height if controller != null else BODY_HEIGHT


func body_ready() -> bool:
	return hitboxes != null and is_instance_valid(hitboxes)


## Where this player's eyes are: a person's, or the middle-top of the prop they are.
func eye_position() -> Vector3:
	var height := EYE_HEIGHT

	if is_disguised():
		height = clampf(disguise.size.y * 0.8, 0.2, 2.0)

	return controller.state.position + Vector3(0.0, height, 0.0)


## Which way they are looking, as a unit vector. From yaw and pitch, never a camera.
func aim_direction() -> Vector3:
	var view := Basis.from_euler(Vector3(
		deg_to_rad(controller.state.pitch), deg_to_rad(controller.state.yaw), 0.0
	))
	return -view.z


## The way the prop they are faces: their view, or what it was locked at.
func prop_basis() -> Basis:
	return disguise.hit_basis(controller.state.yaw if controller != null else 0.0)


## The hitboxes: a person's capsule and head, or one box the prop's size, turned.
func build_hitboxes(combat: DotCombatManager) -> void:
	hitboxes = DotHitboxSet.new()
	hitboxes.name = "Hitboxes"
	hitboxes.owner_ref = DotNodeRef.of_path(^"..")
	add_child(hitboxes)

	var chest := DotHitbox.new()
	chest.name = "Chest"
	chest.group = DotHitGroup.CHEST
	chest.shape = DotHitbox.Shape.CAPSULE
	chest.radius = 0.34
	chest.height = 1.25
	chest.position = Vector3(0.0, 0.78, 0.0)
	hitboxes.add_child(chest)

	var head := DotHitbox.new()
	head.name = "Head"
	head.group = DotHitGroup.HEAD
	head.shape = DotHitbox.Shape.SPHERE
	head.radius = 0.19
	head.position = Vector3(0.0, EYE_HEIGHT + 0.06, 0.0)
	head.damage_scale = 2.0
	head.precedence = 10
	hitboxes.add_child(head)

	var prop := DotHitbox.new()
	prop.name = "Prop"
	prop.group = DotHitGroup.CHEST
	prop.shape = DotHitbox.Shape.BOX
	prop.enabled = false
	hitboxes.add_child(prop)

	hitboxes.refresh()
	hitboxes.register_with(combat, entity_id)
	_fit_hitboxes()


## Turns the hitboxes to whoever this player is now. Every tick on the server.
##
## [b]A prop has no head.[/b] Every hit on a prop is the same hit, which is what makes a small
## prop survivable at all; a headshot multiplier on a bottle is a bottle that dies to a pistol.
func _fit_hitboxes() -> void:
	if not body_ready():
		return

	var disguised := is_disguised()
	var chest := hitboxes.get_node_or_null(^"Chest") as DotHitbox
	var head := hitboxes.get_node_or_null(^"Head") as DotHitbox
	var prop := hitboxes.get_node_or_null(^"Prop") as DotHitbox

	if chest != null:
		chest.enabled = not disguised
	if head != null:
		head.enabled = not disguised

	if prop != null:
		prop.enabled = disguised

		if disguised:
			var size := disguise.size
			var turn := prop_basis()
			prop.half_extents = size * 0.5
			prop.transform = Transform3D(turn, turn * Vector3(0.0, size.y * 0.5, 0.0))
			hitboxes.bounds_offset = Vector3(0.0, size.y * 0.5, 0.0)
			hitboxes.bounds_radius = maxf(size.length() * 0.6, 0.5)
		else:
			hitboxes.bounds_offset = Vector3(0.0, 0.9, 0.0)
			hitboxes.bounds_radius = 1.5


## Every tick on the authority: the prop's hitbox follows the view while it is not locked.
func refit() -> void:
	if is_disguised() and not disguise.locked:
		_fit_hitboxes()


# --- The rest of a body ----------------------------------------------------

## The duck-typed lookup dot-weapon's player bridge asks a carrier for.
func component(type_name: StringName) -> Object:
	match String(type_name):
		"DotPlayerController", "DotFpsController":
			return controller
		"DotHealth":
			return health
		"ZeeWeaponRig":
			return weapons
		_:
			return null


## Puts a player somewhere, facing somewhere, with nothing carried over.
func place_at(at: Vector3, yaw_degrees: float) -> void:
	warps += 1
	global_position = at
	controller.teleport(at, yaw_degrees, 0.0)

	if sampler != null:
		sampler.look_at_angles(yaw_degrees, 0.0)

	var facing := DotFpsCommand.new()
	facing.yaw = yaw_degrees
	controller.apply_command(facing)


## Back to the start of a round: their own body, nothing set aside, nothing marked.
func reset_round() -> void:
	watching = false
	set_aside = null
	revealed_at = -1.0
	reveal_ready_at = 0.0
	reveal_paid = 0.0
	taunt_meter = 0.0
	taunting_id = &""
	marked = false
	apply_disguise(DotPropDisguise.new())


func retune() -> void:
	if controller == null:
		return

	var held := disguise
	controller.tunables = tunables_for(config)

	if sampler != null:
		sampler.tunables = controller.tunables

	apply_disguise(held)


func is_alive() -> bool:
	return health == null or health.alive


# --- Drawing (client side) --------------------------------------------------

## Draws the beacon at [param at], from the admin's flag or the rule's. Returns whether it
## pinged.
func present_beacon(delta: float, at: Vector3, local_view: bool, period: float) -> bool:
	if not (beacon or marked) or not is_alive():
		if beacon_marker != null:
			beacon_marker.queue_free()
			beacon_marker = null
		return false

	if beacon_marker == null:
		beacon_marker = DotFxBeacon.new()
		beacon_marker.name = "Beacon"
		beacon_marker.period = period
		# The rule's marker is the props' blue, so it reads as "a prop is here" and not as an
		# admin's punishment; an admin's is the family's magenta.
		beacon_marker.colour = Color(0.98, 0.22, 0.86) if beacon else Color(0.35, 0.7, 1.0)
		beacon_marker.column_base = maxf(hull_height(), 0.6) + 0.4
		add_child(beacon_marker)

	beacon_marker.local_view = local_view
	beacon_marker.global_position = at
	return beacon_marker.advance(delta)


## Draws this player for one frame at [param at]: their own body, or the prop they are, or
## nothing. Returns whether anything was shown.
func present_body(hidden: bool, at: Vector3, team_colour: Color) -> bool:
	var alive := is_alive()
	var as_prop := is_disguised() and alive

	if as_prop:
		if figure != null:
			figure.visible = false
		_present_prop(not hidden, at)
		return not hidden

	if prop_model != null:
		prop_model.visible = false

	var shown := not hidden and alive

	if figure == null:
		if not shown:
			return false
		figure = PhFigure.new()
		figure.name = "Figure"
		add_child(figure)

	var atlas := _atlas()

	if figure.atlas != atlas or not figure.team_colour.is_equal_approx(team_colour):
		figure.build(BODY_HEIGHT, atlas, team_colour)

	figure.visible = shown

	if shown:
		_present_held()
		var velocity := controller.state.velocity
		figure.pose(at, deg_to_rad(controller.state.yaw), Vector2(velocity.x, velocity.z).length())

	return shown


func _present_prop(shown: bool, at: Vector3) -> void:
	if catalogue == null:
		return

	if prop_model == null or _drawn_prop != disguise.prop_id:
		if prop_model != null:
			prop_model.queue_free()
		prop_model = catalogue.instance(disguise.prop_id)
		prop_model.top_level = true
		add_child(prop_model)
		_drawn_prop = disguise.prop_id

	prop_model.visible = shown

	if shown:
		prop_model.global_transform = Transform3D(prop_basis(), at)


## Breaks this player's body apart: a hunter killed by the furniture. Client side.
func break_body(break_rules: DotPlayerBreakRules, direction: Vector3, seed_value: int) -> DotPlayerBodyBreak:
	if figure == null or not figure.visible or break_rules == null:
		return null

	var model := figure.body_node()

	if model == null:
		return null

	return DotPlayerBodyBreak.break_apart(
		model, get_parent(), break_rules, figure.global_position, direction, seed_value, true, true
	)


func note_dealt(weapon_id: StringName, round_number: int) -> void:
	if round_number != dealt_round:
		dealt.clear()
		dealt_round = round_number

	if not dealt.has(weapon_id):
		dealt.append(weapon_id)


func _present_held() -> void:
	var rig := _rig()
	var id := &""
	var switching := false
	var fired := 0
	var kind := 0

	if rig != null and rig.arsenal != null:
		var def := rig.arsenal.current_def()
		id = def.id if def != null else &""
		switching = rig.arsenal.is_switching()
		var seq := rig.fire_seq % ZeeWeaponNet.FIRE_SEQ_WRAP
		fired = ZeeWeaponNet.uses_between(_seen_fire_seq, seq) if _seen_fire_seq >= 0 else 0
		_seen_fire_seq = seq
		kind = rig.fire_kind
	elif mirrored:
		id = held_by_slot(dealt, mirror_slot)
		switching = mirror_switching
		fired = mirror_fired
		kind = mirror_fire_kind

	mirror_fired = 0
	figure.hold(id, switching)
	figure.fired(fired, kind)


static func held_by_slot(ids: Array[StringName], slot: int) -> StringName:
	if slot <= 0 or ids.is_empty():
		return &""

	if _slots.is_empty():
		for def in ZeeWeaponPack.weapons():
			_slots[def.id] = def.slot

	for id in ids:
		if int(_slots.get(id, -1)) == slot:
			return id

	return &""


func _rig() -> ZeeWeaponRig:
	if weapons != null:
		return weapons

	return get_node_or_null(^"Weapons") as ZeeWeaponRig


func _atlas() -> String:
	var index := PhAvatars.skin_index(avatar)

	if index < 0 or index >= PhFigure.ATLASES.size():
		index = PhAvatars.stock_index(player_id)

	return str(PhFigure.ATLASES[index])


func describe() -> Dictionary:
	return {
		"id": String(player_id),
		"side": team,
		"alive": is_alive(),
		"health": health.health if health != null else 0.0,
		"disguise": disguise.describe(),
		"watching": watching,
		"armed": weapons != null,
		"marked": marked,
		"blinded": blinded,
		"beacon": beacon,
		"points": points,
	}
