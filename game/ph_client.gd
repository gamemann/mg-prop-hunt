extends Node

const PhAudio := preload("ph_audio.gd")
const PhBindings := preload("ph_bindings.gd")
const PhFigure := preload("ph_figure.gd")
const PhSettings := preload("ph_settings.gd")
const PhServices := preload("ph_services.gd")
const PhNetBridge := preload("net/ph_net_bridge.gd")
const PhNetCommand := preload("net/ph_net_command.gd")

const PhConfig := preload("ph_config.gd")
const PhGame := preload("ph_game.gd")
const PhHud := preload("ph_hud.gd")
const PhPaths := preload("ph_paths.gd")
const PhPlayer := preload("ph_player.gd")

## One local player, a camera and a HUD over a [PhGame] — offline, or against a server.
##
## [b]One client for both, and the offline half is not a demo mode.[/b] It is the same world
## class with `authoritative` true, stand-ins on both sides, and nothing else different. What
## changes is where the answers come from, and the whole of that difference is [PhNetBridge].
##
## [b]Which half runs is decided by whether there is a link in the registry.[/b] A dot-server
## client publishes a [DotClientLink] under `dot_client_link` before the game scene loads; no
## link means nobody connected us to anything, and the honest answer is a playable round.
## `--offline` forces it.
##
## [b]A prop sees itself, a hunter sees down a gun.[/b] The camera follows the side: third
## person behind a prop, at a distance that grows with what it is hiding as, because a prop's
## whole game is knowing what it looks like from where the hunters stand; first person for a
## hunter. F5 swaps either way. The simulation is the same in both — presentation only.

const CHANNEL := "ph.client"

const LINK_SERVICE := &"dot_client_link"

## How far behind a prop the camera hangs: this plus its size.
const CHASE_BACK := 2.4
const CHASE_UP := 0.8

@export var config_file: String = "user://cfg/prophunt.json"
@export var force_offline: bool = false

## How many stand-ins an offline round gets.
@export_range(0, 12, 1) var offline_bots: int = 5

var game: PhGame = null
var player: PhPlayer = null
var camera: Camera3D = null
var hud: PhHud = null
var board: DotMenuScoreboard = null
var chat: DotGameChatClient = null
var audio: PhAudio = null
var settings: PhSettings = null

## A hunter's own gun, drawn. Never decides anything: every shot is the server's.
var weapons: ZeeWeaponRig = null
var view_model: ZeeViewModel = null

var net: DotNetManager = null
var bridge: PhNetBridge = null
var link: Node = null

## Whether the camera hangs behind the player. Follows the side; F5 swaps it.
var third_person: bool = false

## Whether the player chose the view with F5 this round, which the side then leaves alone.
var _view_chosen: bool = false

var _offline: bool = true
var _sampler: DotFpsSampler = null
var _watch_id: int = -1
var _captured: bool = false
var _arm: SpringArm3D = null
var _rig_height: float = 0.0
var _started_msec: int = Time.get_ticks_msec()

var _firing: bool = false
var _alt: bool = false
var _reloading: bool = false
var _slot: int = 0

## The last whole second of the hide a beep was played for.
var _beeped: int = -1

## The rules a hunter's body comes apart by when the furniture finishes them.
var _break_rules: DotPlayerBreakRules = null


func _ready() -> void:
	ZeeModelCache.set_asset_root(PhPaths.root())

	var config := PhConfig.new()
	var loaded := config.load_layered(config_file)

	if not loaded.ok:
		DotLog.warn(CHANNEL, "falling back to defaults", {"why": loaded.error.message})

	link = DotRegistry.get_node_service(LINK_SERVICE)
	_offline = force_offline or link == null or OS.get_cmdline_user_args().has("--offline")

	game = PhGame.new()
	game.name = "World"
	game.config = config
	game.authoritative = _offline
	game.register_service = _offline
	game.tick_rate = int(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", 64))
	game.draw_world = true
	add_child(game)

	_sampler = DotFpsSampler.new(PhPlayer.tunables_for(config))
	PhPlayer.register_actions(_sampler)

	_build_hud()
	_build_chat()
	_build_audio()
	_build_settings()
	_build_break_rules()

	if _offline:
		_start_offline()
	else:
		DotLog.result(CHANNEL, "the netcode", _build_netcode())

	if not DotPlatform.is_web():
		_capture()


func _exit_tree() -> void:
	ZeeModelCache.set_asset_root("res://")


# --- Offline ---------------------------------------------------------------

func _start_offline() -> void:
	for i in range(offline_bots):
		var bot := game.add_player(StringName("u%d" % (PhNetBridge.FIRST_BOT_SESSION + i)), _bot_name(i))
		bot.is_bot = true

	_adopt(game.add_player(&"local", "You", 0, true))
	_hear_the_world()

	game.achievement_earned.connect(func(id: StringName, title: String, points: int) -> void:
		if player != null and id == player.player_id and chat != null:
			chat.say_locally("Achievement: %s (+%d)" % [title, points], Color(0.98, 0.84, 0.40))
	)
	game.start()
	DotLog.result(CHANNEL, "chat, offline", chat.attach(null))


static func _bot_name(index: int) -> String:
	var names := PackedStringArray(["Lamp", "Ottoman", "Houseplant", "Toaster", "Bookcase", "Teddy", "Fridge", "Stool"])
	return names[index % names.size()]


# --- Connected -------------------------------------------------------------

func _build_netcode() -> DotResult:
	net = DotNetManager.new()
	net.name = "Net"
	net.is_server = false
	net.local_peer_id = multiplayer.get_unique_id() if multiplayer != null else 2
	net.auto_tick = false
	net.config_file = ""

	var net_config := DotNetConfig.new()
	net_config.tick_rate = game.tick_rate
	net_config.snapshot_rate = PhGame.NET_SNAPSHOT_RATE
	net_config.enable_prediction = true
	net_config.enable_lag_compensation = false
	net_config.max_entities_per_snapshot = 64
	net_config.world_extent = PhGame.NET_WORLD_EXTENT
	net.config = net_config
	add_child(net)

	var started := net.setup()

	if not started.ok:
		return started

	bridge = PhNetBridge.new()
	bridge.name = "Bridge"
	add_child(bridge)

	var attached := bridge.attach(game, net)

	if not attached.ok:
		return attached

	bridge.open_link(link)
	net.messages.seal()

	bridge.hello_received.connect(_on_hello)
	bridge.roster_changed.connect(_on_roster_changed)
	bridge.phase_received.connect(_on_phase)
	bridge.round_changed.connect(_on_round)
	bridge.death_received.connect(_on_death)
	bridge.armed_received.connect(_on_armed)
	bridge.map_received.connect(_on_map)
	bridge.disguise_received.connect(_on_disguise)
	bridge.taunt_received.connect(_on_taunt)
	bridge.decoy_received.connect(_on_decoy)
	bridge.notice_received.connect(func(text: String) -> void:
		if chat != null:
			chat.notice(text)
		if audio != null:
			var _denied := audio.deny())
	bridge.weapon_used_by.connect(func(session_id: int, _times: int, kind: int) -> void:
		if session_id == _watch_id or audio == null:
			return
		var who: PhPlayer = game.players.get(PhNetBridge.player_key(session_id))
		if who != null:
			var _heard := audio.on_weapon(who.global_position, kind))

	if link != null and link.has_method("ping_ms"):
		bridge.rtt_source = func() -> float:
			return float(maxi(0, int(link.call("ping_ms"))))

	DotLog.result(CHANNEL, "chat and voice", chat.attach(bridge))

	if link != null and link.has_method("is_playing") and bool(link.call("is_playing")):
		_say_ready()
	elif link != null and link.has_signal("spawned"):
		link.connect("spawned", _say_ready, CONNECT_ONE_SHOT)

	return net.start()


func _say_ready() -> void:
	if bridge != null:
		bridge.ask_ready()


func _on_hello(session_id: int) -> void:
	_watch_id = session_id
	_adopt(game.players.get(PhNetBridge.player_key(session_id)))


func _on_roster_changed(session_id: int) -> void:
	if session_id == _watch_id and player == null:
		_adopt(game.players.get(PhNetBridge.player_key(session_id)))

	if session_id == _watch_id:
		_follow_side()


func _adopt(candidate: PhPlayer) -> void:
	if candidate == null or player == candidate:
		return

	player = candidate
	_follow_side()
	_build_camera()

	if settings != null:
		settings.bind_camera(camera)
		if player.sampler != null:
			settings.bind_look(player.sampler.tunables)

	if hud != null:
		hud.bind(game, player)


## Third person for a prop, first for a hunter — unless the player chose with F5 this round.
func _follow_side() -> void:
	if player == null or _view_chosen:
		return

	var want := game.team_of(player.player_id) != PhGame.HUNTERS

	if want != third_person:
		third_person = want
		_place_camera()


# --- What the world, or the server, says --------------------------------------

## Offline: the world is the authority, so its own signals are what happened. A connected
## client hears the same from the bridge and calls the same functions with the same arguments,
## so the two can only differ in where a fact came from.
func _hear_the_world() -> void:
	game.world_rebuilt.connect(func() -> void: _on_map(game.map.id()))
	game.phase_changed.connect(_on_phase)
	game.round_began.connect(func(n: int, _map: StringName) -> void: _on_round(n, true, 0))
	game.round_over.connect(func(n: int, winner: int, why: String) -> void: _on_round(n, false, winner, why))
	game.player_died.connect(func(id: StringName, by: StringName, why: StringName) -> void:
		_on_death(_session(id), _session(by) if by != &"" else 0, why))
	game.disguise_changed.connect(func(id: StringName) -> void:
		var who: PhPlayer = game.players.get(id)
		_on_disguise(_session(id), who != null and who.set_aside != null and not who.is_disguised()))
	game.taunted.connect(func(id: StringName, taunt_id: StringName, forced: bool) -> void:
		_on_taunt(_session(id), taunt_id, forced))
	game.decoy_hit.connect(func(id: StringName, amount: float) -> void:
		if id == &"local":
			_on_decoy(amount))
	game.refused.connect(func(id: StringName, why: String) -> void:
		if id == &"local" and chat != null:
			chat.notice(why)
			if audio != null:
				var _denied := audio.deny())
	game.player_armed.connect(func(id: StringName, weapon: StringName) -> void:
		if id == &"local":
			_on_armed(_watch_id, weapon)
		else:
			_hear_rig(game.players.get(id)))
	game.side_changed.connect(func(id: StringName, _side: int) -> void:
		if id == &"local":
			_follow_side())


## The local world's ids are `local` for this keyboard and `u<session>` for everybody else.
func _session(id: StringName) -> int:
	return _watch_id if id == &"local" else PhNetBridge.session_of(id)


func _player_of(session_id: int) -> PhPlayer:
	if session_id == _watch_id and player != null:
		return player
	return game.players.get(PhNetBridge.player_key(session_id))


func _hear_rig(armed: PhPlayer) -> void:
	if armed == null or audio == null or armed.weapons == null:
		return
	if armed.weapons.used.is_connected(_on_rig_used.bind(armed)):
		return
	armed.weapons.used.connect(_on_rig_used.bind(armed))


func _on_rig_used(outcome: DotWeaponOutcome, armed: PhPlayer) -> void:
	if audio != null and is_instance_valid(armed):
		var _heard := audio.on_weapon(armed.global_position, ZeeWeaponNet.kind_number(outcome.kind))


func _on_phase(phase: int) -> void:
	if hud == null or player == null:
		return

	var hunter := is_hunter()

	match phase:
		PhGame.Phase.HIDE:
			# Only a prop puts last round's gun down. A round arms its hunters BEFORE it starts
			# the hide, so dropping every gun here took the one just handed out, and a hunter
			# sought all round with a gun nobody could see (found in a browser, 2026-10-09).
			if not hunter:
				_disarm_locally()
			_view_chosen = false
			_follow_side()
			if audio != null:
				var _heard := audio.on_hide()
			if hunter:
				hud.shout("YOU ARE A HUNTER — wait while they hide", 3.5)
			else:
				hud.shout("HIDE — %s becomes what you look at" % _key(PhBindings.DISGUISE), 3.5)
		PhGame.Phase.SEEK:
			if audio != null:
				var _heard := audio.on_seek()
			if game.effects != null:
				var _flashed := game.effects.flash(&"go")
			hud.shout("READY OR NOT" if hunter else "THE HUNTERS ARE COMING", 2.4)


func is_hunter() -> bool:
	return player != null and game != null and game.team_of(player.player_id) == PhGame.HUNTERS


func _on_map(_map_id: StringName) -> void:
	var name_of := str(game.map_doc.get("name", ""))
	hud.shout(name_of, 3.0)

	if chat != null and name_of != "":
		var author := str(game.map_doc.get("author", ""))
		var blurb := str(game.map_doc.get("blurb", ""))
		chat.say_locally("%s%s%s" % [name_of, " by %s" % author if author != "" else "",
			" — %s" % blurb if blurb != "" else ""], Color(0.80, 0.90, 1.0))


func _on_round(number: int, began: bool, winner: int, why: String = "") -> void:
	if began:
		hud.shout("ROUND %d" % number, 2.0)
		return

	if audio != null and player != null:
		var _heard := audio.on_round_end(winner != 0 and game.team_of(player.player_id) == winner)

	var who := game.side_name(winner).to_upper() + " WIN" if winner != 0 else "DRAW"
	hud.shout("%s — %s" % [who, why] if why != "" else who, 4.0)

	if chat != null and why != "":
		chat.say_locally(why, Color(0.98, 0.86, 0.40))


func _on_death(session_id: int, by: int, why: StringName) -> void:
	var who := _player_of(session_id)
	var mine := session_id == _watch_id
	var was_hunter := who != null and game.team_of(who.player_id) == PhGame.HUNTERS

	if audio != null and who != null:
		var _heard := audio.on_death(who.global_position, mine, was_hunter)

	# The furniture finished a hunter: they come apart, the way the brief asked.
	if why == PhGame.DIED_DECOY and who != null and _break_rules != null:
		var _broke := who.break_body(_break_rules, Vector3.UP, session_id * 7919 + game.round_number)

	if chat == null:
		return

	var name_of := who.display_name if who != null else "somebody"
	var hunter := _player_of(by)
	var line := "%s is out" % name_of

	match why:
		PhGame.DIED_SHOT:
			line = "%s was found by %s" % [name_of, hunter.display_name] if hunter != null else "%s was found" % name_of
		PhGame.DIED_DECOY:
			line = "%s was beaten by the furniture" % name_of
		PhGame.DIED_FELL:
			line = "%s fell" % name_of

	chat.say_locally(line, Color(0.80, 0.82, 0.86))


func _on_disguise(session_id: int, revealed: bool) -> void:
	var who := _player_of(session_id)

	if who == null:
		return

	if audio != null:
		var _heard := audio.on_disguise(who.global_position, revealed)

	if session_id == _watch_id and hud != null:
		if who.is_disguised():
			hud.shout("You are a %s" % game.props_catalogue.title_of(who.disguise.prop_id).to_lower(), 1.4)
		elif revealed:
			hud.shout("Showing yourself — %s to hide again" % _key(PhBindings.REVEAL), 1.8)

		_place_camera()


func _on_taunt(session_id: int, taunt_id: StringName, forced: bool) -> void:
	var who := _player_of(session_id)

	if who == null or game.taunts == null:
		return

	var entry := game.taunts.entry(taunt_id)

	if audio != null and not entry.is_empty():
		var _voice := audio.taunt(who, str(entry["sound"]), game.config.taunt_range)

	if session_id == _watch_id and hud != null:
		hud.shout("%s%s" % ["You stood still: " if forced else "", str(entry.get("title", ""))], 1.5)


func _on_decoy(amount: float) -> void:
	if audio != null:
		var _heard := audio.on_decoy()

	if game.effects != null:
		var _flashed := game.effects.flash(&"hurt")

	if hud != null:
		hud.shout("That was furniture (-%d)" % int(ceilf(amount)), 1.0)


func _on_armed(session_id: int, weapon_id: StringName) -> void:
	if session_id != _watch_id:
		return

	_arm_locally(weapon_id)


# --- The weapons, drawn ----------------------------------------------------

func _arm_locally(weapon_id: StringName = &"") -> void:
	if player == null:
		return

	if weapons != null:
		_select_locally(weapon_id)
		return

	if camera == null:
		_build_camera()

	if camera == null:
		return

	view_model = ZeeViewModel.new()
	view_model.name = "ViewModel"
	camera.add_child(view_model)

	weapons = ZeeWeaponRig.new()
	weapons.name = "Weapons"
	weapons.role = ZeeWeaponRig.Role.LOCAL
	weapons.authority = false
	weapons.tick_rate = game.tick_rate
	weapons.view_model_ref = DotNodeRef.of_path(view_model.get_path())
	weapons.player_ref = DotNodeRef.of_path(player.get_path())
	player.add_child(weapons)

	var ready_now := weapons.setup()

	if not ready_now.ok:
		DotLog.warn(CHANNEL, "the view model would not set up", {"why": ready_now.error.message})
		_disarm_locally()
		return

	var _given := weapons.give_everything()

	weapons.used.connect(func(outcome: DotWeaponOutcome) -> void:
		if audio != null and camera != null:
			var _heard := audio.on_weapon(camera.global_position, ZeeWeaponNet.kind_number(outcome.kind)))

	_select_locally(weapon_id)


func _select_locally(weapon_id: StringName) -> void:
	if weapons == null or weapon_id == &"" or _slot != 0:
		return

	var def := weapons.arsenal.catalogue.get_def(weapon_id)

	if def != null:
		_slot = def.slot


func _disarm_locally() -> void:
	_slot = 0

	if weapons != null:
		if is_instance_valid(player) and weapons.get_parent() == player:
			player.remove_child(weapons)
		weapons.queue_free()
		weapons = null

	if view_model != null and is_instance_valid(view_model):
		view_model.queue_free()
		view_model = null


# --- The camera ------------------------------------------------------------

func _build_camera() -> void:
	if camera != null or player == null:
		return

	camera = Camera3D.new()
	camera.name = "Eye"
	camera.fov = 90.0
	camera.current = true
	_place_camera()


## Hangs the camera where the view wants it: at the eyes, or on an arm behind a prop as far
## back as the prop is big.
func _place_camera() -> void:
	if camera == null or player == null:
		return

	if camera.get_parent() != null:
		camera.get_parent().remove_child(camera)

	if _arm != null and is_instance_valid(_arm):
		_arm.queue_free()
		_arm = null

	var eye := player.eye_position() - player.controller.state.position

	if not third_person:
		player.add_child(camera)
		_rig_height = eye.y
		camera.position = Vector3(0.0, eye.y, 0.0)
		camera.rotation = Vector3.ZERO

		if view_model != null and is_instance_valid(view_model):
			view_model.visible = true

		return

	var size := player.disguise.size if player.is_disguised() else Vector3(0.7, 1.8, 0.7)
	_arm = SpringArm3D.new()
	_arm.name = "Chase"
	_arm.spring_length = CHASE_BACK + maxf(size.x, size.z)
	# Against the building and the furniture, never the player's own prop.
	_arm.collision_mask = game.physics.layer_mask(&"world") | game.physics.layer_mask(&"prop") \
		if game.physics != null else 1
	_arm.add_excluded_object(player.get_rid())
	_arm.margin = 0.15
	_rig_height = maxf(eye.y, size.y * 0.6) + CHASE_UP
	player.add_child(_arm)
	_arm.add_child(camera)
	camera.position = Vector3.ZERO
	camera.rotation = Vector3.ZERO

	if view_model != null and is_instance_valid(view_model):
		view_model.visible = false


func toggle_view() -> void:
	third_person = not third_person
	_view_chosen = true
	_place_camera()

	if audio != null:
		var _heard := audio.click()


func _build_hud() -> void:
	hud = PhHud.new()
	hud.name = "Hud"
	hud.key_fn = _key
	add_child(hud)


## The key an action is on, as the player has it bound.
func _key(action: StringName) -> String:
	if settings != null and settings.bindings != null:
		var text := settings.bindings.key_for(action)
		if text != "":
			return text

	var row := PhBindings.make().row_for_action(action)
	return str(row.get("default", action))


# --- The Tab board ---------------------------------------------------------

func _wire_board() -> void:
	if settings == null or settings.menu == null:
		return

	board = settings.menu.scoreboard
	board.title_text = "Prop Hunt"
	board.columns = [
		{"key": &"avatar", "kind": DotMenuScoreboard.KIND_AVATAR, "width": 0.0},
		{"key": &"name", "title": "Player", "width": 3.0},
		{"key": &"points", "title": "Points", "kind": DotMenuScoreboard.KIND_NUMBER},
		{"key": &"seconds", "title": "Time", "kind": DotMenuScoreboard.KIND_DURATION},
		{"key": &"ping", "title": "Ping", "kind": DotMenuScoreboard.KIND_PING},
	]
	board.sort_by = &"points"
	board.decorate = _decorate_row
	board.prepare = _prepare_board

	if not _offline and link != null:
		board.feed_from(link)
	else:
		board.source = board_snapshot


func _show_board(on: bool) -> void:
	if board == null:
		return
	if on:
		board.open()
	else:
		board.close()


func _decorate_row(row: Dictionary) -> void:
	if game == null:
		return
	var id := PhNetBridge.player_key(int(row.get("id", 0)))
	if not game.players.has(id):
		id = StringName(str(row.get("id", "")))
	var who: PhPlayer = game.players.get(id)
	if who == null:
		return
	row["avatar"] = _face(who)
	row["points"] = who.points
	row["team"] = game.team_of(id)
	if int(row.get("ping", -1)) < 0 and who.ping_ms >= 0:
		row["ping"] = who.ping_ms
	if who == player:
		row["you"] = true


## The map in the header, and the two sides as the teams, props first.
func _prepare_board(snap: Dictionary) -> void:
	if game == null:
		return
	snap["header"] = {"Map": str(game.map_doc.get("name", "")), "Round": str(game.round_number)}
	snap["teams"] = [
		{"id": PhGame.PROPS, "name": game.side_name(PhGame.PROPS), "color": game.side_colour(PhGame.PROPS)},
		{"id": PhGame.HUNTERS, "name": game.side_name(PhGame.HUNTERS), "color": game.side_colour(PhGame.HUNTERS)},
	]


## The board offline: every player in the local world. Public so a suite can read it.
func board_snapshot() -> Dictionary:
	var rows: Array = []
	if game != null:
		for id in game.players:
			var who: PhPlayer = game.players[id]
			rows.append({"id": String(id), "name": who.display_name, "seconds": _seconds_here(), "ping": -1, "bot": who.is_bot})
	return {"server": {"name": "Prop Hunt", "game": "offline"}, "players": rows}


func _seconds_here() -> int:
	return int((Time.get_ticks_msec() - _started_msec) / 1000)


var _portraits: Dictionary = {}


func _face(who: PhPlayer) -> Texture2D:
	return _portrait(str(who.call("_atlas")))


## A player's face for the board: their figure's head, rendered once per skin. See
## mg-deathrun, where this came from.
func _portrait(atlas: String) -> Texture2D:
	if _portraits.has(atlas):
		return _portraits[atlas]

	var view := SubViewport.new()
	view.name = "Portrait%d" % _portraits.size()
	view.size = Vector2i(64, 64)
	view.own_world_3d = true
	view.transparent_bg = true
	view.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(view)

	var figure := PhFigure.new()
	view.add_child(figure)
	figure.build(1.8, atlas, Color.WHITE)
	figure.global_position = Vector3.ZERO

	var eye := Camera3D.new()
	eye.fov = 30.0
	view.add_child(eye)
	eye.look_at_from_position(Vector3(0.0, 1.55, -1.6), Vector3(0.0, 1.45, 0.0), Vector3.UP)
	eye.current = true

	var texture := view.get_texture()
	_portraits[atlas] = texture
	return texture


# --- Chat, sound, settings ---------------------------------------------------

## dot-game's chat box and microphone, with this game's channels and voice format.
func _build_chat() -> void:
	chat = DotGameChatClient.new()
	chat.name = "Chat"
	chat.channels = [
		{"id": PhServices.CH_ALL, "label": "All", "colour": Color(0.93, 0.94, 0.96)},
		{"id": PhServices.CH_TEAM, "label": "Team", "colour": Color(0.55, 0.82, 0.95)},
		{"id": PhServices.CH_NEAR, "label": "Near", "colour": Color(0.82, 0.86, 0.72)},
	]
	chat.max_length = PhServices.chat_rules().max_length
	chat.voice_config = PhServices.voice_format()
	add_child(chat)

	# Typing is not moving: the sampler polls the keyboard.
	chat.typing_changed.connect(func(typing: bool) -> void:
		_suspend_input(typing or (settings != null and settings.is_open())))


func _build_audio() -> void:
	audio = PhAudio.new()
	audio.name = "Sound"
	add_child(audio)

	var ready_now := audio.setup()

	if not ready_now.ok:
		DotLog.warn(CHANNEL, "no sound", {"why": ready_now.error.message})
		remove_child(audio)
		audio.queue_free()
		audio = null


func _build_settings() -> void:
	settings = PhSettings.new()
	add_child(settings)

	var built: DotResult = settings.setup()

	if not built.ok:
		DotLog.warn(CHANNEL, "no settings; everything is at its default", {"why": built.error.message})
		remove_child(settings)
		settings.free()
		settings = null
		return

	if _sampler != null:
		settings.bind_look(_sampler.tunables)

	if audio != null:
		settings.bind_audio(audio.manager)

	if settings.menu != null:
		settings.menu.picker_action = PhBindings.TAUNT_MENU
		settings.menu.scoreboard_action = PhBindings.SCOREBOARD
		settings.menu.picked.connect(_on_taunt_picked)
		settings.menu_state_changed.connect(func(any_open: bool) -> void:
			_suspend_input(any_open or (chat != null and chat.is_typing()))
			if any_open:
				_release()
			elif not DotPlatform.is_web():
				_capture())
		settings.menu.busy = func() -> bool: return chat != null and chat.is_typing()
		_wire_board()


func _build_break_rules() -> void:
	if game.config.hunter_break == 0:
		return

	_break_rules = DotPlayerBreakRules.new()
	_break_rules.mode = DotPlayerBreakRules.Mode.EXPLODE if game.config.hunter_break == 2 \
		else DotPlayerBreakRules.Mode.LIMBS
	_break_rules.limbs = 3
	_break_rules.criticals_only = false
	_break_rules.force = 7.0
	_break_rules.lift = 4.0
	_break_rules.collision_mask = game.physics.layer_mask(&"world") | game.physics.layer_mask(&"prop") \
		if game.physics != null else 1


func _suspend_input(suspended: bool) -> void:
	if _sampler != null:
		_sampler.suspended = suspended

	if player != null and player.sampler != null:
		player.sampler.suspended = suspended


func _capture() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_captured = true


func _release() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_captured = false


# --- Asking ----------------------------------------------------------------

func ask_disguise() -> void:
	if bridge != null:
		bridge.ask_disguise()
	elif player != null:
		var _became := game.request_disguise(player.player_id)


func ask_reveal() -> void:
	if bridge != null:
		bridge.ask_reveal()
	elif player != null:
		var _shown := game.reveal(player.player_id)


func ask_turn(how: int) -> void:
	if bridge != null:
		bridge.ask_turn(how)
	elif player != null:
		var _turned := game.turn(player.player_id, how)


func ask_taunt(taunt_id: StringName = &"") -> void:
	if bridge != null:
		bridge.ask_taunt(taunt_id)
	elif player != null:
		var _said := game.taunt(player.player_id, taunt_id)


func open_taunts() -> void:
	if settings == null or settings.menu == null or game.taunts == null:
		return

	var items: Array = []

	for id in game.taunt_ids():
		var entry := game.taunts.entry(id)
		items.append({"id": id, "name": str(entry.get("title", id)), "tags": ["%.1f s" % float(entry.get("seconds", 0.0))]})

	settings.menu.open_picker(items, "Taunt")


func _on_taunt_picked(id: StringName) -> void:
	if game.taunts != null and game.taunts.has(id):
		ask_taunt(id)


# --- The frame -------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if _offline:
		_drive_offline()
		return

	if net == null or not net.is_running() or bridge == null:
		return

	var move := _sampler.sample(delta) if _sampler != null else DotFpsCommand.new()
	_stamp(move)

	var ticks := net.clock.advance(delta)

	for i in range(ticks):
		if not net.clock.is_synced():
			continue

		bridge.client_tick(net.clock.input_tick() - (ticks - 1 - i), move, _slot)

	_drive_view_model(move)


func _drive_offline() -> void:
	if player == null or player.sampler == null:
		return

	var pending := player.controller.current_command

	if pending != null:
		_stamp(pending)
		player.wanted_slot = _slot

	_drive_view_model(pending)


func _stamp(command: DotFpsCommand) -> void:
	if command == null:
		return

	command.set_button(PhNetCommand.BUTTON_FIRE, _firing)
	command.set_button(PhNetCommand.BUTTON_ALT, _alt)
	command.set_button(PhNetCommand.BUTTON_RELOAD, _reloading)


func _drive_view_model(command: DotFpsCommand) -> void:
	if weapons == null or player == null:
		return

	var weapon_command := DotWeaponCommand.new()

	if command != null:
		weapon_command.set_button(DotWeaponCommand.BUTTON_ATTACK, command.is_pressed(PhNetCommand.BUTTON_FIRE))
		weapon_command.set_button(DotWeaponCommand.BUTTON_ALT, command.is_pressed(PhNetCommand.BUTTON_ALT))
		weapon_command.set_button(DotWeaponCommand.BUTTON_RELOAD, command.is_pressed(PhNetCommand.BUTTON_RELOAD))
		weapon_command.yaw = command.yaw
		weapon_command.pitch = command.pitch

	weapon_command.slot = _slot
	var _outcome := weapons.simulate_tick(weapon_command, game.round_number * 100000 + Engine.get_physics_frames())


func _process(delta: float) -> void:
	var _shown := present_frame(net, game, player, not third_person, delta, -1.0, _watched_through_eyes())
	_present_hide()

	if camera == null or player == null:
		return

	if _drive_spectator_camera():
		_present_effects(delta)
		return

	var state := player.controller.state
	var pitch := deg_to_rad(state.pitch)
	var yaw := deg_to_rad(state.yaw)
	var rig: Node3D = _arm if _arm != null and is_instance_valid(_arm) else camera

	if weapons != null:
		var punch := weapons.view_punch()
		pitch += deg_to_rad(punch.x)
		yaw += deg_to_rad(punch.y)

	rig.rotation = Vector3(pitch, yaw, 0.0)

	var drawn := player.controller.render_state()
	rig.global_position = drawn.position + Vector3(0.0, _rig_height, 0.0)

	if weapons != null:
		var speed := Vector2(state.velocity.x, state.velocity.z).length()
		weapons.drive_view(Vector2(state.yaw, state.pitch), speed, state.mode != DotFpsState.Mode.AIR, state.crouch_fraction > 0.5)

	_present_effects(delta)


## The last seconds of the hide, beeped.
func _present_hide() -> void:
	if game == null or game.phase != PhGame.Phase.HIDE:
		_beeped = -1
		return

	var second := int(ceilf(game.seconds_left()))

	if second != _beeped and second <= 5 and second > 0:
		_beeped = second

		if audio != null:
			var _heard := audio.on_countdown()


func _present_effects(delta: float) -> void:
	if audio != null:
		audio.listen_from(camera.global_position)

	if game.effects != null:
		game.effects.viewer_position = camera.global_position
		game.effects.advance(delta)


# --- Watching, once out -----------------------------------------------------

func is_spectating() -> bool:
	return player != null and game != null and game.spectate != null \
		and game.spectate.is_spectating(player.player_id)


func _watched_through_eyes() -> PhPlayer:
	if not is_spectating():
		return null

	var mode := game.spectate.mode_of(player.player_id)

	if mode != DotSpectatorView.Mode.FIRST_PERSON and mode != DotSpectatorView.Mode.FREEZE_CAM:
		return null

	return game.players.get(game.spectate.watching(player.player_id))


func _drive_spectator_camera() -> bool:
	if not is_spectating():
		if camera.get_parent() == self:
			_place_camera()

		if hud != null:
			hud.set_watching("")

		return false

	if camera.get_parent() != self:
		camera.get_parent().remove_child(camera)
		add_child(camera)
		camera.current = true

		if _arm != null and is_instance_valid(_arm):
			_arm.queue_free()
			_arm = null

	if view_model != null and is_instance_valid(view_model):
		view_model.visible = false

	var where := game.spectate.camera_for(player.player_id)

	if where != Transform3D.IDENTITY:
		camera.global_transform = where

	if hud != null:
		hud.set_watching(game.spectate.line_for(player.player_id))

	return true


func spectate_step(direction: int) -> void:
	if audio != null:
		var _heard := audio.click()

	if bridge != null:
		bridge.ask_spectate(direction)
		return

	if game == null or game.spectate == null or player == null:
		return

	var moved := game.spectate.step(player.player_id, direction)

	if not moved.ok and chat != null:
		chat.notice(moved.error.message)


## Everything a frame draws that a tick does not, in this order: the netcode's interpolation,
## then every player — a person or the prop they are — then every beacon. Returns how many are
## shown. Static so the net suite drives exactly this and not a copy of it.
##
## [param first_person] is whether [param own]'s camera is behind their eyes, which hides their
## own body. A prop is always drawn to its own player in third person: that is what a prop is
## looking at.
static func present_frame(
	p_net: DotNetManager,
	p_game: PhGame,
	own: PhPlayer,
	first_person: bool,
	delta: float,
	alpha: float = -1.0,
	watched: PhPlayer = null
) -> int:
	var networked := p_net != null and p_net.is_running()

	if networked:
		p_net.interpolate_frame(alpha)

	if p_game == null:
		return 0

	var shown := 0
	var period := p_game.config.beacon_period if p_game.config != null else 2.0

	for key: StringName in p_game.players:
		var body: PhPlayer = p_game.players[key]

		if body == null or not is_instance_valid(body) or not body.is_inside_tree():
			continue

		var mine := body == own
		var at := drawn_position(body, networked and not mine)
		var colour := p_game.side_colour(p_game.team_of(key))
		var hidden := (mine and first_person) or body == watched

		if body.present_body(hidden, at, colour):
			shown += 1

		var _pinged := body.present_beacon(delta, at, mine and first_person, period)

	return shown


static func drawn_position(body: PhPlayer, remote: bool) -> Vector3:
	if remote or body.controller == null:
		return body.global_position

	return body.controller.render_state().position


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and not _captured:
		_capture()
		return

	if event.is_action_pressed("ui_cancel"):
		_release()
		if settings != null:
			settings.open()
		return

	if event.is_action(PhBindings.SCOREBOARD) and not event.is_echo():
		_show_board(event.is_pressed())
		return

	if event is InputEventKey and (event as InputEventKey).pressed and not event.is_echo():
		if _key_pressed(event):
			get_viewport().set_input_as_handled()
			return

	if event.is_action_released(PhBindings.RELOAD):
		_reloading = false

	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton

		if is_spectating():
			_firing = false
			_alt = false

			if button.pressed and button.button_index == MOUSE_BUTTON_LEFT:
				spectate_step(1)
			elif button.pressed and button.button_index == MOUSE_BUTTON_RIGHT:
				spectate_step(-1)
			return

		if button.button_index == MOUSE_BUTTON_LEFT:
			_firing = button.pressed and is_hunter()
		elif button.button_index == MOUSE_BUTTON_RIGHT:
			_alt = button.pressed and is_hunter()

	if player == null:
		return

	if event is InputEventMouseMotion and _captured:
		if _offline and player.sampler != null:
			player.sampler.handle_event(event)
		elif _sampler != null:
			_sampler.handle_event(event)


## The game's own keys, from the bindings. True when one was used.
func _key_pressed(event: InputEvent) -> bool:
	if event.is_action_pressed(PhBindings.VIEW):
		if is_spectating():
			spectate_step(0)
		else:
			toggle_view()
		return true

	if player == null or not player.is_alive() or is_spectating():
		return false

	if is_hunter():
		if event.is_action_pressed(PhBindings.RELOAD):
			_reloading = true
			return true

		var key := (event as InputEventKey).physical_keycode

		if key >= KEY_1 and key <= KEY_5:
			_slot = key - KEY_1 + 1
			return true

		return false

	if event.is_action_pressed(PhBindings.DISGUISE):
		ask_disguise()
	elif event.is_action_pressed(PhBindings.REVEAL):
		ask_reveal()
	elif event.is_action_pressed(PhBindings.LOCK):
		ask_turn(PhGame.Turn.LOCK)
	elif event.is_action_pressed(PhBindings.TAUNT):
		ask_taunt()
	elif event.is_action_pressed(PhBindings.TAUNT_MENU):
		open_taunts()
	elif event.is_action_pressed(PhBindings.TILT_FORWARD):
		ask_turn(PhGame.Turn.TILT_FORWARD)
	elif event.is_action_pressed(PhBindings.TILT_BACK):
		ask_turn(PhGame.Turn.TILT_BACK)
	elif event.is_action_pressed(PhBindings.TILT_LEFT):
		ask_turn(PhGame.Turn.TILT_LEFT)
	elif event.is_action_pressed(PhBindings.TILT_RIGHT):
		ask_turn(PhGame.Turn.TILT_RIGHT)
	elif event.is_action_pressed(PhBindings.STRAIGHTEN):
		ask_turn(PhGame.Turn.STRAIGHTEN)
	else:
		return false

	return true


func describe() -> Dictionary:
	var out := {
		"offline": _offline,
		"session": _watch_id,
		"player": player != null,
		"view": "third" if third_person else "first",
		"armed": weapons != null,
	}

	if bridge != null:
		out["bridge"] = bridge.describe()

	if chat != null:
		out["chat"] = chat.describe()

	if game != null:
		out["world"] = game.describe()

	return out
