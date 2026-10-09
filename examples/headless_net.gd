extends Node

const PhCatalogue := preload("../game/ph_catalogue.gd")
const PhConfig := preload("../game/ph_config.gd")
const PhEvents := preload("../game/net/ph_events.gd")
const PhGame := preload("../game/ph_game.gd")
const PhMapDoc := preload("../game/ph_map_doc.gd")
const PhNetBridge := preload("../game/net/ph_net_bridge.gd")
const PhPlayer := preload("../game/ph_player.gd")

## The real path minus the socket: two worlds, two managers, two bridges, two links with the
## RPC replaced by a queue, so the codec, the seal, the snapshots, the prediction and the
## reconciliation all run, in one process, in two physics worlds.
##
## [b]What this suite is for is the two claims the game rests on over a wire.[/b] First, a
## disguise is a HULL as well as a look: a prop's own client predicts itself with the prop's
## capsule, so if the client and the server disagree about what somebody is wearing, the client
## walks through a doorway the server's chair does not fit through and is pulled back every
## tick. So this asserts the hull on both ends and the two ends agreeing after a run. Second,
## the blindfold is true on the wire: a hunter's snapshots carry no prop while the props hide
## (`PhInterest`), so a client that skipped drawing the black screen would still see nothing.
## Then everything else that crosses: the map document, the sides, turning, a taunt, a joiner
## told what everybody is wearing, a decoy's charge, the result.
##
## Sections and checks are both counted; mg-smash-copter's notes say why the second matters.

const SECTIONS := 12
const CHECKS := 47

const CLIENT_PEER := 7
const SESSION := 42
const SERVER_TICK_RATE := 64
const CLIENT_ENGINE_TICK_RATE := 30
const SNAPSHOT_RATE := 30
const INPUT_LEAD := 3

## The practice house's kitchen chair, and a spot west of it to stand and look at it from.
const CHAIR_AT := Vector3(3.6, 0.0, 1.2)
const LOOK_FROM := Vector3(1.6, 0.05, 1.2)

var _passed := 0
var _failed := 0
var _sections_entered := 0
var _sections_finished := 0
var _failures := PackedStringArray()

var _server_game: PhGame = null
var _client_game: PhGame = null
var _server_net: DotNetManager = null
var _client_net: DotNetManager = null
var _server_bridge: PhNetBridge = null
var _client_bridge: PhNetBridge = null
var _stand_in: PhPlayer = null

var _to_client: Array = []
var _to_server: Array = []
var _tick: int = 0

## What the client was told, by kind, so a section can ask whether an event arrived.
var _heard: Dictionary = {}


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("prophunt over the wire")
	print("")

	_test_the_codec()

	if await _build():
		await _test_a_client_joins()
		await _test_the_map_arrives()
		await _test_the_blindfold_is_on_the_wire()
		await _test_the_local_player_is_predicted()
		await _test_a_disguise_is_a_hull_on_both_ends()
		await _test_turning_and_taunting()
		await _test_a_joiner_is_told_what_everybody_wears()
		await _test_a_decoy_is_charged()
		await _test_the_round_ends()
		await _test_leaving()

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


# --- The codec ------------------------------------------------------------------

## Every encoder against its decoder. Nothing checks that two ends of a serialisation are
## inverses for you: dot-moderation once wrote "voice muted" and read back a warning.
func _test_the_codec() -> void:
	_section("every event decodes to what was encoded")

	var hello := PhEvents.read_hello(DotNetReader.new(PhEvents.write_hello(SESSION, 64, 1234, 30.0, 300.0, 2.0, 60.0)))
	_check(bool(hello["ok"]) and int(hello["player_id"]) == SESSION
		and absf(float(hello["round_seconds"]) - 300.0) < 0.1 and absf(float(hello["hide_seconds"]) - 30.0) < 0.05
		and absf(float(hello["beacon_period"]) - 2.0) < 0.02 and absf(float(hello["taunt_range"]) - 60.0) < 0.2,
		"HELLO", str(hello))

	var doc := PhCatalogue.practice()
	var sent := PhEvents.read_map(DotNetReader.new(PhEvents.write_map(PhMapDoc.encode(doc))))
	var decoded := PhMapDoc.decode(sent["encoded"]) if bool(sent["ok"]) else DotResult.fail(DotError.CODE_PARSE, "no map")
	_check(decoded.ok and PhMapDoc.digest(decoded.value) == PhMapDoc.digest(doc), "MAP carries the document whole")

	var join := PhEvents.read_join(DotNetReader.new(PhEvents.write_join(SESSION, 9, "Ada", PhGame.HUNTERS, null)))
	_check(bool(join["ok"]) and int(join["team"]) == PhGame.HUNTERS, "JOIN carries the side", str(join.get("team")))

	var round_info := PhEvents.read_round(DotNetReader.new(PhEvents.write_round(3, false, PhGame.PROPS, "the props held out")))
	_check(bool(round_info["ok"]) and int(round_info["winner"]) == PhGame.PROPS
		and str(round_info["why"]) == "the props held out", "ROUND carries the winning side and the sentence")

	var worn := DotPropDisguise.new()
	worn.prop_id = &"furniture_chair"
	worn.size = Vector3(0.9, 1.8, 0.95)
	worn.yaw = 135.0
	worn.pitch = 15.0
	worn.locked = true
	var disguise := PhEvents.read_disguise(DotNetReader.new(PhEvents.write_disguise(SESSION, worn.to_wire(), true)))
	var back := DotPropDisguise.from_wire(disguise.get("wire", {}))
	_check(bool(disguise["ok"]) and bool(disguise["revealed"]) and back != null and back.prop_id == worn.prop_id
		and back.locked and absf(back.yaw - 135.0) < 0.5 and absf(back.pitch - 15.0) < 0.5,
		"DISGUISE carries the prop, how it is turned, the lock and the face", str(disguise))

	var taunt := PhEvents.read_taunt(DotNetReader.new(PhEvents.write_taunt(SESSION, &"laugh", true)))
	_check(bool(taunt["ok"]) and taunt["taunt_id"] == &"laugh" and bool(taunt["forced"]), "TAUNT", str(taunt))

	var decoy := PhEvents.read_decoy(DotNetReader.new(PhEvents.write_decoy(4.5)))
	_check(bool(decoy["ok"]) and absf(float(decoy["amount"]) - 4.5) < 0.1, "DECOY", str(decoy))

	var turned := PhEvents.read_turn(DotNetReader.new(PhEvents.write_turn(PhGame.Turn.TILT_LEFT)))
	var asked := PhEvents.read_ask_taunt(DotNetReader.new(PhEvents.write_ask_taunt(&"whistle")))
	_check(bool(turned["ok"]) and int(turned["how"]) == PhGame.Turn.TILT_LEFT and bool(asked["ok"]) and asked["taunt_id"] == &"whistle",
		"TURN and a taunt request")

	var clock := PhEvents.read_clock(DotNetReader.new(PhEvents.write_clock(2, 12.5, 40.25, PhGame.Phase.SEEK, 3, 1, true)))
	_check(bool(clock["ok"]) and int(clock["phase"]) == PhGame.Phase.SEEK
		and absf(float(clock["seek_elapsed"]) - 40.25) < 0.1 and int(clock["props"]) == 3
		and int(clock["hunters"]) == 1, "CLOCK", str(clock))
	_finished()


# --- Bringing both halves up ---------------------------------------------------------

func _build() -> bool:
	_section("bringing both halves up")
	var failed_before := _failed

	var server_side := Node.new()
	server_side.name = "ServerSide"
	add_child(server_side)

	# The client's own physics space: two processes would be two worlds, and one world holding
	# both copies of a map is two of every collider in the same cubic metres.
	var client_view := SubViewport.new()
	client_view.name = "ClientView"
	client_view.own_world_3d = true
	client_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(client_view)

	var client_side := Node.new()
	client_side.name = "ClientSide"
	client_view.add_child(client_side)

	_server_game = _make_game(true, server_side)
	_client_game = _make_game(false, client_side)
	await get_tree().process_frame

	_check(_server_game.get_world_3d() != _client_game.get_world_3d(), "two physics worlds, as two processes would have")
	_check(_client_game.map_doc.is_empty() and _client_game.catalogue == null,
		"the client has no map and reads no map files; it will be sent one")

	Engine.physics_ticks_per_second = CLIENT_ENGINE_TICK_RATE

	_server_net = _make_manager(true, &"server", 1, server_side, SERVER_TICK_RATE)
	_client_net = _make_manager(false, &"client", CLIENT_PEER, client_side, CLIENT_ENGINE_TICK_RATE)

	_server_bridge = PhNetBridge.new()
	_server_bridge.name = "Bridge"
	server_side.add_child(_server_bridge)

	_client_bridge = PhNetBridge.new()
	_client_bridge.name = "Bridge"
	client_side.add_child(_client_bridge)

	var attached := _server_bridge.attach(_server_game, _server_net)
	var client_attached := _client_bridge.attach(_client_game, _client_net)
	_check(attached.ok and client_attached.ok, "both bridges attach")

	_server_bridge.open_link(server_side)
	_client_bridge.open_link(client_side)
	_server_net.messages.seal()
	_client_net.messages.seal()
	_check(_server_net.messages.schema_hash() == _client_net.messages.schema_hash(), "both ends agree on the schema")

	_server_bridge.link.loopback = _on_server_send
	_client_bridge.link.loopback = _on_client_send
	_client_bridge.rtt_source = func() -> float: return 40.0

	var _s := _server_net.start()
	var _c := _client_net.start()

	_client_bridge.map_received.connect(func(id: StringName) -> void:
		_heard["map"] = id)
	_client_bridge.disguise_received.connect(func(who: int, revealed: bool) -> void:
		_heard["disguises"] = int(_heard.get("disguises", 0)) + 1
		_heard["disguise"] = [who, revealed])
	_client_bridge.taunt_received.connect(func(who: int, taunt_id: StringName, forced: bool) -> void:
		_heard["taunt"] = [who, taunt_id, forced])
	_client_bridge.decoy_received.connect(func(amount: float) -> void:
		_heard["decoy"] = amount)
	_client_bridge.round_changed.connect(func(n: int, began: bool, winner: int, why: String) -> void:
		if not began:
			_heard["round_over"] = [n, winner, why])

	_stand_in = _server_bridge.add_bot("Stand-in")
	_check(_stand_in != null and _stand_in.is_bot, "a stand-in is seated before anybody joins")
	# Seated as a stand-in, driven by the suite: a stand-in prop hides on its own, and this
	# suite wants it where it puts it.
	_stand_in.is_bot = false

	# Started AFTER the bridge exists, which is what the module does: a map laid out before
	# anything listened to `world_rebuilt` would be a map no client is ever sent.
	_server_game.start()
	_check(not _server_game.map_doc.is_empty(), "the server lays its map out on start")
	_finished()
	return _failed == failed_before


func _test_a_client_joins() -> void:
	_section("a client joins, and is told its side")
	var seated := _server_bridge.add_player(CLIENT_PEER, SESSION, "Ada")
	_check(seated.ok, "the server seats them")
	_client_bridge.ask_ready()
	_exchange()
	_exchange()
	await _steps(6)

	_check(_client_bridge.local_player_id == SESSION, "the client is told who it is")
	_check(_client_game.tick_rate == SERVER_TICK_RATE, "it adopts the server's tick rate", "%d" % _client_game.tick_rate)
	_check(_client_game.players.size() == 2, "it has a body for itself and for the stand-in", "%d" % _client_game.players.size())

	await _hide_with(PhGame.HUNTERS)
	_check(_client_game.team_of(_me()) == PhGame.HUNTERS and _client_game.team_of(_stand_in.player_id) == PhGame.PROPS,
		"the client knows who is hunting and who is hiding")
	_check(_client_game.phase == PhGame.Phase.HIDE, "and that the props are hiding")
	_finished()


func _test_the_map_arrives() -> void:
	_section("the map arrives, as the document the server built")
	_check(not _client_game.map_doc.is_empty(), "the client built a map")
	_check(PhMapDoc.digest(_client_game.map_doc) == PhMapDoc.digest(_server_game.map_doc),
		"the same document, to the byte", PhMapDoc.digest(_client_game.map_doc))
	_check(_client_game.map.props.size() == _server_game.map.props.size() and _client_game.map.props.size() > 0,
		"every prop in it", "%d" % _client_game.map.props.size())
	_check(_heard.has("map"), "and the client said so")
	_finished()


## The black screen is the HUD's; this is the wire's half of it.
func _test_the_blindfold_is_on_the_wire() -> void:
	_section("a hunter is told nothing about the props while they hide")
	var copy: PhPlayer = _client_game.players[_stand_in.player_id]
	var was := copy.global_position
	_stand_in.place_at(Vector3(-3.0, 0.05, -2.0), 0.0)
	await _steps(20)
	_check(copy.global_position.distance_to(was) < 0.05 and copy.global_position.distance_to(_stand_in.global_position) > 1.0,
		"the prop moved on the server and the hunter's copy did not",
		"%.2f m from where it was" % copy.global_position.distance_to(was))

	_server_game._set_phase(PhGame.Phase.SEEK)
	await _steps(20)
	_check(copy.global_position.distance_to(_stand_in.global_position) < 0.3,
		"the moment the hunters are let go, the prop is where it is",
		"%.2f m apart" % copy.global_position.distance_to(_stand_in.global_position))
	_finished()


func _test_the_local_player_is_predicted() -> void:
	_section("a prop is predicted, and the server agrees")
	await _hide_with(PhGame.PROPS)
	var mine := _mine()
	var server_me := _server_me()
	server_me.place_at(Vector3(-2.0, 0.05, 0.0), 0.0)
	await _steps(20)
	var before := mine.controller.state.position
	var forward := DotFpsCommand.new()
	forward.move = Vector2(0.0, 1.0)
	await _step(forward)
	_check(mine.controller.state.position.distance_to(before) > 0.01,
		"a key moves the client's own player on the tick it is pressed")
	await _steps(20, forward)
	await _steps(24)
	var apart := mine.controller.state.position.distance_to(server_me.controller.state.position)
	_check(apart < 0.25, "and after running, the two ends agree", "%.3f m" % apart)
	_finished()


## The claim: what a prop wears is the capsule it is predicted with, on both ends.
func _test_a_disguise_is_a_hull_on_both_ends() -> void:
	_section("a disguise is the same hull on both ends, and the run still agrees")
	var server_me := _server_me()
	server_me.place_at(LOOK_FROM, 0.0)
	await _steps(24)
	var aim := _aim_at(_mine(), CHAIR_AT + Vector3(0.0, 0.6, 0.0))
	await _steps(6, aim)

	var heard_before := int(_heard.get("disguises", 0))
	_client_bridge.ask_disguise()
	await _steps(6, aim)
	_check(server_me.is_disguised() and server_me.disguise.prop_id == &"furniture_chair",
		"asking while looking at the chair makes the server's copy a chair",
		String(server_me.disguise.prop_id) if server_me.disguise != null else "nothing")
	_check(int(_heard.get("disguises", 0)) > heard_before, "and a DISGUISE event crossed")

	var mine := _mine()
	_check(mine.is_disguised() and mine.disguise.prop_id == &"furniture_chair", "the client's own player is the chair too")
	_check(is_equal_approx(mine.controller.tunables.radius, server_me.controller.tunables.radius)
		and is_equal_approx(mine.controller.tunables.stand_height, server_me.controller.tunables.stand_height),
		"with the chair's capsule, on both ends",
		"r %.2f / %.2f, h %.2f / %.2f" % [mine.controller.tunables.radius, server_me.controller.tunables.radius,
			mine.controller.tunables.stand_height, server_me.controller.tunables.stand_height])
	_check(absf(mine.health.max_health - server_me.health.max_health) < 0.1, "and the chair's health",
		"%.1f / %.1f" % [mine.health.max_health, server_me.health.max_health])

	var back := DotFpsCommand.new()
	back.move = Vector2(-1.0, 0.0)
	back.yaw = aim.yaw
	await _steps(20, back)
	await _steps(24)
	var apart := mine.controller.state.position.distance_to(server_me.controller.state.position)
	_check(apart < 0.25, "a chair that runs is where the server has it", "%.3f m" % apart)
	_finished()


func _test_turning_and_taunting() -> void:
	_section("turning and taunting are asked for, and the server's answer comes back")
	var server_me := _server_me()
	_client_bridge.ask_turn(PhGame.Turn.LOCK)
	await _steps(4)
	_check(server_me.disguise.locked and _mine().disguise.locked, "the lock is the server's, and the client is told")

	_client_bridge.ask_turn(PhGame.Turn.TILT_LEFT)
	await _steps(4)
	_check(absf(server_me.disguise.roll) > 1.0 and is_equal_approx(_mine().disguise.roll, server_me.disguise.roll),
		"a tilt lands on both ends", "roll %.1f / %.1f" % [_mine().disguise.roll, server_me.disguise.roll])

	var points := server_me.points
	_client_bridge.ask_taunt()
	await _steps(4)
	_check(_heard.has("taunt") and int(_heard["taunt"][0]) == SESSION and not bool(_heard["taunt"][2]),
		"a taunt is played, and everybody is told who and which", str(_heard.get("taunt")))
	_check(server_me.points - points == _server_game.config.taunt_points, "and is paid for",
		"+%d" % (server_me.points - points))
	_finished()


## A client that asks to be told everything again is told what everybody is wearing.
func _test_a_joiner_is_told_what_everybody_wears() -> void:
	_section("a joiner is told what everybody is wearing")
	var mine := _mine()
	_client_game.apply_disguise_wire(mine.player_id, {})
	_check(not mine.is_disguised(), "the client forgets (as a joiner never knew)")
	_client_bridge.ask_ready()
	_exchange()
	_exchange()
	await _steps(4)
	_check(mine.is_disguised() and mine.disguise.prop_id == &"furniture_chair" and mine.disguise.locked,
		"and READY is answered with the chair, locked")
	_finished()


func _test_a_decoy_is_charged() -> void:
	_section("a hunter who shoots the furniture is told what it cost")
	await _hide_with(PhGame.HUNTERS)
	# Armed as a round arms its hunters: the suite moved them to this side after it began.
	_server_game._arm_hunters()
	_server_game._set_phase(PhGame.Phase.SEEK)
	await _steps(4)
	var server_me := _server_me()
	server_me.place_at(LOOK_FROM, 0.0)
	await _steps(20)
	var aim := _aim_at(_mine(), CHAIR_AT + Vector3(0.0, 0.5, 0.0))
	await _steps(6, aim)
	var health := server_me.health.health
	var fire := _aim_at(_mine(), CHAIR_AT + Vector3(0.0, 0.5, 0.0))
	fire.set_button(DotFpsCommand.BUTTON_USER_0, true)
	await _steps(SERVER_TICK_RATE * 2, fire)
	await _steps(6, aim)
	_check(server_me.health.health < health, "the server charged them for shooting a chair",
		"%.1f -> %.1f, holding %s" % [health, server_me.health.health,
			String(server_me.weapons.arsenal.current_def().id) if server_me.weapons != null and server_me.weapons.arsenal.current_def() != null else "nothing"])
	_check(_heard.has("decoy") and float(_heard["decoy"]) > 0.0, "and the client was told, for its flash",
		str(_heard.get("decoy")))
	_finished()


func _test_the_round_ends() -> void:
	_section("the round ends, and the client is told who won and why")
	var damage := DotDamage.make(_server_me().entity_id, _stand_in.entity_id, 10000.0, null)
	damage.tick = _tick
	var _applied := _server_game.combat.apply_damage(damage)
	await _steps(6)
	_check(_heard.has("round_over") and int(_heard["round_over"][1]) == PhGame.HUNTERS,
		"the hunters won, and the client is told", str(_heard.get("round_over")))
	_check(_heard.has("round_over") and str(_heard["round_over"][2]) != "", "with the server's own sentence",
		str(_heard.get("round_over")))
	_finished()


func _test_leaving() -> void:
	_section("leaving")
	_server_bridge.remove_peer(CLIENT_PEER)
	await _steps(4)
	_check(not _server_game.players.has(_me()), "the server lets them go")
	_check(_server_bridge.describe()["ready_peers"] == 0, "and stops talking to them")
	_finished()


# --- Helpers --------------------------------------------------------------------

func _me() -> StringName:
	return PhNetBridge.player_key(SESSION)


func _mine() -> PhPlayer:
	return _client_game.players.get(_me())


func _server_me() -> PhPlayer:
	return _server_game.players[_me()]


## A command that looks from [param player]'s eye at [param target].
func _aim_at(player: PhPlayer, target: Vector3) -> DotFpsCommand:
	var look := target - player.eye_position()
	var command := DotFpsCommand.new()
	command.yaw = rad_to_deg(atan2(-look.x, -look.z))
	command.pitch = clampf(rad_to_deg(asin(clampf(look.normalized().y, -1.0, 1.0))), -89.0, 89.0)
	return command


## Into a fresh round's hide, with the client on [param side] and the stand-in on the other,
## everybody put back where the round puts them and wearing nothing.
func _hide_with(side: int) -> void:
	for _i in range(SERVER_TICK_RATE * 10):
		if _server_game.phase == PhGame.Phase.HIDE:
			break
		await _step()

	var other := PhGame.PROPS if side == PhGame.HUNTERS else PhGame.HUNTERS
	_server_game._set_side(_me(), side)
	_server_game._set_side(_stand_in.player_id, other)
	_server_game._set_phase(PhGame.Phase.HIDE)
	_server_game._place_everybody()
	await _steps(8)


func _make_game(server: bool, parent: Node) -> PhGame:
	var config := PhConfig.new()
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.hide_seconds = 60.0
	config.minimum_players = 0
	config.keep_progress = false
	config.auto_taunt_seconds = 0.0
	config.map_ids = PackedStringArray(["ph_practice"])

	var game := PhGame.new()
	game.name = "World"
	game.config = config
	game.authoritative = server
	game.tick_rate = SERVER_TICK_RATE if server else CLIENT_ENGINE_TICK_RATE
	game.register_service = false
	parent.add_child(game)
	game.set_physics_process(false)
	return game


func _make_manager(server: bool, scope: StringName, peer_id: int, parent: Node, tick_rate: int) -> DotNetManager:
	var manager := DotNetManager.new()
	manager.name = "Server" if server else "Client"
	manager.is_server = server
	manager.local_peer_id = peer_id
	manager.service_scope = scope
	manager.auto_tick = false
	manager.config_file = ""

	var config := DotNetConfig.new()
	config.tick_rate = tick_rate
	config.snapshot_rate = SNAPSHOT_RATE
	config.enable_prediction = true
	config.enable_lag_compensation = false
	config.max_entities_per_snapshot = 192
	config.world_extent = PhGame.NET_WORLD_EXTENT
	manager.config = config

	parent.add_child(manager)
	var _ready_now := manager.setup()
	return manager


func _on_server_send(method: StringName, peer_id: int, payload: PackedByteArray) -> void:
	if peer_id != 0 and peer_id != CLIENT_PEER:
		return

	_to_client.append({"method": method, "payload": payload})


func _on_client_send(method: StringName, _peer_id: int, payload: PackedByteArray) -> void:
	_to_server.append({"method": method, "payload": payload})


func _flush() -> void:
	var to_client := _to_client.duplicate()
	var to_server := _to_server.duplicate()
	_to_client.clear()
	_to_server.clear()

	for entry in to_client:
		_client_bridge.link.deliver(entry["method"], 1, entry["payload"])

	for entry in to_server:
		_server_bridge.link.deliver(entry["method"], CLIENT_PEER, entry["payload"])


func _exchange() -> void:
	_flush()
	_flush()


## One tick on both ends, with a real physics frame between them.
func _step(command: DotFpsCommand = null) -> void:
	_tick += 1
	var _ticks := _client_net.clock.advance(1.0 / float(maxi(_client_game.tick_rate, 1)))
	_server_bridge.server_tick(_tick)
	_flush()
	_client_bridge.client_tick(_tick + INPUT_LEAD, command if command != null else DotFpsCommand.new())
	_flush()
	await get_tree().physics_frame


func _steps(count: int, command: DotFpsCommand = null) -> void:
	for _i in range(count):
		await _step(command)


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
