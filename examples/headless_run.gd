extends Node

const PhCatalogue := preload("../game/ph_catalogue.gd")
const PhConfig := preload("../game/ph_config.gd")
const PhController := preload("../game/ph_controller.gd")
const PhGame := preload("../game/ph_game.gd")
const PhInterest := preload("../game/net/ph_interest.gd")
const PhMapDoc := preload("../game/ph_map_doc.gd")
const PhPlayer := preload("../game/ph_player.gd")
const PhProgress := preload("../game/ph_progress.gd")
const PhProps := preload("../game/ph_props.gd")

## The simulation, headless: the prop catalogue and the map documents, the draw, the hide, every
## part of hiding as a prop, taunts, shots at props and at the furniture, the beacon, and how a
## round is decided.
##
## [b]Counts sections AND checks, and the second is the one that matters.[/b] A script error
## inside a section aborts that function and the section counter is already satisfied,
## because the section announced itself on the way in. dot-settings has the story.
##
## Every number about the map here is the built-in practice house's
## ([method PhCatalogue.practice]), whose comment lists where everything is.

const SECTIONS := 18

const CHECKS := 79

const TICK_RATE := 64
const TICK := 1.0 / float(TICK_RATE)

## The first chair round the kitchen table in the practice house: where it stands.
const CHAIR_AT := Vector3(3.6, 0.0, 1.2)

## The bookcase on the south wall of the living room, a decoy to shoot.
const BOOKCASE_AT := Vector3(-4.0, 0.0, 7.6)

var _passed := 0
var _failed := 0
var _sections_entered := 0
var _sections_finished := 0
var _failures := PackedStringArray()

var _worlds: Array[PhGame] = []


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("prophunt headless run")
	print("")

	_test_config()
	_test_catalogue()
	_test_documents()
	await _test_world_builds()
	await _test_the_draw()
	await _test_the_hide()
	await _test_disguise()
	await _test_reveal()
	await _test_turning()
	await _test_room()
	await _test_taunts()
	await _test_shots()
	await _test_decoys()
	await _test_the_round()
	await _test_the_beacon()
	_test_interest()
	await _test_bots()
	await _test_the_client()

	for world in _worlds.duplicate():
		await _dispose(world)

	await get_tree().process_frame

	print("")
	print("%d sections entered, %d finished" % [_sections_entered, _sections_finished])
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	var code := 1 if _failed > 0 else 0

	if _sections_entered != _sections_finished or _sections_entered != SECTIONS:
		print("ERROR: %d of %d sections finished, %d expected." % [
			_sections_finished, _sections_entered, SECTIONS
		])
		code = 1

	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		code = 1

	get_tree().quit(code)


# --- Without a world ------------------------------------------------------------

func _test_config() -> void:
	_section("the configuration")
	var config := PhConfig.new()
	_check(config.validate().ok, "the defaults validate")
	_check(config.hunters_for(1) == 0, "one person is not a round")
	_check(config.hunters_for(2) == 1 and config.hunters_for(3) == 1, "one hunter up to three players")
	_check(config.hunters_for(7) == 3, "one per three, rounded up (7 players, 3)")
	_check(config.hunters_for(60) == config.max_hunters, "never more than the most")

	var rules := config.disguise_rules()
	_check(is_equal_approx(rules.reach, config.disguise_reach) and is_equal_approx(rules.reveal_cooldown, config.reveal_cooldown),
		"the disguise rules are the configuration's")

	config.hunter_pick = 9
	_check(not config.validate().ok, "a way of picking hunters that is none of the three is refused")
	_finished()


func _test_catalogue() -> void:
	_section("the prop catalogue is what the models measure")
	var props := PhProps.new()
	var count := props.load_file()
	_check(count > 100, "it reads (%d props)" % count)
	_check((props.size_of(&"furniture_chair") - Vector3(0.46, 1.08, 0.46)).length() < 0.01,
		"a chair is the size measured", str(props.size_of(&"furniture_chair")))
	_check(props.may_disguise(&"furniture_chair") and not props.may_disguise(&"furniture_ceiling_fan"),
		"a chair may be worn and a ceiling fan may not")

	var bad := 0
	for id in props.order:
		var e := props.entry(id)
		if not ResourceLoader.exists("res://" + str(e["model"])):
			bad += 1
	_check(bad == 0, "every prop's model is in the game", "%d missing" % bad)
	_finished()


func _test_documents() -> void:
	_section("a map is a document, and a bad one is refused with a reason")
	var practice := PhCatalogue.practice()
	_check(str(practice.get("id", "")) == "ph_practice", "the practice house validates")
	_check(practice["boxes"][0]["at"] is Array, "positions are normalised to plain arrays")

	var props := PhProps.new()
	var _n := props.load_file()
	var unknown := 0
	for prop: Dictionary in practice["props"]:
		if not props.has(StringName(str(prop["id"]))):
			unknown += 1
	_check(unknown == 0, "every prop it names is in the catalogue")

	var bare := practice.duplicate(true)
	bare["spawns"] = {"props": [], "hunters": [{"at": [0, 0, 0]}]}
	var refused := PhMapDoc.validate(bare)
	_check(not refused.ok and str(refused.error).contains("props"), "a map with no props' spawns is refused, saying so")

	var wrong := practice.duplicate(true)
	wrong["kind"] = "course"
	_check(not PhMapDoc.validate(wrong).ok, "a document of another kind is refused")

	var encoded := PhMapDoc.encode(practice)
	var decoded := PhMapDoc.decode(encoded)
	_check(decoded.ok and PhMapDoc.digest(decoded.value) == PhMapDoc.digest(practice),
		"it survives the wire whole (%d bytes)" % encoded.size())

	var torn := encoded.slice(0, encoded.size() - 3)
	_check(not PhMapDoc.decode(torn).ok, "a torn one is refused rather than half built")
	_finished()


# --- A world ---------------------------------------------------------------------

func _test_world_builds() -> void:
	_section("the practice house builds, solid where it should be")
	var game := await _world()
	_check(game.map.id() == &"ph_practice", "the map is built")
	_check(game.map.props.size() == (game.map_doc["props"] as Array).size(), "every prop is in it (%d)" % game.map.props.size())

	var space := game.get_world_3d().direct_space_state
	var clear := 0
	var floored := 0
	var spawns: Array = (game.map_doc["spawns"] as Dictionary)["props"] + (game.map_doc["spawns"] as Dictionary)["hunters"]

	for spawn: Dictionary in spawns:
		var at := PhMapDoc.v3(spawn["at"])
		var hull := CapsuleShape3D.new()
		hull.radius = 0.35
		hull.height = 1.8
		var query := PhysicsShapeQueryParameters3D.new()
		query.shape = hull
		query.transform = Transform3D(Basis.IDENTITY, at + Vector3(0.0, 0.95, 0.0))
		query.collision_mask = game.physics.collision_mask(&"player")
		if space.intersect_shape(query, 1).is_empty():
			clear += 1
		var ray := PhysicsRayQueryParameters3D.create(at + Vector3.UP * 0.5, at + Vector3.DOWN * 1.0)
		if not space.intersect_ray(ray).is_empty():
			floored += 1

	_check(clear == spawns.size(), "nobody starts inside anything (%d of %d clear)" % [clear, spawns.size()])
	_check(floored == spawns.size(), "and every spawn has a floor under it (%d of %d)" % [floored, spawns.size()])

	var chair := _prop_near(game, CHAIR_AT)
	_check(chair >= 0 and game.map.prop_id(chair) == &"furniture_chair", "the chair is where the document puts it")
	_check(game.map.prop_containing(CHAIR_AT + Vector3(0.0, 0.5, 0.0)) == chair, "and a point inside it is on it")
	_finished()


func _test_the_draw() -> void:
	_section("who hunts: the draw, the wishes and the equal share")
	var game := await _world(func(c: PhConfig) -> void:
		c.hunter_pick = 1
		c.players_per_hunter = 3.0)
	var ids: Array[StringName] = []
	for i in range(6):
		var p := game.add_player(StringName("u%d" % (100 + i)), "P%d" % i)
		ids.append(p.player_id)

	game.start()
	await _step(game, 2)
	_check(game.players_on(PhGame.HUNTERS).size() == 2, "six players, two hunters")

	var turns := {}
	for round_index in range(6):
		for id in ids:
			if game.team_of(id) == PhGame.HUNTERS:
				turns[id] = int(turns.get(id, 0)) + 1
		await _end_round(game)
	var spread := _spread(turns, ids)
	_check(spread.y - spread.x <= 1, "an equal share over six rounds (%d..%d each)" % [spread.x, spread.y])

	game.wish_side(ids[0], PhGame.PROPS)
	for id in ids.slice(1):
		game.wish_side(id, PhGame.PROPS)
	game.wish_side(ids[3], PhGame.HUNTERS)
	await _end_round(game)
	_check(game.team_of(ids[3]) == PhGame.HUNTERS, "somebody who asked to hunt hunts")
	_finished()


func _test_the_hide() -> void:
	_section("the hide: hunters held still and blind, props free")
	var game := await _world(func(c: PhConfig) -> void: c.hide_seconds = 1.0)
	var hunter := game.add_player(&"u200", "Hunter", PhGame.HUNTERS)
	var prop := game.add_player(&"u201", "Prop")
	game.wish_side(hunter.player_id, PhGame.HUNTERS)
	game.wish_side(prop.player_id, PhGame.PROPS)
	game.start()
	await _step(game, 2)
	_check(game.phase == PhGame.Phase.HIDE, "a round starts with the hide")
	_check(game.team_of(hunter.player_id) == PhGame.HUNTERS and hunter.controller.has_modifier(PhController.BLINDFOLD),
		"the hunter is blindfolded")

	var hunter_from := hunter.controller.state.position
	var prop_from := prop.controller.state.position
	for i in range(30):
		_drive(hunter, Vector2(0.0, 1.0))
		_drive(prop, Vector2(0.0, 1.0))
		await _step(game, 1)
	var walked := Vector2(hunter.controller.state.position.x - hunter_from.x, hunter.controller.state.position.z - hunter_from.z)
	_check(walked.length() < 0.05, "a blindfolded hunter does not move", "%.2f m" % walked.length())
	_check(prop.controller.state.position.distance_to(prop_from) > 1.0, "a prop does")
	_check(hunter.weapons != null, "a hunter is armed from the start")

	await _step(game, TICK_RATE)
	_check(game.phase == PhGame.Phase.SEEK and not hunter.controller.has_modifier(PhController.BLINDFOLD),
		"after the hide the hunters are let go")
	_finished()


func _test_disguise() -> void:
	_section("becoming a prop: the hull, the health and the hitbox are the prop's")
	var game := await _hide_round()
	var prop: PhPlayer = game.players_on(PhGame.PROPS)[0]
	var hunter: PhPlayer = game.players_on(PhGame.HUNTERS)[0]

	_check(not game.request_disguise(hunter.player_id), "a hunter cannot hide")

	# From the west, across the empty end of the kitchen: the table is on the chair's other side.
	_stand_facing(prop, CHAIR_AT + Vector3(-2.0, 0.05, 0.0), CHAIR_AT + Vector3(0.0, 0.6, 0.0))
	await _step(game, 1)
	_check(game.request_disguise(prop.player_id) and prop.disguise.prop_id == &"furniture_chair",
		"a prop looking at a chair becomes a chair", String(prop.disguise.prop_id))

	var size := game.props_catalogue.size_of(&"furniture_chair")
	var hull := DotPropDisguise.hull(size, game.rules)
	_check(is_equal_approx(prop.controller.tunables.radius, hull.x) and is_equal_approx(prop.controller.tunables.stand_height, hull.y),
		"the controller sweeps the chair's hull (r %.2f, h %.2f)" % [hull.x, hull.y])
	_check(is_equal_approx(prop.health.max_health, DotPropDisguise.health(size, game.rules)),
		"and has a chair's health (%d)" % int(prop.health.max_health))

	var box := prop.hitboxes.get_node("Prop") as DotHitbox
	_check(box.enabled and (prop.hitboxes.get_node("Chest") as DotHitbox).enabled == false
		and box.half_extents.is_equal_approx(size * 0.5), "its hitbox is the chair's box and not a person's")

	_check(not game.disguise_as(prop.player_id, &"furniture_ceiling_fan"), "a ceiling fan cannot be worn")
	_check(not game.disguise_as(prop.player_id, &"furniture_computer_mouse"), "nor something too small to find")

	prop.health.health = prop.health.max_health * 0.5
	var _became := game.disguise_as(prop.player_id, &"furniture_bookcase_closed")
	_check(absf(prop.health.health / prop.health.max_health - 0.5) < 0.02,
		"a hurt prop keeps the share of health it had in a bigger one (%d of %d)" % [int(prop.health.health), int(prop.health.max_health)])
	_finished()


func _test_reveal() -> void:
	_section("showing yourself: paid by the second, and not again for a while")
	var game := await _hide_round(func(c: PhConfig) -> void:
		c.reveal_cooldown = 10.0
		c.reveal_points_per_second = 1.0)
	var prop: PhPlayer = game.players_on(PhGame.PROPS)[0]
	var _worn := game.disguise_as(prop.player_id, &"furniture_chair")
	var points := prop.points

	_check(game.reveal(prop.player_id) and not prop.is_disguised() and prop.set_aside != null,
		"a prop takes the chair off and keeps it")
	await _step(game, TICK_RATE * 3 + 2)
	_check(prop.points - points == 3, "and is paid a point a second while it shows itself (+%d)" % (prop.points - points))

	_check(game.reveal(prop.player_id) and prop.disguise.prop_id == &"furniture_chair", "the same key puts the chair back on")
	_check(not game.reveal(prop.player_id), "and it cannot show itself again straight away")
	_finished()


## A hull changes size where the player stands, so the server looks for room first.
func _test_room() -> void:
	_section("a bigger hull needs room: moved a step, or refused")
	var game := await _hide_round()
	var prop: PhPlayer = game.players_on(PhGame.PROPS)[0]

	# Against the living room's west wall (inner face x -10.0) as a bedside cabinet, which fits,
	# then a bookcase, whose hull would be inside the wall where the cabinet stands.
	var _small := game.disguise_as(prop.player_id, &"furniture_cabinet_bed")
	prop.place_at(Vector3(-9.75, 0.05, 2.0), 0.0)
	await _step(game, 2)
	var before := prop.controller.state.position
	_check(game.disguise_as(prop.player_id, &"furniture_bookcase_closed"), "a cabinet against a wall may become a bookcase")
	var moved := prop.controller.state.position.x - before.x
	var hull := DotPropDisguise.hull(game.props_catalogue.size_of(&"furniture_bookcase_closed"), game.rules)
	_check(moved > 0.02 and prop.controller.state.position.x - hull.x >= -10.0 - 0.01,
		"and is moved off the wall by enough for its hull", "moved %.2f m, hull %.2f" % [moved, hull.x])

	# Under the kitchen table (top at 0.75 m, chairs on both sides) as a bedside cabinet: there
	# is no room to stand up anywhere a step away.
	var _under := game.disguise_as(prop.player_id, &"furniture_cabinet_bed")
	prop.place_at(Vector3(4.5, 0.05, 2.0), 0.0)
	await _step(game, 2)
	var refusals: Array = []
	game.refused.connect(func(id: StringName, why: String) -> void: refusals.append(why))
	_check(not game.reveal(prop.player_id) and prop.is_disguised(), "under a table a prop cannot stand up as a person")
	_check(not refusals.is_empty() and str(refusals[-1]).contains("room"), "and is told why", str(refusals))
	_finished()


func _test_turning() -> void:
	_section("turning a prop: locked, tilted, upright again")
	var game := await _hide_round()
	var prop: PhPlayer = game.players_on(PhGame.PROPS)[0]
	var _worn := game.disguise_as(prop.player_id, &"furniture_chair")
	prop.controller.state.yaw = 40.0
	var _locked := game.turn(prop.player_id, PhGame.Turn.LOCK)
	prop.controller.state.yaw = 120.0
	_check(prop.disguise.locked and prop.prop_basis().is_equal_approx(Basis(Vector3.UP, deg_to_rad(40.0))),
		"locked, the chair keeps the facing it was locked at")
	var _tilted := game.turn(prop.player_id, PhGame.Turn.TILT_FORWARD)
	_check(is_equal_approx(prop.disguise.pitch, game.config.tilt_step), "a tilt leans it by the step")
	var _upright := game.turn(prop.player_id, PhGame.Turn.STRAIGHTEN)
	_check(is_zero_approx(prop.disguise.pitch) and is_zero_approx(prop.disguise.roll), "and it stands up again")
	_finished()


func _test_taunts() -> void:
	_section("taunts: chosen and paid, or forced on a prop that stands still")
	var game := await _hide_round(func(c: PhConfig) -> void:
		c.hide_seconds = 0.5
		c.auto_taunt_seconds = 2.0
		c.taunt_cooldown = 0.25
		c.taunt_points = 2)
	var prop: PhPlayer = game.players_on(PhGame.PROPS)[0]
	_check(game.taunt_ids().size() > 10, "the taunt list is read (%d)" % game.taunt_ids().size())

	var heard: Array = []
	game.taunted.connect(func(id: StringName, taunt_id: StringName, forced: bool) -> void:
		heard.append([id, taunt_id, forced]))
	var points := prop.points
	_check(not game.taunt(prop.player_id, &"you_lose") and prop.points == points,
		"no taunt while the hunters are blindfolded")

	while game.phase != PhGame.Phase.SEEK:
		await _step(game, 1)

	_check(game.taunt(prop.player_id, &"you_lose") and prop.points == points + 2,
		"a chosen taunt while they hunt is paid (+%d)" % (prop.points - points))
	_check(not game.taunt(prop.player_id), "and a second straight after is refused")

	await _step(game, TICK_RATE)
	_check(prop.taunt_meter > 0.3 and prop.taunt_meter < 0.8, "standing still fills the meter (%.2f at one second of two)" % prop.taunt_meter)
	await _step(game, TICK_RATE + 4)
	var forced := heard.filter(func(h: Array) -> bool: return bool(h[2]) and h[0] == prop.player_id)
	_check(forced.size() == 1, "and two seconds of it forces one taunt on it", "%d" % forced.size())
	_finished()


func _test_shots() -> void:
	_section("a hunter finds a prop by shooting it")
	var game := await _seek_round()
	var prop: PhPlayer = game.players_on(PhGame.PROPS)[0]
	var hunter: PhPlayer = game.players_on(PhGame.HUNTERS)[0]
	var _worn := game.disguise_as(prop.player_id, &"furniture_chair")
	prop.place_at(Vector3(-6.0, 0.05, 2.0), 0.0)
	# The other prop off the line of fire: the props' second spawn is where this one now stands.
	(game.players_on(PhGame.PROPS)[1] as PhPlayer).place_at(Vector3(-8.5, 0.05, 6.0), 0.0)
	_stand_facing(hunter, Vector3(-6.0, 0.05, -2.0), Vector3(-6.0, 0.6, 2.0))

	var died: Array = []
	game.player_died.connect(func(id: StringName, by: StringName, why: StringName) -> void: died.append([id, by, why]))
	var points := hunter.points
	var hurt_before := prop.health.health

	for i in range(TICK_RATE * 10):
		_aim(hunter, Vector3(-6.0, 0.6, 2.0))
		# A magazine runs dry, and nothing reloads on its own: a reload every three seconds,
		# as a player would.
		var reloading := i % (TICK_RATE * 3) > TICK_RATE * 2
		_fire(hunter, not reloading)
		_reload(hunter, reloading)
		await _step(game, 1)
		if not prop.is_alive():
			break
	_fire(hunter, false)
	_check(prop.health.health < hurt_before, "the shots land on the chair the prop is")
	_check(not prop.is_alive() and died.size() >= 1 and died[0][2] == PhGame.DIED_SHOT and died[0][1] == hunter.player_id,
		"until the prop is found, by that hunter", "health %.0f of %.0f, deaths %s, weapon %s, magazine %d" % [
			prop.health.health, prop.health.max_health, str(died),
			hunter.weapons.arsenal.current_def().id if hunter.weapons.arsenal.current_def() != null else &"-",
			hunter.weapons.arsenal.magazine_of(hunter.weapons.arsenal.current_def().id) if hunter.weapons.arsenal.has_method("magazine_of") else -1])
	_check(hunter.points >= points + game.config.find_points, "and the hunter is paid for it")
	_finished()


func _test_decoys() -> void:
	_section("shooting the furniture costs a hunter, and can finish one")
	var game := await _seek_round(func(c: PhConfig) -> void:
		c.decoy_penalty = 2.0
		c.hunter_health = 30.0)
	var hunter: PhPlayer = game.players_on(PhGame.HUNTERS)[0]
	_stand_facing(hunter, BOOKCASE_AT + Vector3(0.0, 0.05, -3.0), BOOKCASE_AT + Vector3(0.0, 1.0, 0.0))

	var cost: Array = []
	game.decoy_hit.connect(func(id: StringName, amount: float) -> void: cost.append(amount))
	var died: Array = []
	game.player_died.connect(func(id: StringName, by: StringName, why: StringName) -> void: died.append([id, why]))
	var start := hunter.health.health

	for i in range(TICK_RATE * 6):
		_aim(hunter, BOOKCASE_AT + Vector3(0.0, 1.0, 0.0))
		_fire(hunter, true)
		await _step(game, 1)
		if not hunter.is_alive():
			break
	_fire(hunter, false)

	_check(not cost.is_empty() and hunter.health.health < start, "a shot at the real bookcase costs the hunter health")
	_check(not hunter.is_alive() and died.size() == 1 and died[0][1] == PhGame.DIED_DECOY,
		"and enough of them finish the hunter, as the furniture's")
	_finished()


func _test_the_round() -> void:
	_section("a round: the hunters find everybody, or the props hold out")
	var game := await _seek_round(func(c: PhConfig) -> void:
		c.round_seconds = 30.0)
	var winners: Array = []
	game.round_over.connect(func(_n: int, winner: int, _why: String) -> void: winners.append(winner))
	var hunter: PhPlayer = game.players_on(PhGame.HUNTERS)[0]
	var points := hunter.points

	for prop in game.players_on(PhGame.PROPS):
		_kill(game, prop, hunter)
	await _step(game, 4)
	_check(winners == [PhGame.HUNTERS], "every prop found is the hunters' round")
	_check(hunter.points >= points + game.config.winner_points, "and the hunters are paid for winning")

	await _wait_for(game, PhGame.Phase.SEEK)
	var survivor: PhPlayer = game.players_on(PhGame.PROPS)[0]
	var kept := survivor.points
	game.seek_elapsed = game.round_limit() - 0.05
	await _step(game, 6)
	_check(winners.size() == 2 and winners[1] == PhGame.PROPS, "the clock is the props' round")
	_check(survivor.points >= kept + game.config.winner_points + game.config.survive_points,
		"and a prop alive at the end is paid for winning and for surviving")
	_finished()


func _test_the_beacon() -> void:
	_section("the last prop is given away")
	var game := await _seek_round(func(c: PhConfig) -> void:
		c.beacon_props_left = 1
		c.beacon_seconds_left = 0.0)
	var props := game.players_on(PhGame.PROPS)
	await _step(game, 2)
	_check(props.filter(func(p: PhPlayer) -> bool: return p.marked).is_empty(), "nobody is marked while several are hidden")
	for i in range(props.size() - 1):
		_kill(game, props[i], game.players_on(PhGame.HUNTERS)[0])
	await _step(game, 2)
	_check(props[props.size() - 1].marked, "the last one is")
	_finished()


func _test_interest() -> void:
	_section("a hunter is told nothing about the props while they hide")
	var game := PhGame.new()
	var config := PhConfig.new()
	game.config = config
	var interest := PhInterest.new()
	interest.game = game
	var hunter := PhPlayer.new()
	hunter.player_id = &"u1"
	var prop := PhPlayer.new()
	prop.player_id = &"u2"
	game.sides[&"u1"] = PhGame.HUNTERS
	game.sides[&"u2"] = PhGame.PROPS
	var watcher := DotNetIdentity.new()
	var seen := DotNetIdentity.new()
	hunter.add_child(watcher)
	prop.add_child(seen)

	game.phase = PhGame.Phase.HIDE
	_check(not interest._is_relevant(watcher, seen, {}), "a prop is not in a hunter's snapshot while the props hide")
	_check(interest._is_relevant(seen, watcher, {}), "a hunter is in a prop's")
	game.phase = PhGame.Phase.SEEK
	_check(interest._is_relevant(watcher, seen, {}), "and once the hunters are let go, everybody is in everybody's")

	hunter.free()
	prop.free()
	game.free()
	_finished()


func _test_bots() -> void:
	_section("stand-ins hide and seek")
	var game := await _world(func(c: PhConfig) -> void:
		c.hide_seconds = 8.0
		c.players_per_hunter = 3.0)
	for i in range(6):
		var bot := game.add_player(StringName("u%d" % (900 + i)), "Bot%d" % i)
		bot.is_bot = true
	game.start()
	await _step(game, TICK_RATE * 8)
	var hidden := game.players_on(PhGame.PROPS).filter(func(p: PhPlayer) -> bool: return p.is_disguised())
	# Every one, not most: a stand-in whose look met the wrong thing used to ask again every
	# tick for the rest of the round, in the open.
	_check(hidden.size() == game.players_on(PhGame.PROPS).size(),
		"every stand-in prop is hiding as something by the end of the hide (%d of %d)" % [hidden.size(), game.players_on(PhGame.PROPS).size()])
	await _step(game, TICK_RATE * 6)
	_check(game.phase == PhGame.Phase.SEEK or game.phase == PhGame.Phase.IDLE, "and the round goes on without anybody at the keyboard")

	_finished()


func _test_the_client() -> void:
	_section("the client boots offline: the keys, the HUD, the taunt list, the board")
	var client: Node = (load("res://game/ph_client.gd") as GDScript).new()
	client.set(&"force_offline", true)
	client.set(&"config_file", "user://cfg/headless-none.json")
	add_child(client)

	for i in 8:
		await get_tree().process_frame

	_check(InputMap.has_action(&"ph_disguise") and InputMap.has_action(&"ph_taunt_menu"),
		"the game's keys are actions, from the bindings table")
	_check(client.get("player") != null and client.get("hud") != null and (client.get("hud") as Node).get("game") != null,
		"a player and a HUD bound to the world")
	client.call("open_taunts")
	var menu: Variant = (client.get("settings") as Node).get("menu") if client.get("settings") != null else null
	_check(menu != null and (menu as DotMenu).picker.is_open(), "the taunt picker opens")
	if menu != null:
		(menu as DotMenu).picker.close()
	var snapshot: Dictionary = client.call("board_snapshot")
	_check((snapshot["players"] as Array).size() >= 2, "the board lists the room")

	# A round started the way dot-match starts one, with this keyboard drawn to hunt. The round
	# arms its hunters and THEN begins the hide, and the client used to drop every gun at the
	# start of a hide: a hunter seeking with a gun nobody could see, in every real round.
	var world: PhGame = client.get("game")
	world.wish_side(&"local", PhGame.HUNTERS)
	world._on_round_started(world.round_number + 1)
	for i in 4:
		await get_tree().process_frame
	_check(world.team_of(&"local") == PhGame.HUNTERS and world.phase == PhGame.Phase.HIDE
		and client.get("weapons") != null and client.get("view_model") != null,
		"a hunter's gun is in their hands through the hide",
		"side %d, phase %d, weapons %s" % [world.team_of(&"local"), world.phase, client.get("weapons")])

	remove_child(client)
	client.free()
	await get_tree().process_frame
	_finished()


# --- Helpers --------------------------------------------------------------------

func _section(name: String) -> void:
	_sections_entered += 1
	print(name)


func _finished() -> void:
	_sections_finished += 1


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
		return

	_failed += 1
	var line := "%s%s" % [what, "" if detail == "" else "  (%s)" % detail]
	_failures.append(line)
	print("  FAIL  %s" % line)


## A world on the practice house, stepped by hand. The previous one is freed first: every
## world here shares ONE physics space, and every map is built at the origin.
func _world(configure: Callable = Callable()) -> PhGame:
	for old in _worlds.duplicate():
		await _dispose(old)

	var config := PhConfig.new()
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.minimum_players = 0
	config.map_ids = PackedStringArray(["ph_practice"])
	config.keep_progress = true
	config.hide_seconds = 2.0

	if configure.is_valid():
		configure.call(config)

	var game := PhGame.new()
	game.name = "World%d" % _worlds.size()
	game.config = config
	game.tick_rate = TICK_RATE
	game.authoritative = true
	game.register_service = false
	add_child(game)
	game.set_physics_process(false)
	_worlds.append(game)

	await _physics_frame()
	await _physics_frame()
	return game


## A world in the hide, with a hunter and two props.
func _hide_round(configure: Callable = Callable()) -> PhGame:
	var game := await _world(configure)
	var hunter := game.add_player(&"u300", "Hunter")
	game.wish_side(hunter.player_id, PhGame.HUNTERS)
	for i in range(2):
		var prop := game.add_player(StringName("u%d" % (301 + i)), "Prop%d" % i)
		game.wish_side(prop.player_id, PhGame.PROPS)
	game.start()
	await _wait_for(game, PhGame.Phase.HIDE)
	return game


## A world where the hunters are seeking.
func _seek_round(configure: Callable = Callable()) -> PhGame:
	var game := await _hide_round(func(c: PhConfig) -> void:
		c.hide_seconds = 0.25
		if configure.is_valid():
			configure.call(c))
	await _wait_for(game, PhGame.Phase.SEEK)
	return game


func _wait_for(game: PhGame, phase: int) -> void:
	for i in range(TICK_RATE * 20):
		if game.phase == phase:
			return
		await _step(game, 1)


## Ends the round in play (the hunters win) and waits for the next to begin.
func _end_round(game: PhGame) -> void:
	var number := game.round_number
	for prop in game.players_on(PhGame.PROPS):
		if prop.is_alive():
			_kill(game, prop, null)
	for i in range(TICK_RATE * 20):
		await _step(game, 1)
		if game.round_number > number and game.phase == PhGame.Phase.HIDE:
			return


func _kill(game: PhGame, victim: PhPlayer, by: PhPlayer) -> void:
	var damage := DotDamage.make(by.entity_id if by != null else 0, victim.entity_id, 10000.0, null)
	damage.context = {"why": PhGame.DIED_SHOT}
	var _applied := game.combat.apply_damage(damage)


func _step(game: PhGame, ticks: int) -> void:
	for _i in range(ticks):
		game.simulate(TICK)
		await _physics_frame()


func _physics_frame() -> void:
	await get_tree().physics_frame


func _dispose(game: PhGame) -> void:
	_worlds.erase(game)

	if not is_instance_valid(game):
		return

	remove_child(game)
	game.free()
	await get_tree().process_frame


func _drive(player: PhPlayer, move: Vector2) -> void:
	var command := DotFpsCommand.new()
	command.yaw = player.controller.state.yaw
	command.move = move
	player.controller.apply_command(command)


## Puts [param player] at [param at], looking at [param target].
func _stand_facing(player: PhPlayer, at: Vector3, target: Vector3) -> void:
	player.place_at(at, 0.0)
	_aim(player, target)


func _aim(player: PhPlayer, target: Vector3) -> void:
	var look := target - player.eye_position()
	var command := DotFpsCommand.new()
	command.yaw = rad_to_deg(atan2(-look.x, -look.z))
	command.pitch = clampf(rad_to_deg(asin(clampf(look.normalized().y, -1.0, 1.0))), -89.0, 89.0)
	player.controller.state.yaw = command.yaw
	player.controller.state.pitch = command.pitch
	player.controller.apply_command(command)


func _fire(player: PhPlayer, on: bool) -> void:
	var command := player.controller.current_command
	if command == null:
		command = DotFpsCommand.new()
	command.set_button(DotFpsCommand.BUTTON_USER_0, on)
	player.controller.apply_command(command)


func _reload(player: PhPlayer, on: bool) -> void:
	var command := player.controller.current_command
	if command == null:
		command = DotFpsCommand.new()
	command.set_button(DotFpsCommand.BUTTON_USER_2, on)
	player.controller.apply_command(command)


func _prop_near(game: PhGame, at: Vector3) -> int:
	for index in range(game.map.props.size()):
		if ((game.map.props[index] as Dictionary)["transform"] as Transform3D).origin.distance_to(at) < 0.05:
			return index
	return -1


static func _spread(turns: Dictionary, ids: Array[StringName]) -> Vector2i:
	var lo := 999
	var hi := 0
	for id in ids:
		lo = mini(lo, int(turns.get(id, 0)))
		hi = maxi(hi, int(turns.get(id, 0)))
	return Vector2i(lo, hi)
