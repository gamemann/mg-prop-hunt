extends Node3D

const PhCatalogue := preload("ph_catalogue.gd")
const PhConfig := preload("ph_config.gd")
const PhMap := preload("ph_map.gd")
const PhMapDoc := preload("ph_map_doc.gd")
const PhPaths := preload("ph_paths.gd")
const PhPlayer := preload("ph_player.gd")
const PhProgress := preload("ph_progress.gd")
const PhProps := preload("ph_props.gd")
const PhRules := preload("ph_rules.gd")
const PhSpectate := preload("ph_spectate.gd")
const PhController := preload("ph_controller.gd")

## The simulation. Headless, authoritative, and the only thing that decides anything.
##
## [b]A round is hiding and then seeking.[/b] At the top of each round some players are drawn
## as hunters and everybody else is a prop. For [member PhConfig.hide_seconds] the props run off
## and turn into furniture while the hunters stand blindfolded and held where they started.
## Then the hunters are let go, armed, to find them: every prop shot is out, and so is any
## hunter who shoots enough of the real furniture. Every prop found is the hunters' round; any
## prop still standing when the clock runs out is the props'.
##
## [b]What it owns and what it borrows.[/b] The round, the sides and the scoreboard are
## dot-match's (decided through [PhRules]); who becomes a hunter is dot-team's
## [DotTeamRotation]; what a disguise is and what it costs is dot-props' [DotPropDisguise] and
## its taunts are [DotPropTaunts]; health and shots are dot-combat's; the weapons are
## zee-dot-weapons'. The map, the furniture and the rules of this game are its own.

const CHANNEL := "ph.game"

## Where this world publishes itself, so a module can find it. A registry name and not an
## autoload: a server and a client in one process are two of these.
const SERVICE := &"ph_game"

## Snapshots a second. What a hunter reads continuously is a prop moving across a room.
const NET_SNAPSHOT_RATE := 30

## How far a position may be from the origin, in metres, on the wire. Both ends read it here.
const NET_WORLD_EXTENT := 512.0

## The two sides. Fixed ids, because the whole game is about which of the two somebody is.
const PROPS := 1
const HUNTERS := 2

const TEAM_COLOURS: Array[Color] = [
	Color(0.30, 0.58, 0.96),
	Color(0.97, 0.56, 0.16),
]

const TEAM_NAMES: Array[String] = ["Props", "Hunters"]

## Which part of the round it is.
enum Phase {
	## Between rounds, or waiting for enough people.
	IDLE,
	## The props hide; the hunters are blindfolded and held still.
	HIDE,
	## The hunters are let go.
	SEEK,
}

const DIED_SHOT := &"shot"
const DIED_DECOY := &"decoy"
const DIED_FELL := &"fell"

## What a turn request asks of a disguise.
enum Turn { LOCK, TILT_FORWARD, TILT_BACK, TILT_LEFT, TILT_RIGHT, STRAIGHTEN }

signal player_added(player_id: StringName)
signal player_removed(player_id: StringName)
signal round_began(number: int, map_id: StringName)
signal world_clearing()
signal world_rebuilt()
signal round_over(number: int, winner: int, winner_name: String)
signal phase_changed(phase: int)
signal side_changed(player_id: StringName, side: int)
signal player_died(player_id: StringName, by: StringName, why: StringName)

## Somebody's disguise changed: a new prop, their own face, a turn, a lock.
signal disguise_changed(player_id: StringName)

## Somebody taunted: [param taunt_id] from the taunt list, forced or chosen.
signal taunted(player_id: StringName, taunt_id: StringName, forced: bool)

## Something a player asked for was refused, and why. Told to them alone.
signal refused(player_id: StringName, why: String)

## A hunter shot the furniture and paid for it.
signal decoy_hit(player_id: StringName, amount: float)

signal achievement_earned(player_id: StringName, title: String, points: int)
signal player_armed(player_id: StringName, weapon_id: StringName)

@export var config: PhConfig = null
@export var authoritative: bool = true
@export_range(1, 240, 1) var tick_rate: int = 64
@export var external_tick: bool = false
@export var register_service: bool = true

## Whether the map is drawn. A client sets it.
@export var draw_world: bool = false

var map: PhMap = null
var catalogue: PhCatalogue = null
var props_catalogue: PhProps = null
var combat: DotCombatManager = null
var match_node: DotMatch = null
var random: DotRandomManager = null
var physics: DotPhysicsLayout = null
var effects: DotFxManager = null
var spectate: PhSpectate = null
var progress: PhProgress = null
var taunts: DotPropTaunts = null
var rules: DotPropDisguiseRules = null

## player id -> PhPlayer.
var players: Dictionary = {}

## player id -> side.
var sides: Dictionary = {}

## The map the next round plays, set by the players' vote or an operator, used once.
var next_map_id: StringName = &""

var round_number: int = 0

## Seconds into the current phase, and into the seeking. Simulated, never a wall clock.
var phase_elapsed: float = 0.0
var seek_elapsed: float = 0.0

var phase: int = Phase.IDLE

## The map this round is played on.
var map_doc: Dictionary = {}

var entities := DotEntityTable.new()

## What the server last said about numbers a client cannot count. Negative is "count it".
var remote_props: int = -1
var remote_hunters: int = -1
var remote_playable: bool = false

## Who has had the hunters' role, for [DotTeamRotation].
var hunter_history: Dictionary = {}

var _tick: int = 0
var _round_seed: int = 0
var _rounds_on_map: int = 0
var _map_unplayed: bool = false
var _decided: bool = false
var _winner: int = 0
var _winner_name: String = ""

## Bots: player id -> what they are doing. See [method _drive_bots].
var _bot: Dictionary = {}


func _ready() -> void:
	if config == null:
		config = PhConfig.new()

	var valid := config.validate()

	if not valid.ok:
		DotLog.error(CHANNEL, "the configuration is not usable", {"why": valid.error.message})
		return

	_round_seed = config.seed_value
	rules = config.disguise_rules()

	_build_physics()
	_apply_gravity()
	_build_random()
	_build_props()
	_build_map()
	_build_combat()
	_build_effects()
	_build_match()
	_build_spectate()
	_build_progress()
	_build_taunts()

	if authoritative:
		catalogue = PhCatalogue.new()
		var _loaded := catalogue.load_from(config.map_directory)
		# Laid out now, not on the first round: a warmup on an empty world is
		# indistinguishable from a map that failed to load.
		_lay_out_map()

	if register_service:
		DotRegistry.register(SERVICE, self)

	DotLog.info(CHANNEL, "world ready", config.describe())


func _exit_tree() -> void:
	if register_service:
		DotRegistry.unregister_instance(SERVICE, self)


# --- Building ---------------------------------------------------------------

## Three layers: the building, the people, and the furniture.
##
## [b]People do not collide with people.[/b] Two players shoving is a race decided by who
## walked into whom, drawn in the past on every client; a hunter walks through a prop who is
## another player, which is a tell the genre has always had in one form or another, and a far
## smaller one than a hunter stuck against an invisible sofa they cannot see is a person.
func _build_physics() -> void:
	physics = DotPhysicsLayout.custom(&"prophunt", [&"world", &"player", &"prop"])

	for layer in physics.layers:
		match layer.id:
			&"player":
				layer.collides_with = [&"world", &"prop"]
			_:
				layer.collides_with = [&"player"]

	var built := physics.build()

	if not built.ok:
		DotLog.error(CHANNEL, "the collision layout would not build", {"why": built.error.message})
		physics = null


## The gravity the movement is tuned against, on this world's own physics SPACE: a project
## setting does not travel with a delivered pack.
func _apply_gravity() -> void:
	var world := get_world_3d()

	if world == null:
		return

	PhysicsServer3D.area_set_param(world.space, PhysicsServer3D.AREA_PARAM_GRAVITY, config.gravity)


func _build_random() -> void:
	random = DotRandomManager.new()
	random.name = "Random"
	random.register_as_service = false
	add_child(random)
	var _started := random.setup()
	random.reseed(_round_seed)


func _build_props() -> void:
	props_catalogue = PhProps.new()
	var count := props_catalogue.load_file()

	if count == 0:
		DotLog.error(CHANNEL, "no props: nobody can hide as anything", {})


func _build_map() -> void:
	map = PhMap.new()
	map.name = "Map"
	map.physics = physics
	map.catalogue = props_catalogue
	map.draw_world = draw_world
	add_child(map)


func _build_combat() -> void:
	combat = DotCombatManager.new()
	combat.name = "Combat"
	combat.is_authority = authoritative
	combat.register_service = false

	var damage_rules := DotDamageRules.new()
	damage_rules.friendly_fire = false
	damage_rules.self_damage = true
	damage_rules.hit_groups = true
	combat.rules = damage_rules

	var settings := DotCombatConfig.new()
	settings.lag_compensation = false
	combat.config = settings

	# A shot stops on a wall AND on a piece of furniture: the furniture is what a hunter is
	# shooting at, and a shot through a sofa would be a shot that cannot cost anybody anything.
	var trace := DotTracePhysics.for_world(get_world_3d())

	if physics != null:
		trace.collision_mask = physics.layer_mask(&"world") | physics.layer_mask(&"prop")

	combat.trace = trace
	combat.resolver = DotDamageResolver.with_rules(damage_rules)
	combat.resolver.hit_groups = DotHitGroup.defaults()
	combat.resolver.team_of = func(entity_id: int) -> int:
		return team_of(entities.key_for_id(entity_id))

	add_child(combat)


func _build_effects() -> void:
	if authoritative and not draw_world:
		return

	var fx := DotFxCatalogue.new()

	var go := DotFxDef.new()
	go.id = &"go"
	go.kind = DotFxDef.Kind.SCREEN
	go.flash_peak = 0.18
	go.flash_colour = Color(0.98, 0.86, 0.35, 1.0)
	go.flash_decay_ms = 380
	fx.add(go)

	var hurt := DotFxDef.new()
	hurt.id = &"hurt"
	hurt.kind = DotFxDef.Kind.SCREEN
	hurt.flash_peak = 0.3
	hurt.flash_colour = Color(0.9, 0.1, 0.1, 1.0)
	hurt.flash_decay_ms = 260
	fx.add(hurt)

	effects = DotFxManager.new()
	effects.name = "Effects"
	effects.catalogue = fx
	effects.config = DotFxConfig.new()
	effects.register_as_service = false
	add_child(effects)
	DotLog.result(CHANNEL, "the effects layer", effects.setup())


func _build_match() -> void:
	match_node = DotMatch.new()
	match_node.name = "Match"
	match_node.register_service = false

	var match_config := DotMatchConfig.new()
	match_config.tick_rate = tick_rate
	match_config.auto_start = false
	match_config.log_transitions = false
	# Off: the sides are this game's to draw (see [method _draw_sides]).
	match_config.balance_between_rounds = false
	match_node.config = match_config

	var match_rules: DotMatchRules = PhRules.make()
	match_rules.intermission_sec = config.intermission_seconds
	match_rules.warmup_sec = config.warmup_seconds
	match_rules.countdown_sec = 0.0
	match_rules.team_based = true
	match_rules.min_players = 2
	match_rules.set(&"decision_fn", _decision)
	match_rules.time_limit_sec = config.hide_seconds + config.round_seconds + 60.0
	match_node.rules = match_rules

	# Scoped to the match node, which finds nothing: this game places its own players.
	match_node.spawns_ref = DotNodeRef.of_path(^".")
	add_child(match_node)

	match_node.round_started.connect(_on_round_started)
	match_node.round_ended.connect(_on_round_ended)

	var teams: Array[DotTeam] = [
		DotTeam.make(PROPS, TEAM_NAMES[0], TEAM_COLOURS[0]),
		DotTeam.make(HUNTERS, TEAM_NAMES[1], TEAM_COLOURS[1]),
	]
	match_node.teams.teams = teams
	match_node.teams.force_balance = false
	match_node.teams.allow_choice = false
	match_node.teams.max_difference = 0
	match_node.teams.reindex()


func _decision() -> Dictionary:
	return {"decided": _decided, "winner": _winner}


func _build_spectate() -> void:
	spectate = PhSpectate.new()
	spectate.name = "Spectate"
	spectate.players = players
	spectate.sides = sides
	spectate.phase_fn = func() -> int: return phase
	add_child(spectate)

	var ready_now := spectate.setup(authoritative, tick_rate, config.spectate_camera)

	if not ready_now.ok:
		DotLog.warn(CHANNEL, "spectating is off", {"why": ready_now.error.message})
		remove_child(spectate)
		spectate.queue_free()
		spectate = null


func _build_progress() -> void:
	if not authoritative or not config.keep_progress:
		return

	progress = PhProgress.new()
	progress.name = "Progress"
	progress.players = players
	progress.sides = sides
	add_child(progress)

	var ready_now := progress.setup(config.progress_directory, config.report_progress)

	if not ready_now.ok:
		DotLog.warn(CHANNEL, "progress is off", {"why": ready_now.error.message})
		remove_child(progress)
		progress.queue_free()
		progress = null
		return

	progress.earned.connect(func(id: StringName, title: String, points: int) -> void:
		achievement_earned.emit(id, title, points)
	)


## The taunt list, on both ends: the server decides when a taunt plays, every client plays it.
func _build_taunts() -> void:
	taunts = DotPropTaunts.new()
	taunts.auto_after = config.auto_taunt_seconds
	taunts.auto_radius = config.auto_taunt_radius
	taunts.cooldown = config.taunt_cooldown
	taunts.points_voluntary = config.taunt_points
	taunts.points_forced = config.forced_taunt_points

	var text := FileAccess.get_file_as_string(PhPaths.rebase("res://" + config.taunt_file.trim_prefix("res://")))
	var parsed: Variant = JSON.parse_string(text) if text != "" else null
	var list: Variant = (parsed as Dictionary).get("taunts", []) if parsed is Dictionary else parsed

	if list is Array:
		var _added := taunts.add_all(list)

	if taunts.order.is_empty():
		DotLog.warn(CHANNEL, "no taunts; a prop can only be found by shooting", {"file": config.taunt_file})


func taunt_ids() -> Array[StringName]:
	return taunts.order if taunts != null else ([] as Array[StringName])


# --- Players ----------------------------------------------------------------

## Puts somebody in the world. [param wanted_side] is a side, or 0 to be placed.
func add_player(
	player_id: StringName,
	display_name: String,
	wanted_side: int = 0,
	samples_input: bool = false
) -> PhPlayer:
	if players.has(player_id):
		return players[player_id]

	var side := HUNTERS if wanted_side == HUNTERS else PROPS

	var player := PhPlayer.new()
	player.name = "Player_%s" % String(player_id)
	player.player_id = player_id
	player.display_name = display_name
	player.samples_input = samples_input
	player.tick_rate = tick_rate
	player.config = config
	player.catalogue = props_catalogue
	player.rules = rules
	player.team = side
	add_child(player)

	if physics != null:
		var applied := physics.apply_to(player, &"player")

		if not applied.ok:
			DotLog.warn(CHANNEL, "a player could not be put on its collision layer", {"why": applied.error.message})

		player.controller.set_collision_mask(physics.collision_mask(&"player"))

	var opened := entities.open(
		DotEntity.KIND_PLAYER, player, &"", player_id, float(_tick) / float(maxi(tick_rate, 1))
	)
	player.entity_id = (opened.value as DotEntityHandle).id if opened.ok else 0

	var health := DotHealth.new()
	health.name = "Health"
	health.max_health = config.prop_body_health
	health.health = health.max_health
	player.add_child(health)
	player.health = health

	if combat != null:
		combat.register_health(player.entity_id, health)
		player.build_hitboxes(combat)

	health.died.connect(func(damage: DotDamage) -> void: _on_player_died(player, damage))

	players[player_id] = player
	sides[player_id] = side

	if match_node != null:
		var seated := match_node.add_player(String(player_id), display_name, _tick, side)

		if not seated.ok:
			DotLog.error(CHANNEL, "dot-match refused a player", {"id": String(player_id), "why": seated.error.message})

	place_one(player)
	DotLog.debug(CHANNEL, "player joined", {"id": String(player_id), "side": side})
	player_added.emit(player_id)
	return player


## Puts one player somewhere they can be, for the phase it is.
##
## [b]A joiner while the hunters are seeking watches the round out.[/b] A prop dropped into
## a round that is half over has had no time to hide, and a hunter dropped in arrives armed
## among props who planned around how many there were.
func place_one(player: PhPlayer) -> void:
	if map == null or map.doc.is_empty():
		return

	var side := "hunters" if team_of(player.player_id) == HUNTERS else "props"
	var spot := map.spawn(side, players.size() - 1)
	player.place_at(spot[0], spot[1])

	if authoritative and phase == Phase.SEEK:
		_bench(player)
	elif spectate != null:
		spectate.on_spawned(player.player_id)


func _bench(player: PhPlayer) -> void:
	player.watching = true

	if player.health != null:
		player.health.invulnerable = true

	if spectate != null:
		spectate.on_died(player.player_id, &"", false, player.controller.state.position,
			map.kill_height() + 8.0, _tick)


func remove_player(player_id: StringName) -> void:
	if not players.has(player_id):
		return

	var player: PhPlayer = players[player_id]

	if combat != null and is_instance_valid(combat) and player.entity_id != 0:
		combat.forget(player.entity_id)
		var _closed := entities.close(player.entity_id, DotEntityTable.REASON_OWNER_LEFT)

	if match_node != null:
		match_node.remove_player(String(player_id))

	players.erase(player_id)
	sides.erase(player_id)
	_bot.erase(player_id)

	if taunts != null:
		taunts.forget(player_id)

	player.queue_free()

	if spectate != null:
		spectate.on_left(player_id)

	if progress != null:
		progress.leave(player_id)

	player_removed.emit(player_id)


func team_of(player_id: StringName) -> int:
	return int(sides.get(player_id, 0))


func side_name(side: int) -> String:
	if side == PROPS or side == HUNTERS:
		return TEAM_NAMES[side - 1]

	return "nobody"


func side_colour(side: int) -> Color:
	if side == PROPS or side == HUNTERS:
		return TEAM_COLOURS[side - 1]

	return Color(0.7, 0.7, 0.7)


func players_on(side: int) -> Array[PhPlayer]:
	var out: Array[PhPlayer] = []

	for id: StringName in players:
		if int(sides.get(id, 0)) == side:
			out.append(players[id])

	return out


## How many of a side are up and in the round.
func alive_on(side: int) -> int:
	if not authoritative:
		if side == PROPS and remote_props >= 0:
			return remote_props
		if side == HUNTERS and remote_hunters >= 0:
			return remote_hunters

	var total := 0

	for player in players_on(side):
		if player.is_alive() and not player.watching:
			total += 1

	return total


func sides_are_playable() -> bool:
	if not authoritative:
		return remote_playable

	return players.size() >= 2


# --- The round --------------------------------------------------------------

func start() -> void:
	if not authoritative:
		return

	# Built again here: on a server nothing was listening when the world opened (the module
	# builds the bridge after), and a map built before it is a map no client is ever sent.
	var id := StringName(str(map_doc.get("id", "")))

	if not map_doc.is_empty() and catalogue != null and catalogue.playable(config.map_ids).has(id):
		var _rebuilt := build_map(map_doc)
		_place_everybody()
	else:
		_lay_out_map()

	match_node.start(_tick)


func _on_round_started(number: int) -> void:
	round_number = number
	_round_seed = config.seed_value + number * 7919
	random.reseed(_round_seed)

	# A new map once this one has had its rounds, or as soon as the players voted for one.
	if next_map_id != &"" or (_rounds_on_map >= config.rounds_per_map and not _map_unplayed):
		_lay_out_map()

	_map_unplayed = false
	_decided = false
	_winner = 0
	_winner_name = ""
	seek_elapsed = 0.0
	_bot.clear()

	if taunts != null:
		taunts.reset()

	_draw_sides()
	_place_everybody()
	_arm_hunters()

	if progress != null:
		progress.on_round_began()

	_set_phase(Phase.HIDE)
	round_began.emit(number, map.id())

	DotLog.info(CHANNEL, "round began", {
		"number": number, "map": String(map.id()), "seed": _round_seed,
		"players": players.size(), "hunters": ", ".join(_names(players_on(HUNTERS))),
	})


func _on_round_ended(number: int, winner: int, _outcome: int) -> void:
	_set_phase(Phase.IDLE)
	_rounds_on_map += 1

	if not _decided:
		_winner_name = "the round ran out"

	if progress != null:
		progress.on_round_over(winner)

	round_over.emit(number, winner, _winner_name)
	DotLog.info(CHANNEL, "round over", {"number": number, "winner": _winner_name})


## Who hunts this round: [DotTeamRotation], with the server's mode and the players' wishes.
func _draw_sides() -> void:
	var keys: Array[StringName] = []

	for id: StringName in players:
		keys.append(id)

	keys.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))

	var wishes := {}

	if config.allow_side_choice:
		for id in keys:
			match (players[id] as PhPlayer).side_wish:
				HUNTERS:
					wishes[id] = 1
				PROPS:
					wishes[id] = -1

	var want := config.hunters_for(keys.size())
	var picked: Dictionary = DotTeamRotation.pick(
		keys, want, config.hunter_pick as DotTeamRotation.Mode, hunter_history, _round_seed, wishes
	)
	DotTeamRotation.note(hunter_history, keys, picked["picked"], round_number)

	for id in keys:
		_set_side(id, HUNTERS if (picked["picked"] as Array).has(id) else PROPS)

	if not keys.is_empty():
		DotLog.debug(CHANNEL, "hunters drawn", {"why": str(picked["why"])})


## A player's wish, from chat. Server side. Takes effect at the next draw.
func wish_side(id: StringName, side: int) -> void:
	var player: PhPlayer = players.get(id)
	if player != null:
		player.side_wish = side if side == PROPS or side == HUNTERS else 0


func _set_side(id: StringName, side: int) -> void:
	var player: PhPlayer = players.get(id)

	if player == null:
		return

	var was := int(sides.get(id, 0))
	sides[id] = side
	player.team = side

	if match_node != null and was != side:
		var _moved := match_node.switch_team(String(id), side, _tick)

	if was != side:
		side_changed.emit(id, side)


static func _names(of: Array[PhPlayer]) -> PackedStringArray:
	var out := PackedStringArray()
	for player in of:
		out.append(player.display_name)
	return out


## The next map, built.
func _lay_out_map() -> void:
	if catalogue == null:
		return

	var doc: Dictionary = {}

	if next_map_id != &"" and catalogue.playable(config.map_ids).has(next_map_id):
		doc = catalogue.maps[next_map_id]

	next_map_id = &""

	if doc.is_empty():
		doc = catalogue.next_map(
			config.map_ids, config.shuffle_maps, random.stream(&"map"),
			StringName(str(map_doc.get("id", "")))
		)

	var _built := build_map(doc)
	_rounds_on_map = 0
	_map_unplayed = true
	_place_everybody()


## Builds [param doc] as the map. What the server does between rounds, and what a client does
## when it is sent one.
func build_map(doc: Dictionary) -> DotResult:
	world_clearing.emit()

	# Everybody back into their own body before the furniture they were wearing goes.
	for id: StringName in players:
		(players[id] as PhPlayer).reset_round()

	var built := map.build(doc)

	if not built.ok:
		DotLog.error(CHANNEL, "a map would not build", {"id": str(doc.get("id", "?")), "why": built.error.message})
		return built

	map_doc = map.doc

	if spectate != null:
		spectate.set_overviews(map.overview(), map.overview())

	world_rebuilt.emit()
	return built


## Everybody to where their side starts, in their own body, at full health, holding nothing.
func _place_everybody() -> void:
	var ids := players.keys()
	ids.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))

	var seats := {PROPS: 0, HUNTERS: 0}

	for id: StringName in ids:
		var player: PhPlayer = players[id]
		var side := team_of(id)
		player.reset_round()
		_disarm(player)
		player.controller.remove_modifier(PhController.BLINDFOLD)

		if player.health != null:
			player.health.max_health = config.hunter_health if side == HUNTERS else config.prop_body_health
			player.health.health = player.health.max_health
			player.health.alive = true
			player.health.invulnerable = false

		var spot := map.spawn("hunters" if side == HUNTERS else "props", int(seats.get(side, 0)))
		seats[side] = int(seats.get(side, 0)) + 1
		player.place_at(spot[0], spot[1])

		if spectate != null:
			spectate.on_spawned(player.player_id)

		disguise_changed.emit(player.player_id)


func _arm_hunters() -> void:
	for player in players_on(HUNTERS):
		for weapon_id in config.hunter_weapons:
			var _armed := arm(player, StringName(weapon_id))

		var first := StringName(config.hunter_weapons[0]) if not config.hunter_weapons.is_empty() else &""

		if first != &"" and player.weapons != null:
			var def := player.weapons.arsenal.catalogue.get_def(first)
			if def != null:
				var _selected := player.weapons.arsenal.select(def.slot, _tick)
				player.wanted_slot = def.slot


func _set_phase(to: int) -> void:
	if phase == to:
		return

	phase = to
	phase_elapsed = 0.0

	# The blindfold is a modifier, so a predicting client holds its own hunter still on exactly
	# the ticks the server does. See [PhController].
	for player in players_on(HUNTERS):
		if to == Phase.HIDE:
			var _held := player.controller.add_modifier(PhController.BLINDFOLD)
		else:
			var _let_go := player.controller.remove_modifier(PhController.BLINDFOLD)

	if to == Phase.SEEK and taunts != null:
		# The standing-still clock starts with the seeking: a prop standing still while it
		# hides is doing what hiding is.
		taunts.reset()

	phase_changed.emit(to)
	DotLog.debug(CHANNEL, "the round changed phase", {"phase": Phase.keys()[to]})


func _advance_phase(delta: float) -> void:
	if phase == Phase.IDLE:
		return

	phase_elapsed += delta

	match phase:
		Phase.HIDE:
			if phase_elapsed >= hide_limit():
				seek_elapsed = 0.0
				_set_phase(Phase.SEEK)
			else:
				_check_round(false)
		Phase.SEEK:
			seek_elapsed += delta
			_check_round(true)


## Rounds still to play on this map, this one included. 1 is the last.
func rounds_left_on_map() -> int:
	return maxi(config.rounds_per_map - _rounds_on_map, 1)


## How long the props get to hide: the map's, under the server's.
func hide_limit() -> float:
	var asked := float(map_doc.get("hide_seconds", 0.0))
	return minf(asked, config.hide_seconds) if asked > 0.0 else config.hide_seconds


## How long the hunters get to seek: the map's, under the server's ceiling.
func round_limit() -> float:
	var asked := float(map_doc.get("round_seconds", 0.0))
	return minf(asked, config.round_seconds) if asked > 0.0 else config.round_seconds


## Last side standing, or the clock. [param seeking] is whether the clock counts yet.
func _check_round(seeking: bool) -> void:
	var props_left := alive_on(PROPS)
	var hunters_left := alive_on(HUNTERS)

	if props_left == 0 and hunters_left == 0:
		_decide(0, "nobody is left")
	elif props_left == 0:
		_decide(HUNTERS, "the hunters found every prop")
	elif hunters_left == 0:
		_decide(PROPS, "the hunters are gone" if players_on(HUNTERS).size() > 0 else "nobody was hunting")
	elif seeking and seek_elapsed >= round_limit():
		match config.timeout_winner:
			PROPS:
				_decide(PROPS, "time: the props stayed hidden")
			HUNTERS:
				_decide(HUNTERS, "time: the hunters hold the house")
			_:
				_decide(0, "time")


func _decide(winner: int, why: String) -> void:
	if _decided:
		return

	_decided = true
	_winner = winner
	_winner_name = why

	if authoritative:
		for id: StringName in players:
			var player: PhPlayer = players[id]

			if winner != 0 and team_of(id) == winner:
				player.points += config.winner_points

			if team_of(id) == PROPS and player.is_alive() and not player.watching:
				player.points += config.survive_points

				if progress != null:
					progress.on_survived(id)

	DotLog.info(CHANNEL, "the round is decided", {"winner": winner, "why": why})


# --- Hiding -------------------------------------------------------------------

## A prop asks to become what they are looking at. Server side.
##
## [b]The server looks, not the client.[/b] What is in front of somebody is a ray from where
## the server has their eyes along the way the server has them looking, through the server's
## copy of the map; a client that named a prop could name one across the map.
func request_disguise(id: StringName) -> bool:
	var player: PhPlayer = players.get(id)

	if not _may_hide(player, id):
		return false

	var hit := _look(player, rules.reach)

	if hit < 0:
		refused.emit(id, "Look at a prop to become it.")
		return false

	return disguise_as(id, map.prop_id(hit))


## Makes [param id] a [param prop_id], if the rules allow it. What a look decides, and what a
## suite and an admin do directly.
func disguise_as(id: StringName, prop_id: StringName) -> bool:
	var player: PhPlayer = players.get(id)

	if not _may_hide(player, id):
		return false

	if not props_catalogue.may_disguise(prop_id):
		refused.emit(id, "You cannot hide as a %s." % props_catalogue.title_of(prop_id).to_lower())
		return false

	var size := props_catalogue.size_of(prop_id)
	var allowed := DotPropDisguise.may_take(size, rules)

	if not allowed.ok:
		refused.emit(id, allowed.error.message)
		return false

	if player.is_disguised() and player.disguise.prop_id == prop_id:
		return false

	var next := DotPropDisguise.of(prop_id, size)
	next.yaw = player.controller.state.yaw

	if not _make_room(player, next):
		refused.emit(id, "There is no room to be a %s here." % props_catalogue.title_of(prop_id).to_lower())
		return false

	_wear(player, next)
	return true


## Makes sure [param player] has room for [param next]'s hull, moving them a little if they
## need it. False when there is nowhere near enough.
##
## [b]A hull changes size in place.[/b] A bottle beside a wall that becomes a bookcase, or a
## small prop under a table that shows its face, has a capsule half inside the wall or the
## table, and the motor resolves that by shoving them out a different way on each machine, or
## not at all. So the server looks first: where they stand, then a step to each side, never
## through a wall to get there, never off the floor. A move is a teleport, which the owner's
## client takes from the next snapshot like any other correction.
func _make_room(player: PhPlayer, next: DotPropDisguise) -> bool:
	var world := get_world_3d()

	if world == null or physics == null or player.controller == null:
		return true

	var hull := DotPropDisguise.hull(next.size, rules) if next.is_disguised() \
		else Vector2(PhPlayer.BODY_RADIUS, PhPlayer.BODY_HEIGHT)
	var at := player.controller.state.position
	var space := world.direct_space_state
	var mask := physics.layer_mask(&"world") | physics.layer_mask(&"prop")

	var capsule := CapsuleShape3D.new()
	# A hair under the real size, or a hull resting on the floor and touching a wall counts
	# as being inside both.
	capsule.radius = maxf(hull.x - 0.03, 0.05)
	capsule.height = maxf(hull.y - 0.06, capsule.radius * 2.0)
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = capsule
	query.collision_mask = mask

	var spots: Array[Vector3] = [at]

	for ring in [0.3, 0.6]:
		for k in range(8):
			var a := TAU * float(k) / 8.0
			spots.append(at + Vector3(cos(a), 0.0, sin(a)) * ring)

	for spot in spots:
		query.transform = Transform3D(Basis.IDENTITY, spot + Vector3(0.0, hull.y * 0.5 + 0.02, 0.0))

		if not space.intersect_shape(query, 1).is_empty():
			continue

		if spot != at:
			var middle := Vector3(0.0, minf(hull.y, player.hull_height()) * 0.5, 0.0)
			var through := PhysicsRayQueryParameters3D.create(at + middle, spot + middle, mask)
			var down := PhysicsRayQueryParameters3D.create(spot + Vector3(0.0, 0.3, 0.0), spot + Vector3(0.0, -0.5, 0.0), mask)

			if not space.intersect_ray(through).is_empty() or space.intersect_ray(down).is_empty():
				continue

			player.place_at(spot, player.controller.state.yaw)

		return true

	return false


func _may_hide(player: PhPlayer, id: StringName) -> bool:
	if player == null or not player.is_alive() or player.watching:
		return false

	if team_of(id) != PROPS:
		refused.emit(id, "Only the props hide.")
		return false

	if phase == Phase.IDLE:
		refused.emit(id, "Wait for the round to start.")
		return false

	return true


## Puts [param next] on [param player] — a new prop, or their own body — and carries the
## health across as a fraction, so a hurt prop cannot heal by finding a bigger one.
func _wear(player: PhPlayer, next: DotPropDisguise) -> void:
	var old_max := player.health.max_health if player.health != null else 1.0
	var new_max := DotPropDisguise.health(next.size, rules) if next.is_disguised() else config.prop_body_health

	player.apply_disguise(next)

	if player.health != null:
		var current := player.health.health
		player.health.max_health = new_max
		player.health.health = DotPropDisguise.health_after(current, old_max, new_max, rules)

	# Wearing anything again ends a reveal.
	if next.is_disguised() and player.set_aside != null:
		player.set_aside = null
		player.reveal_ready_at = _now() + rules.reveal_cooldown

	if progress != null and next.is_disguised():
		progress.on_disguised(player.player_id)

	disguise_changed.emit(player.player_id)


## A prop shows their own face, or puts the prop they took off back on. Server side.
func reveal(id: StringName) -> bool:
	var player: PhPlayer = players.get(id)

	if not _may_hide(player, id):
		return false

	if player.is_disguised():
		var wait := player.reveal_ready_at - _now()

		if wait > 0.0:
			refused.emit(id, "You can show yourself again in %d s." % int(ceilf(wait)))
			return false

		var body := DotPropDisguise.new()

		if not _make_room(player, body):
			refused.emit(id, "There is no room to stand up here.")
			return false

		var kept := player.disguise.duplicate_value()
		_wear(player, body)
		player.set_aside = kept
		player.revealed_at = _now()
		player.reveal_paid = 0.0
		return true

	if player.set_aside != null:
		if not _make_room(player, player.set_aside):
			refused.emit(id, "There is no room to be that here.")
			return false

		_wear(player, player.set_aside)
		return true

	refused.emit(id, "Look at a prop and press the disguise key first.")
	return false


## Turns a prop: [enum Turn]. Server side.
func turn(id: StringName, how: int) -> bool:
	var player: PhPlayer = players.get(id)

	if player == null or not player.is_disguised() or not player.is_alive():
		return false

	var d := player.disguise
	var changed := true

	match how:
		Turn.LOCK:
			d.set_locked(not d.locked, player.controller.state.yaw)
		Turn.TILT_FORWARD:
			changed = d.tilt(1, true, rules)
		Turn.TILT_BACK:
			changed = d.tilt(-1, true, rules)
		Turn.TILT_LEFT:
			changed = d.tilt(1, false, rules)
		Turn.TILT_RIGHT:
			changed = d.tilt(-1, false, rules)
		Turn.STRAIGHTEN:
			d.straighten()
		_:
			changed = false

	if changed:
		player.apply_disguise(d)
		disguise_changed.emit(id)

	return changed


## A prop taunts, by choice. [param taunt_id] empty picks one. Server side.
func taunt(id: StringName, taunt_id: StringName = &"") -> bool:
	var player: PhPlayer = players.get(id)

	if player == null or not player.is_alive() or player.watching or team_of(id) != PROPS:
		return false

	# Taunts start with the seek. A hunter cannot move yet, so a taunt during the hide is no
	# risk; and the hunter's client is told nothing about where the props are then, so it
	# would play the sound from wherever it last saw them, which is the wrong place.
	if phase != Phase.SEEK:
		refused.emit(id, "Taunts start when the hunters are let go.")
		return false

	var may := taunts.may_taunt(id, _now())

	if not may.ok:
		refused.emit(id, may.error.message)
		return false

	var played := taunts.taunt(id, _now(), taunt_id, false, _tick)

	if played.is_empty():
		return false

	player.points += int(played["points"])
	player.taunting_id = played["id"]

	if progress != null:
		progress.on_taunted(id, false)

	taunted.emit(id, played["id"], false)
	return true


## Every prop standing still too long, made to taunt; and the meter on the way there.
func _advance_taunts() -> void:
	if taunts == null or phase != Phase.SEEK:
		return

	var now := _now()

	for player in players_on(PROPS):
		if not player.is_alive() or player.watching:
			continue

		taunts.observe(player.player_id, player.controller.state.position, now)
		player.taunt_meter = taunts.meter(player.player_id, now) if config.show_taunt_meter else 0.0

		if taunts.due(player.player_id, now):
			var played := taunts.taunt(player.player_id, now, &"", true, _tick + int(player.entity_id % 997))

			if played.is_empty():
				continue

			player.points += int(played["points"])
			player.taunting_id = played["id"]

			if progress != null:
				progress.on_taunted(player.player_id, true)

			taunted.emit(player.player_id, played["id"], true)


## The points a prop earns while showing their own face.
func _advance_reveals(delta: float) -> void:
	for player in players_on(PROPS):
		player.reveal_wait = maxf(player.reveal_ready_at - _now(), 0.0) if player.is_disguised() else 0.0

		if player.set_aside == null or player.is_disguised() or not player.is_alive():
			continue

		var cap := rules.reveal_paid_seconds
		var before := player.reveal_paid
		player.reveal_paid = before + delta if cap <= 0.0 else minf(before + delta, cap)
		var whole := int(floor(player.reveal_paid)) - int(floor(before))

		if whole > 0:
			player.points += int(round(float(whole) * rules.reveal_points_per_second))


## The last props given away: everybody still hidden is marked once few enough are left or
## little enough time is.
func _advance_beacons() -> void:
	var props_left := alive_on(PROPS)
	var on := phase == Phase.SEEK and props_left > 0 and (
		(config.beacon_props_left > 0 and props_left <= config.beacon_props_left)
		or (config.beacon_seconds_left > 0.0 and round_limit() - seek_elapsed <= config.beacon_seconds_left)
	)

	for player in players_on(PROPS):
		player.marked = on and player.is_alive() and not player.watching


## A ray from [param player]'s eyes along their aim: the prop it reaches within [param reach],
## or -1. Walls stop it.
func _look(player: PhPlayer, reach: float) -> int:
	var world := get_world_3d()

	if world == null or map == null:
		return -1

	var eye := player.eye_position()
	var query := PhysicsRayQueryParameters3D.create(eye, eye + player.aim_direction() * reach)
	query.collision_mask = (physics.layer_mask(&"world") | physics.layer_mask(&"prop")) if physics != null else 0xFFFFFFFF
	var hit := world.direct_space_state.intersect_ray(query)

	if hit.is_empty():
		return -1

	return map.prop_from_hit(hit.get("collider"), int(hit.get("shape", -1)))


# --- Weapons ---------------------------------------------------------------

## Hands [param player] a weapon, building their rig the first time.
func arm(player: PhPlayer, weapon_id: StringName) -> bool:
	if player.weapons == null:
		var rig := ZeeWeaponRig.new()
		rig.name = "Weapons"
		rig.role = ZeeWeaponRig.Role.SERVER
		rig.authority = authoritative
		rig.tick_rate = tick_rate
		rig.player_ref = DotNodeRef.of_path(player.get_path())
		player.add_child(rig)

		var ready_now := rig.setup()

		if not ready_now.ok:
			DotLog.warn(CHANNEL, "a weapon rig would not set up", {"player": String(player.player_id), "why": ready_now.error.message})
			player.remove_child(rig)
			rig.queue_free()
			return false

		player.weapons = rig

	if not player.weapons.give(weapon_id).ok:
		return false

	player_armed.emit(player.player_id, weapon_id)
	return true


func _disarm(player: PhPlayer) -> void:
	if player.weapons == null:
		return

	player.remove_child(player.weapons)
	player.weapons.queue_free()
	player.weapons = null


## The hunters' guns, while they seek. A blindfolded hunter fires nothing.
func _advance_weapons() -> void:
	if combat == null or phase != Phase.SEEK:
		return

	for id: StringName in players:
		var player: PhPlayer = players[id]

		if player.weapons == null or not player.is_alive() or player.watching:
			continue

		var outcome := player.weapons.simulate_tick(weapon_command_for(player), _tick)

		for shot in outcome.shots:
			shot.attacker = player.entity_id
			shot.tick = _tick
			var _resolved := combat.resolve_shot(shot)
			_charge_for_decoys(player, shot)


## What shooting the furniture costs: a share of the damage the shot would have done, off the
## hunter's own health.
##
## [b]Every pellet that stopped on a real prop, and none that hit a player.[/b] A shot's
## impacts include the pellets that struck somebody, and a prop player standing beside the
## chair they copied would otherwise cost the hunter who found them.
func _charge_for_decoys(player: PhPlayer, shot: DotShot) -> void:
	if config.decoy_penalty <= 0.0 or map == null:
		return

	var struck: Array[Vector3] = []

	for damage in shot.damages:
		if damage != null:
			struck.append(damage.point)

	var decoys := 0

	for point in shot.impacts:
		var on_somebody := false

		for hit in struck:
			if hit.distance_to(point) < 0.02:
				on_somebody = true
				break

		if not on_somebody and map.prop_containing(point) >= 0:
			decoys += 1

	if decoys == 0:
		return

	var amount := maxf(shot.damage * float(decoys) * config.decoy_penalty, config.decoy_penalty_min)
	var cost := DotDamage.make(0, player.entity_id, amount, null)
	cost.point = player.controller.state.position
	cost.direction = player.aim_direction()
	cost.tick = _tick
	cost.weapon_id = &"decoy"
	cost.context = {"why": DIED_DECOY}
	var _applied := combat.apply_damage(cost)

	if progress != null:
		progress.on_decoy(player.player_id)

	decoy_hit.emit(player.player_id, amount)


func weapon_command_for(player: PhPlayer) -> DotWeaponCommand:
	var command := DotWeaponCommand.new()
	var pending := player.controller.current_command

	if pending == null:
		return command

	command.set_button(DotWeaponCommand.BUTTON_ATTACK, pending.is_pressed(DotFpsCommand.BUTTON_USER_0))
	command.set_button(DotWeaponCommand.BUTTON_ALT, pending.is_pressed(DotFpsCommand.BUTTON_USER_1))
	command.set_button(DotWeaponCommand.BUTTON_RELOAD, pending.is_pressed(DotFpsCommand.BUTTON_USER_2))
	command.yaw = pending.yaw
	command.pitch = pending.pitch
	command.slot = player.wanted_slot
	return command


# --- The tick ---------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if not authoritative or match_node == null or external_tick:
		return

	simulate(delta)


## One tick, counted by this world. What an offline client and the suite use.
func simulate(delta: float) -> void:
	_tick += 1
	_step(delta)


## One tick, numbered by the netcode. What the bridge uses.
func tick_once(tick: int) -> void:
	if match_node == null:
		return

	_tick = tick
	_step(delta_for_tick())


func current_tick() -> int:
	return _tick


## Simulated seconds, from the tick. What every timer in the game counts.
func _now() -> float:
	return float(_tick) / float(maxi(tick_rate, 1))


func _step(delta: float) -> void:
	_advance_phase(delta)
	_drive_bots()

	for id: StringName in players:
		var player: PhPlayer = players[id]

		if player.is_alive() and not player.watching:
			player.simulate(_tick, delta)
			player.refit()

	_advance_weapons()
	_watch_world()
	_advance_reveals(delta)
	_advance_taunts()
	_advance_beacons()

	if combat != null:
		combat.tick(_tick, delta)

	if spectate != null:
		spectate.advance(_tick)

	if not sides_are_playable() and phase == Phase.IDLE:
		return

	match_node.tick(_tick)


## Somebody below the map is out. A height test, not a trigger volume: something falling fast
## crosses a thin trigger between two ticks without ever being inside it.
func _watch_world() -> void:
	if map == null or map.doc.is_empty() or phase == Phase.IDLE:
		return

	for id: StringName in players:
		var player: PhPlayer = players[id]

		if phase == Phase.IDLE:
			return

		if not player.is_alive() or player.watching:
			continue

		if player.controller.state.position.y < map.kill_height():
			var fall := DotDamage.make(0, player.entity_id, player.health.max_health * 10.0, null)
			fall.tick = _tick
			fall.context = {"why": DIED_FELL}
			var _applied := combat.apply_damage(fall)


func delta_for_tick() -> float:
	return 1.0 / float(maxi(tick_rate, 1))


func set_tick_rate(rate: int) -> bool:
	if rate <= 0 or rate == tick_rate:
		return false

	tick_rate = rate

	for id: StringName in players:
		(players[id] as PhPlayer).tick_rate = rate

	if match_node != null and match_node.config != null:
		match_node.config.tick_rate = rate

	return true


# --- Applying what the server said (client side) -----------------------------

## A disguise the server decided, on this client's copy of the player.
func apply_disguise_wire(id: StringName, wire: Dictionary) -> void:
	var player: PhPlayer = players.get(id)

	if player == null:
		return

	player.apply_disguise(DotPropDisguise.from_wire(wire))
	disguise_changed.emit(id)


# --- Bots ------------------------------------------------------------------

## What a stand-in does. A prop walks to a piece of furniture it may become, becomes it, and
## stands still somewhere near others like it; a hunter wanders the props' half of the map,
## shoots any prop it can see the face of, and now and then shoots something it suspects.
func _drive_bots() -> void:
	for id: StringName in players:
		var player: PhPlayer = players[id]

		if not player.is_bot or not player.is_alive() or player.watching:
			continue

		var command := DotFpsCommand.new()
		command.yaw = player.controller.state.yaw
		command.pitch = player.controller.state.pitch

		if phase == Phase.IDLE:
			pass
		elif team_of(id) == PROPS:
			_bot_hide(player, command)
		elif phase == Phase.SEEK:
			_bot_seek(player, command)

		player.controller.apply_command(command)


func _bot_state(player: PhPlayer) -> Dictionary:
	if not _bot.has(player.player_id):
		_bot[player.player_id] = {"target": -1, "goal": Vector3.INF, "since": _tick, "stuck": [player.controller.state.position, _tick]}

	return _bot[player.player_id]


func _bot_hide(player: PhPlayer, command: DotFpsCommand) -> void:
	var state := _bot_state(player)

	if player.is_disguised():
		# Turned to face somewhere fixed and left alone, like a person who has found a spot. A
		# taunt now and then, for the points.
		if not player.disguise.locked:
			var _locked := turn(player.player_id, Turn.LOCK)

		var draw := random.stream_for(&"bot_taunt", _tick + int(player.entity_id % 4096))

		if phase == Phase.SEEK and draw.next_range_f(0.0, 1.0) < 0.002:
			var _taunted := taunt(player.player_id)

		return

	var target := int(state["target"])

	if target < 0 or target >= map.props.size():
		target = _bot_pick_prop(player)
		state["target"] = target

	if target < 0:
		return

	var prop: Dictionary = map.props[target]
	var size: Vector3 = prop["size"]
	var centre: Vector3 = (prop["transform"] as Transform3D).origin + Vector3(0.0, size.y * 0.5, 0.0)
	var eye := player.eye_position()
	var flat := Vector3(centre.x - eye.x, 0.0, centre.z - eye.z)

	if flat.length() > rules.reach * 0.6:
		command.yaw = rad_to_deg(atan2(-flat.x, -flat.z))
		command.move = Vector2(0.0, 1.0)
		_bot_unstick(player, command)
		return

	# Close enough: look at it and become it.
	var look := centre - eye
	command.yaw = rad_to_deg(atan2(-look.x, -look.z))
	command.pitch = clampf(rad_to_deg(asin(clampf(look.normalized().y, -1.0, 1.0))), -89.0, 89.0)
	player.controller.apply_command(command)
	player.controller.state.yaw = command.yaw
	player.controller.state.pitch = command.pitch

	if not request_disguise(player.player_id):
		# Something in the way, or not one it may be: another.
		state["target"] = -1


## A prop the bot may become, near it but not on top of the hunters' spawn.
func _bot_pick_prop(player: PhPlayer) -> int:
	var best := -1
	var best_score := INF
	var at := player.controller.state.position
	var draw := random.stream_for(&"bot_prop", round_number * 4096 + int(player.entity_id % 4096))

	for index in range(map.props.size()):
		var prop: Dictionary = map.props[index]
		var prop_id: StringName = prop["id"]

		if not props_catalogue.may_disguise(prop_id) or not DotPropDisguise.may_take(prop["size"], rules).ok:
			continue

		var distance := at.distance_to((prop["transform"] as Transform3D).origin)
		var score := distance + draw.next_range_f(0.0, 12.0)

		if score < best_score:
			best_score = score
			best = index

	return best


func _bot_seek(player: PhPlayer, command: DotFpsCommand) -> void:
	var state := _bot_state(player)

	# A person who has paid for a few wrong guesses stops guessing: the first build's stand-in
	# hunter emptied a magazine through a sofa at a prop behind it and killed itself on the
	# decoy charge in its first round (examples/dedicated found it).
	var careful := player.health != null and player.health.health < player.health.max_health * 0.4

	# Anybody whose own face this bot can see, it shoots.
	var seen := _bot_seen_prop(player)

	if seen != null:
		_bot_aim(player, command, seen.controller.state.position + Vector3(0.0, minf(seen.hull_height(), 1.4) * 0.6, 0.0))
		command.set_button(DotFpsCommand.BUTTON_USER_0, true)
		return

	var goal: Vector3 = state["goal"]

	if goal == Vector3.INF or player.controller.state.position.distance_to(goal) < 1.5 or _tick - int(state["since"]) > tick_rate * 12:
		goal = _bot_wander_goal(player)
		state["goal"] = goal
		state["since"] = _tick

	var flat := Vector3(goal.x, 0.0, goal.z) - Vector3(player.controller.state.position.x, 0.0, player.controller.state.position.z)
	command.yaw = rad_to_deg(atan2(-flat.x, -flat.z))
	command.move = Vector2(0.0, 1.0)
	_bot_unstick(player, command)

	# Suspicion: now and then, a shot at the nearest piece of furniture, which is how a person
	# finds a prop and how they pay for guessing wrong.
	var draw := random.stream_for(&"bot_suspect", _tick + int(player.entity_id % 4096))

	if not careful and draw.next_range_f(0.0, 100.0) < config.bot_suspicion / float(maxi(tick_rate, 1)):
		var near := _bot_nearest_hideable(player)

		if near != Vector3.INF:
			_bot_aim(player, command, near)
			command.move = Vector2.ZERO
			command.set_button(DotFpsCommand.BUTTON_USER_0, true)


func _bot_seen_prop(player: PhPlayer) -> PhPlayer:
	var eye := player.eye_position()
	var forward := player.aim_direction()

	for other in players_on(PROPS):
		if not other.is_alive() or other.watching:
			continue

		var at := other.controller.state.position + Vector3(0.0, 0.8, 0.0)
		var toward := at - eye

		if toward.length() > 25.0 or forward.dot(toward.normalized()) < 0.5:
			continue

		# Its own face, or a prop that moved where the bot could see.
		if other.is_disguised() and Vector2(other.controller.state.velocity.x, other.controller.state.velocity.z).length() < 1.0:
			continue

		# Clear of the furniture too: a shot through a sofa at somebody behind it is a shot
		# into the sofa, and the sofa charges for it.
		if _clear_between(eye, at, true):
			return other

	return null


func _bot_nearest_hideable(player: PhPlayer) -> Vector3:
	var best := Vector3.INF
	var closest := 6.0
	var eye := player.eye_position()

	for prop: Dictionary in map.props:
		var centre: Vector3 = (prop["transform"] as Transform3D).origin + Vector3(0.0, (prop["size"] as Vector3).y * 0.5, 0.0)
		var distance := eye.distance_to(centre)

		if distance < closest:
			closest = distance
			best = centre

	for other in players_on(PROPS):
		if other.is_alive() and other.is_disguised():
			var at := other.controller.state.position + Vector3(0.0, other.hull_height() * 0.5, 0.0)
			if eye.distance_to(at) < closest:
				closest = eye.distance_to(at)
				best = at

	return best


func _bot_wander_goal(player: PhPlayer) -> Vector3:
	var draw := random.stream_for(&"bot_wander", _tick + int(player.entity_id % 4096))

	if map.props.is_empty():
		return player.controller.state.position

	var prop: Dictionary = map.props[draw.next_range_i(0, map.props.size() - 1)]
	return (prop["transform"] as Transform3D).origin


func _bot_aim(player: PhPlayer, command: DotFpsCommand, at: Vector3) -> void:
	var toward := at - player.eye_position()
	var draw := random.stream_for(&"bot_aim", round_number * 8192 + int(player.entity_id % 8192))
	var spread := config.bot_aim_spread_degrees
	command.yaw = rad_to_deg(atan2(-toward.x, -toward.z)) + draw.next_range_f(-spread, spread)
	command.pitch = clampf(rad_to_deg(asin(clampf(toward.normalized().y, -1.0, 1.0))) + draw.next_range_f(-spread, spread) * 0.4, -89.0, 89.0)


func _bot_unstick(player: PhPlayer, command: DotFpsCommand) -> void:
	var state := _bot_state(player)
	var mark: Array = state["stuck"]
	var at := player.controller.state.position

	if _tick - int(mark[1]) < tick_rate:
		return

	var stuck := Vector2(at.x - (mark[0] as Vector3).x, at.z - (mark[0] as Vector3).z).length() < 0.4

	if stuck and player.controller.state.mode == DotFpsState.Mode.GROUND:
		command.set_button(DotFpsCommand.BUTTON_JUMP, true)
		# And a new goal, because the old one is through something.
		state["goal"] = Vector3.INF
		state["target"] = -1

	state["stuck"] = [at, _tick]


## Whether nothing solid is between two points: the walls, and with [param furniture] the
## map's props as well.
func _clear_between(from: Vector3, to: Vector3, furniture: bool = false) -> bool:
	var world := get_world_3d()

	if world == null:
		return true

	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = physics.layer_mask(&"world") if physics != null else 1

	if furniture and physics != null:
		query.collision_mask |= physics.layer_mask(&"prop")

	return world.direct_space_state.intersect_ray(query).is_empty()


# --- Reacting ---------------------------------------------------------------

func _on_player_died(player: PhPlayer, damage: DotDamage) -> void:
	var by := entities.key_for_id(damage.attacker)
	var why: StringName = damage.context.get("why", DIED_SHOT)

	if spectate != null and authoritative:
		spectate.on_died(
			player.player_id, by, why == DIED_FELL,
			damage.point if damage.point != Vector3.ZERO else player.global_position,
			map.kill_height() + 8.0, _tick
		)

	if authoritative and by != &"" and players.has(by) and team_of(by) == HUNTERS and team_of(player.player_id) == PROPS:
		(players[by] as PhPlayer).points += config.find_points

	if progress != null:
		progress.on_died(player.player_id, by, why)

	player.marked = false

	if match_node != null and DotEntity.is_kind(player.entity_id, DotEntity.KIND_PLAYER):
		match_node.report_kill(String(by), String(player.player_id), why, _tick)

	player_died.emit(player.player_id, by, why)
	DotLog.debug(CHANNEL, "player died", {"id": String(player.player_id), "by": String(by), "why": String(why)})


# --- Reporting --------------------------------------------------------------

func seconds_left() -> float:
	match phase:
		Phase.HIDE:
			return maxf(hide_limit() - phase_elapsed, 0.0)
		Phase.SEEK:
			return maxf(round_limit() - seek_elapsed, 0.0)
		_:
			return 0.0


func describe() -> Dictionary:
	return {
		"round": round_number,
		"phase": Phase.keys()[phase],
		"left": "%.0f s" % seconds_left(),
		"map": str(map_doc.get("id", "-")),
		"players": players.size(),
		"props": alive_on(PROPS),
		"hunters": alive_on(HUNTERS),
		"decided": _winner_name if _decided else "-",
		"maps": catalogue.maps.size() if catalogue != null else 0,
		"phase_id": phase,
	}


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray(["prophunt, round %d" % round_number])
	var facts := describe()

	for key: String in facts:
		lines.append("  %-10s %s" % [key, facts[key]])

	for id: StringName in players:
		var player: PhPlayer = players[id]
		lines.append("  %-8s %-18s %s%s" % [
			side_name(team_of(id)), player.display_name,
			props_catalogue.title_of(player.disguise.prop_id) if player.is_disguised() else "-",
			"" if player.is_alive() else " (out)",
		])

	if map != null:
		lines.append_array(map.describe_lines())

	return lines
