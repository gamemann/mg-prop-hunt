extends DotGameModule

const PhNetBridge := preload("net/ph_net_bridge.gd")
const PhServices := preload("ph_services.gd")

const PhGame := preload("ph_game.gd")
const PhPlayer := preload("ph_player.gd")
const PhAvatars := preload("ph_avatars.gd")
const PhVote := preload("ph_vote.gd")

## This game, as a module a dedicated server loads.
##
## [b]A hundred and forty lines, against the five hand-written modules' 837 to 1,816.[/b]
## [DotGameModule] holds the netcode and its four load-bearing constants, the bridge, the
## message seal, the identity layer, the roster, the authoritative tick and a teardown in
## the reverse order. Two of those five hand-written copies had the same line wrong and
## nobody could ever join those servers. What is left here is what is actually this game's:
## the cvars an operator turns between rounds, the console commands, the map vote, and the rule
## that keeps enough people in a round for one to happen.
##
## [b]No `class_name`, and that is a requirement rather than a style.[/b]
## [method DotModuleHost.load_module] takes a PATH and constructs the module itself — it
## must, because that is the shape that lets an operator name one in a config file — and a
## module delivered inside a dot-cloud pack cannot have a `class_name` at all: a mounted
## pack's globals are not registered in the host.
##
## [codeblock]
## server.modules.load_module("res://game/ph_module.gd")
## [/codeblock]

# [b]No `const CHANNEL` here, and its absence is the point.[/b] [DotGameModule] already
# declares one and GDScript refuses to let a subclass redeclare it — which is the right
# refusal: a module logs through [method DotModule.log_info], which stamps the module's own
# name, so a second channel would split one module's records across two places an operator
# has to know to turn up separately.

## Seconds between checks of how many people are in the round.
const ROSTER_INTERVAL := 2.0

## Where the services keep punishments. Empty is [DotGameServices]'s own default,
## `user://prophunt_punishments.json` — the store a real server enforces.
##
## [b]Static, because nothing holds this module before it exists[/b]: dot-server constructs
## it from a path inside `load_module`, so there is no instance for a host to set a field on
## first. `examples/dedicated.tscn` points it at a directory of its own; before it could,
## every run appended the live tools' audit warnings to the real store, 106 of them by the
## time anybody counted.
static var punishments_file: String = ""

## The `ph_bots` cvar, held so the tick does not look it up sixty times a second.
var _bots: DotConVar = null

var _since_roster_check: float = 0.0

## How many stand-ins this module has put in, so it can take them out again.
var _bot_ids: Array[StringName] = []

## The players' vote for the next map; null when it could not be built.
var vote: PhVote = null

## The drawn ballot's notice topic. The client shell draws one menu per topic.
const MAP_BALLOT_TOPIC := &"map_ballot"


func _module_name() -> String:
	return "prophunt"


func _game_service() -> StringName:
	return PhGame.SERVICE


func _game_missing_hint() -> String:
	return (
		"create an PhGame, add it to the tree and let its _ready() register it under "
		+ "'%s' — a module cannot build the world, because the world outlives it"
		% String(PhGame.SERVICE)
	)


## The netcode's numbers, which are the game's and not the addon's.
##
## Tick rate from the world, so `sv_tickrate` reaches it: the server sets the engine's
## physics rate from that cvar at boot, the world is built after the server and reads it,
## and this reads the world. A number written here instead would be a netcode running at a
## rate the operator did not choose, silently.
func _net_config() -> DotNetConfig:
	var config := DotNetConfig.new()
	config.tick_rate = (game as PhGame).tick_rate
	config.snapshot_rate = PhGame.NET_SNAPSHOT_RATE
	config.world_extent = PhGame.NET_WORLD_EXTENT
	config.enable_prediction = true
	# [b]On, and the two callables that make it real are wired by the bridge.[/b] It was off
	# for as long as they were not: a flag reported as enabled with nothing behind it is
	# worse than one that is off, because the first reader to trust it loses an afternoon.
	# See [method PhNetBridge._wire_lag_compensation].
	#
	# A hunter shooting a prop that is running across a room is the ordinary reason to want it.
	config.enable_lag_compensation = true
	# Everybody playing, and nothing else: the furniture is the map document, not entities, so
	# a snapshot is a full server's players and room to spare.
	config.max_entities_per_snapshot = 64
	return config


func _make_bridge() -> Node:
	return PhNetBridge.new()


## Chat, voice and moderation, over [DotGameServices].
##
## [b]The bridge is handed over as the link, and that is the whole of the wiring.[/b] A chat
## line goes out through `send_chat` and a voice frame through `send_voice`, both on this
## game's own wire. [DotGameModule] does the rest: it assigns the bridge's `voice_relay_fn`,
## checks `check_admission` before seating anybody, and tells the roster to follow this layer
## so a leaver is forgotten by the rate limiter and the voice router together.
func _make_services() -> Node:
	var services := PhServices.new()
	services.bridge = bridge
	services.punishments_file = punishments_file
	return services


## Profiles, avatars and admission: dot-platform's [DotPlatformIdentity] over this game's
## one-slot schema. [DotGameModule] builds it before the services and loads dot-platform's
## own module beside it.
##
## [b]Authentication is not here and was never this game's.[/b] Whether a player is proven
## to be somebody is the host's `dot_auth_server`, the same for every game it runs; what
## this layer does is everything after — a scoped profile, the name on it, and a face.
## With authentication off everybody is a guest with a profile of their own, which is what
## a LAN server is.
func _make_identity() -> Node:
	var identity_layer := DotPlatformIdentity.new()
	identity_layer.avatar_schema = PhAvatars.schema()
	identity_layer.stock_avatar_fn = PhAvatars.stock_avatar
	identity_layer.avatar_translate_fn = PhAvatars.from_site
	return identity_layer


func _game_load() -> DotResult:
	var world := game as PhGame

	if world == null:
		return DotResult.fail(DotError.CODE_STATE, "The registered game is not an PhGame.")

	add_command("ph_status", _cmd_status, "Show the round, the map and who is hiding as what")
	add_command("ph_net", _cmd_net, "Show what the netcode is doing")
	add_command("ph_maps", _cmd_maps, "List the maps, and any refused file")
	add_command("ph_reload", _cmd_reload, "Read the map directory again (from the next map)")
	add_command("ph_taunts", _cmd_taunts, "List the taunts")
	add_command("ph_map", _cmd_map, "Play a map next: ph_map <id> (at the end of this round)", "")
	# A player's wish for the next draw, from chat as !hunter / !prop / !any.
	add_command("hunter", _cmd_wish.bind(PhGame.HUNTERS), "Ask to hunt in the next draw", "")
	add_command("prop", _cmd_wish.bind(PhGame.PROPS), "Ask to hide in the next draw", "")
	add_command("any", _cmd_wish.bind(0), "Either side in the next draw", "")
	add_command("ph_say", _cmd_say, "Say something to everybody, as the server")

	_wire_chat()
	_wire_identity()
	_wire_map(world)
	_wire_progress(world)
	_add_tunables(world)
	_build_vote(world)

	_bots = add_cvar(
		"ph_bots", "1",
		"Keep the round full with stand-ins. 0 leaves the server as empty as it is."
	)

	# [b]Started here and not in the world's own `_ready`.[/b] `start()` builds the map and puts
	# everybody on it, and a world that did that before the bridge existed would have built a
	# map with nothing listening to `world_rebuilt` — one the server knows about and no client
	# is ever told about. Invisible floors: a player stands on nothing and the server says they
	# are fine.
	var _delivered: int = await _add_delivered_maps(world)
	world.start()

	log_info("the map is up", world.describe())
	return DotResult.success(null)


## The maps the SERVER names for this game, fetched and added to the catalogue. Returns how
## many documents they held.
##
## [b]The server's list, not this game's.[/b] A map pack used to be a `server_dependencies`
## entry in `game.yml`, which travels in this game's own pack — so a new map meant a release
## of the game, and a server owner could not choose which maps to run. The owner names them
## now in their deployment's map config (dot-server-deploy's `cfg/content.yml`, which fills
## [member DotGameDescriptor.maps]); [DotGameContent] fetches each pack and hands back its
## `maps/` directory. A server that still names one under `server_dependencies` keeps working,
## because DotGameContent reads those too.
##
## [b]Still server-only.[/b] The server sends the map it is playing in MAP, so a client never
## needs a map file and none of these is in a client's content sync. With nothing named, this
## game plays its built-in map.
##
## [b]Called after EVERY catalogue load[/b], not only the first: `load_from` forgets everything
## read before, and a reload that did not come back here dropped every delivered map — which
## is what mg-wipeout and mg-deathrun did until the three were moved onto DotGameContent.
func _add_delivered_maps(world: PhGame) -> int:
	if server == null or world.catalogue == null:
		return 0

	var read := 0

	for root in await DotGameContent.map_dirs(server, "maps"):
		read += world.catalogue.add_directory(root)

	return read


## Who somebody is reaches the world: a face as they are seated, and the real name and face
## once dot-platform has them. All three events end in [method PhNetBridge.refresh_player].
func _wire_identity() -> void:
	var link := bridge as PhNetBridge

	if link == null:
		return

	link.avatar_fn = _avatar_for
	hook_post("player_admitted", _on_profile)
	hook_post("player_avatar_changed", _on_profile)
	hook_post("player_renamed", _on_profile)


## What a session looks like: what dot-platform resolved for them, or the stock person.
##
## [b]Through the platform module's `player_for`, and never the hub by a key made here.[/b]
## The hub keys a player by their scoped profile key, which only admission knows; a lookup
## by `u<session>` finds nobody, every time, and falls through to stock — which reads as
## "this player has no avatar" rather than as a wrong key. Duck-typed, because a server
## without dot-platform is a configuration.
func _avatar_for(session_id: int) -> DotAvatar:
	var session := server.session_by_userid(session_id) if server != null else null
	var platform: Object = server.modules.get_module("platform") \
		if server != null and server.modules != null else null

	if session != null and platform != null and platform.has_method("player_for"):
		var player: Variant = platform.call("player_for", session)

		if player is Object and (player as Object).get("avatar") is DotAvatar:
			return (player as Object).get("avatar") as DotAvatar

	if identity != null and identity.has_method("avatar_for"):
		return identity.call("avatar_for", String(PhNetBridge.player_key(session_id)))

	return null


func _on_profile(event: DotEvent) -> void:
	var session_id := event.get_int("userid")
	var session := server.session_by_userid(session_id) if server != null else null
	var link := bridge as PhNetBridge

	if session == null or link == null:
		return

	link.refresh_player(session_id, session.display_name, _avatar_for(session_id))


## The numbers an operator is actually going to want to change, as cvars.
##
## [b]Live, and each one writes through to the configuration the world already reads.[/b] A
## server owner finds their server's balance by moving one of them between rounds with people
## watching; a JSON file and a restart is a balance nobody tunes.
##
## [b]What is NOT here is anything the round has already decided.[/b] `ph_players_per_hunter`
## changes how many are drawn for the NEXT round; it does not hand somebody a gun now.
func _add_tunables(world: PhGame) -> void:
	var config := world.config

	_tunable("ph_hide_seconds", config.hide_seconds,
		"Seconds the props have to hide while the hunters are blindfolded",
		func(value: float) -> void: config.hide_seconds = clampf(value, 0.0, 180.0))
	_tunable("ph_round_seconds", config.round_seconds,
		"Seconds the hunters have to find everybody (a map may ask for less)",
		func(value: float) -> void: config.round_seconds = clampf(value, 30.0, 1800.0))
	_tunable("ph_timeout_winner", float(config.timeout_winner),
		"Who wins when the clock runs out: 0 nobody, 1 the props, 2 the hunters",
		func(value: float) -> void: config.timeout_winner = clampi(int(value), 0, 2))
	_tunable("ph_players_per_hunter", config.players_per_hunter,
		"One hunter for every this many players, from the next round",
		func(value: float) -> void: config.players_per_hunter = clampf(value, 1.0, 32.0))
	_tunable("ph_min_hunters", float(config.min_hunters),
		"The fewest hunters a round has, from the next round",
		func(value: float) -> void: config.min_hunters = clampi(int(value), 1, config.max_hunters))
	_tunable("ph_max_hunters", float(config.max_hunters),
		"The most hunters a round has, from the next round",
		func(value: float) -> void: config.max_hunters = clampi(int(value), config.min_hunters, 32))
	_tunable("ph_hunter_pick", float(config.hunter_pick),
		"How hunters are chosen: 0 random, 1 an equal share each, 2 the sides swap",
		func(value: float) -> void: config.hunter_pick = clampi(int(value), 0, 2))
	_tunable("ph_side_choice", 1.0 if config.allow_side_choice else 0.0,
		"Whether !hunter and !prop count in the draw",
		func(value: float) -> void: config.allow_side_choice = value > 0.5)
	_tunable("ph_auto_taunt_seconds", config.auto_taunt_seconds,
		"Seconds a prop may stand still before a taunt is forced (0 never)",
		func(value: float) -> void:
			config.auto_taunt_seconds = clampf(value, 0.0, 600.0)
			if world.taunts != null:
				world.taunts.auto_after = config.auto_taunt_seconds)
	_tunable("ph_auto_taunt_radius", config.auto_taunt_radius,
		"Metres a prop must move for that to count as moving",
		func(value: float) -> void:
			config.auto_taunt_radius = clampf(value, 0.1, 20.0)
			if world.taunts != null:
				world.taunts.auto_radius = config.auto_taunt_radius)
	_tunable("ph_taunt_points", float(config.taunt_points),
		"Points for a taunt a prop chose",
		func(value: float) -> void:
			config.taunt_points = clampi(int(value), 0, 100)
			if world.taunts != null:
				world.taunts.points_voluntary = config.taunt_points)
	_tunable("ph_forced_taunt_points", float(config.forced_taunt_points),
		"Points for a taunt forced on a prop that stood still",
		func(value: float) -> void:
			config.forced_taunt_points = clampi(int(value), 0, 100)
			if world.taunts != null:
				world.taunts.points_forced = config.forced_taunt_points)
	_tunable("ph_reveal_cooldown", config.reveal_cooldown,
		"Seconds before a prop may show its face again after hiding",
		func(value: float) -> void:
			config.reveal_cooldown = clampf(value, 0.0, 600.0)
			world.rules.reveal_cooldown = config.reveal_cooldown)
	_tunable("ph_reveal_points", config.reveal_points_per_second,
		"Points a second a prop earns showing its face",
		func(value: float) -> void:
			config.reveal_points_per_second = clampf(value, 0.0, 100.0)
			world.rules.reveal_points_per_second = config.reveal_points_per_second)
	_tunable("ph_beacon_props_left", float(config.beacon_props_left),
		"Beacon every prop still alive once this few are left (0 never)",
		func(value: float) -> void: config.beacon_props_left = clampi(int(value), 0, 32))
	_tunable("ph_beacon_seconds_left", config.beacon_seconds_left,
		"Beacon every prop still alive once this few seconds are left (0 never)",
		func(value: float) -> void: config.beacon_seconds_left = clampf(value, 0.0, 600.0))
	_tunable("ph_decoy_penalty", config.decoy_penalty,
		"Share of a shot's damage a hunter takes for hitting real furniture (0 off)",
		func(value: float) -> void: config.decoy_penalty = clampf(value, 0.0, 5.0))
	_tunable("ph_rounds_per_map", float(config.rounds_per_map),
		"Rounds on a map before the next one",
		func(value: float) -> void: config.rounds_per_map = clampi(int(value), 1, 50))
	_tunable("ph_gravity", config.gravity, "Metres per second squared, for everything",
		func(value: float) -> void: config.gravity = value)
	_tunable("ph_autobhop", 1.0 if config.auto_bunny_hop else 0.0,
		"Whether holding jump hops again on landing, from the next round",
		func(value: float) -> void:
			config.auto_bunny_hop = value > 0.5
			for id: StringName in world.players:
				(world.players[id] as PhPlayer).retune())
	_tunable("ph_spectate_camera", float(config.spectate_camera),
		"Who somebody who is out may watch: 0 anybody, 1 their own side, 2 nobody",
		func(value: float) -> void:
			config.spectate_camera = clampi(int(value), 0, 2)
			if world.spectate != null:
				world.spectate.set_force_camera(config.spectate_camera))
	_tunable("ph_min_players", float(config.minimum_players),
		"How many players the server keeps in a round with stand-ins",
		func(value: float) -> void: config.minimum_players = clampi(int(value), 0, 24))
	_tunable("ph_bot_suspicion", config.bot_suspicion,
		"Chance in a hundred, a second, that a stand-in hunter shoots something it suspects",
		func(value: float) -> void: config.bot_suspicion = clampf(value, 0.0, 100.0))


## A number as an operator would type it: `34`, not `34.000000`.
##
## [b]Not `%g`, which GDScript's format strings do not have.[/b] It is accepted by the parser
## and fails at RUNTIME with "unsupported format character" — inside `_game_load`, which is
## the one place in the module sequence that unwinds everything above it. The symptom in
## game-buses-from-hell was a server whose netcode came up, logged that it was ready, and
## then reported that the game would not load.
static func _number(value: float) -> String:
	return "%d" % int(round(value)) if is_equal_approx(value, round(value)) else "%.3f" % value


## One cvar, its default taken from the configuration rather than written twice.
##
## [b]The default is the value the world was built with, and that is the whole point.[/b] A
## cvar declared with a literal default is a second copy of a number that
## `defaults < JSON < environment < argv` has already decided — so an operator who set
## `PH_ROUND_SECONDS=240` would see `ph_round_seconds` report 300 and, worse, would reset
## their own setting the moment anything wrote the value back.
func _tunable(
	cvar_name: String, current: float, description: String, apply: Callable
) -> void:
	var cvar := add_cvar(cvar_name, _number(current), description)

	if cvar == null:
		return

	cvar.changed.connect(func(_old: String, _new: String) -> void:
		apply.call(cvar.get_float())
		log_info("a tunable changed", {"cvar": cvar_name, "now": cvar.get_string()})
	)


## [b]Nothing to undo.[/b] The commands are the module's own and [DotModule] removes them;
## the netcode, the bridge and the roster are [DotGameModule]'s and it tears them down in
## the reverse order it built them. The world is NOT this module's to free: it was in the
## tree before the module loaded, and a server can unload and reload a game module without
## the map going away, which is what `module reload` is for.
func _game_unload() -> void:
	_bot_ids.clear()

	if vote != null:
		vote.queue_free()
		vote = null


## The server slept or woke. The vote's director follows it on its own (DotGameModule finds
## it); the map ballot's timer is this game's, so it starts again here on waking.
func _game_hibernation(hibernating: bool) -> void:
	if not hibernating and vote != null:
		vote.note_woke()


## Keeps enough people in the round for there to be one.
##
## [b]A hunter and a prop, or nothing happens at all.[/b] A round ends the moment a side has
## nobody alive, and a side with nobody AT ALL satisfies that on the first tick — so a server
## with one person on it would start a round, end it and start another for as long as nobody
## else joined. Every one of those rounds is decided correctly, which is why nothing errors.
##
## A stand-in is removed the moment a person takes their place. They are here to make the
## game exist, not to take the fun half from the people who came to play it.
func _game_tick(_tick: int, delta: float) -> void:
	if vote != null:
		vote.advance(delta)

	_since_roster_check += delta

	if _since_roster_check < ROSTER_INTERVAL:
		return

	_since_roster_check = 0.0
	_keep_the_round_full()
	_note_pings()


## Each session's ping onto its player, for the Tab board. dot-server already keeps it.
func _note_pings() -> void:
	var world := game as PhGame
	if world == null or server == null:
		return
	for session in server.playing_sessions():
		var who: PhPlayer = world.players.get(PhNetBridge.player_key(session.userid))
		if who != null:
			who.ping_ms = session.ping_ms


func _keep_the_round_full() -> void:
	var world := game as PhGame

	if world == null or bridge == null or _bots == null or not _bots.get_bool():
		return

	var wanted := world.config.minimum_players
	var humans := 0

	for id: StringName in world.players:
		if not (world.players[id] as PhPlayer).is_bot:
			humans += 1

	# Forget any that have gone for some other reason — a round reset, an admin — so the
	# count below is of stand-ins that actually exist.
	for index in range(_bot_ids.size() - 1, -1, -1):
		if not world.players.has(_bot_ids[index]):
			_bot_ids.remove_at(index)

	var short := wanted - humans - _bot_ids.size()

	for _i in range(maxi(short, 0)):
		var bot: PhPlayer = bridge.call("add_bot", _bot_name())

		if bot == null:
			break

		_bot_ids.append(bot.player_id)

	for _i in range(maxi(humans + _bot_ids.size() - wanted, 0)):
		if _bot_ids.is_empty():
			break

		var leaving: StringName = _bot_ids.pop_back()
		bridge.call("remove_player", PhNetBridge.session_of(leaving))


## Names for the stand-ins, so a scoreboard of four of them is readable.
static func _bot_name() -> String:
	var names := PackedStringArray([
		"Lamp", "Ottoman", "Houseplant", "Toaster", "Bookcase", "Teddy", "Fridge", "Stool",
	])
	return String(names[randi() % names.size()])


## Joins the bridge's chat seam to the services layer's router.
##
## [b]Here rather than in either of them, because this is the only object that holds
## both.[/b] The bridge knows what arrived on the wire and nothing about what a line means;
## the services layer knows the rules and nothing about the wire. That separation is why a
## client cannot send a line with somebody else's name on it: what crosses is a channel id
## and a string, and everything else is decided on this side.
func _wire_chat() -> void:
	if bridge == null or services == null:
		return

	bridge.connect("say_requested", _on_say_requested)
	services.connect("command_entered", _on_chat_command)


## The players' vote for the next map, over dot-vote: `!vote`, `!rtv`, `!nominate`.
##
## [b]Opened [member PhVote.open_after_sec] into the last round on a map and applied when that
## round ends[/b]; see [code]game/ph_vote.gd[/code]. A server owner turns it off or reshapes it
## in `user://cfg/prophunt_vote.json` or `game.yml`'s `metadata: map_vote:`, keyed as dot-vote's
## [DotVoteRules]. A vote that cannot be built is a WARN and the rotation alone, never a server
## that will not start.
func _build_vote(world: PhGame) -> void:
	if world.catalogue == null:
		return

	vote = PhVote.new()
	vote.name = "MapVote"
	vote.maps_fn = func() -> Array:
		var out: Array = []

		for id in world.catalogue.playable(world.config.map_ids):
			out.append([id, str((world.catalogue.maps.get(id, {}) as Dictionary).get("name", id))])

		return out
	vote.apply_fn = func(id: StringName) -> DotResult:
		world.next_map_id = id
		return DotResult.success(id)
	vote.due_fn = func() -> bool:
		return world.rounds_left_on_map() <= 1
	vote.voters_fn = func() -> Array:
		var out: Array = []

		for id: Variant in world.players:
			var player: PhPlayer = world.players[id]

			if player == null or player.is_bot:
				continue

			var userid := PhNetBridge.session_of(StringName(str(id)))

			if userid > 0:
				out.append(StringName(str(userid)))

		return out
	vote.announce_fn = func(line: String) -> void:
		var chat: Object = services.get("chat") if services != null else null

		if chat != null:
			var _said: Variant = chat.call("announce", line, PhServices.CH_ALL)
		elif server != null:
			server.broadcast_message(line)
	vote.is_admin_fn = func(voter: StringName) -> bool:
		var session := server.session_by_userid(String(voter).to_int()) if server != null else null
		return session != null and session.has_permission(DotAdminFlags.CHANGEMAP)
	vote.ballot_fn = func(state: Dictionary) -> void:
		if server == null:
			return

		for session in server.playing_sessions():
			var data := state.duplicate()
			data["you"] = str(session.userid)
			server.send_notice(session, DotNotice.make(
				&"", "", float(state.get("seconds", -1.0)), MAP_BALLOT_TOPIC, data
			))
	vote.people_fn = func(voter: StringName) -> Dictionary:
		var session := server.session_by_userid(String(voter).to_int()) if server != null else null

		if session == null:
			return {}

		var avatar: Variant = session.identity.get("avatar_url") if session.identity != null else ""
		return {"name": session.display_name, "avatar": avatar if avatar is String else ""}

	add_child(vote)
	var ready := vote.setup()

	if not ready.ok:
		DotLog.result(CHANNEL, "the map vote; the rotation alone chooses", ready)
		vote.queue_free()
		vote = null
		return

	var commanded := vote.install_commands(self)
	DotLog.result(CHANNEL, "the map vote's commands", commanded)

	_tunable("ph_vote_after", vote.open_after_sec,
		"Seconds into the last round on a map before the vote for the next one opens",
		func(value: float) -> void:
			if vote != null:
				vote.open_after_sec = maxf(value, 0.0))

	world.world_rebuilt.connect(func() -> void:
		if vote != null and world.map != null:
			vote.note_map(world.map.id())
	)
	world.round_began.connect(func(_number: int, _map: StringName) -> void:
		if vote != null:
			vote.note_round_start()
	)
	world.match_node.round_ended.connect(func(_number: int, _winner: int, _outcome: int) -> void:
		if vote != null:
			vote.note_round_end()
	)

	if server != null:
		server.client_disconnected.connect(func(session: DotClientSession, _reason: String) -> void:
			if vote != null:
				vote.forget_voter(StringName(str(session.userid)))
		)


## The map is what a server listing prints, reported on every rebuild: the server forgets it
## whenever a game unloads, and a browser showing last round's map is a browser lying.
func _wire_map(world: PhGame) -> void:
	if world.map != null and not world.map.doc.is_empty():
		report_map(String(world.map.id()))

	world.world_rebuilt.connect(func() -> void:
		report_map(String(world.map.id()))
	)


## An achievement is told to the one person who earned it.
##
## [b]As a notice, which a client already draws in its chat box[/b], rather than a new event
## kind: an unlock is text for one player, which is exactly what a notice is — and a stand-in
## never earns one, because [PhProgress] does not count them.
func _wire_progress(world: PhGame) -> void:
	if bridge == null:
		return

	# What a player keeps is filed under their scoped profile key, so it outlives the
	# connection; see [PhProgress]. Nothing for a stand-in or a guest, who keep their seat's.
	if world.progress != null:
		world.progress.durable_key_fn = func(id: StringName) -> String:
			var session := server.session_by_userid(PhNetBridge.session_of(id)) \
				if server != null else null
			var platform: Object = server.modules.get_module("platform") \
				if server != null and server.modules != null else null

			if session == null or platform == null or not platform.has_method("player_for"):
				return ""

			var held: Variant = platform.call("player_for", session)
			return str((held as Object).call("key")) if held is Object else ""

	world.achievement_earned.connect(func(id: StringName, title: String, points: int) -> void:
		var peer_id: int = bridge.call("peer_for_player", PhNetBridge.session_of(id))

		if peer_id > 0:
			bridge.call("notice", peer_id, "Achievement: %s (+%d)" % [title, points])
	)


func _on_say_requested(peer_id: int, channel_id: StringName, text: String) -> void:
	var said: DotResult = services.call("say", peer_id, channel_id, text)

	if said.ok:
		return

	# Back to the one person who asked. A refusal broadcast would be a rate limit announced
	# to the server.
	bridge.call("notice", peer_id, said.error.message)


## A `!command` typed into chat. Run through the console as the person who typed it.
##
## [b]As THEM, not as the server.[/b] `run_command_as_uid` builds a context with that
## player's own flags, so `!kick` from somebody without the flag is refused by the same file
## that refuses it at the console — rather than by this function having an opinion.
func _on_chat_command(peer_id: int, command: String, args: PackedStringArray) -> void:
	if server == null:
		return

	var session := server.session_of(peer_id)

	if session == null:
		return

	for reply in server.run_command_as_uid(
		session.uid(), command, args, DotCmdContext.Source.CHAT
	):
		bridge.call("notice", peer_id, reply)


func _cmd_wish(ctx: DotCmdContext, side: int) -> void:
	var world := game as PhGame
	if world == null or ctx.session == null:
		ctx.reply("Only a player can choose a side.")
		return
	if not world.config.allow_side_choice:
		ctx.reply("Sides are drawn on this server.")
		return
	world.wish_side(PhNetBridge.player_key(ctx.session.userid), side)
	ctx.reply(
		"You will be picked to hunt first." if side == PhGame.HUNTERS
		else ("You will only hunt if nobody else can." if side == PhGame.PROPS else "Either side.")
	)


func _cmd_say(ctx: DotCmdContext) -> void:
	var text := ctx.rest()

	if text.strip_edges() == "":
		ctx.reply("Say what?")
		return

	if services == null or services.get("chat") == null:
		ctx.reply("This server has no chat.")
		return

	var announced: Variant = services.get("chat").call("announce", text, PhServices.CH_ALL)

	if announced is DotResult and not (announced as DotResult).ok:
		ctx.reply_error(announced)
		return

	ctx.reply("Said: %s" % text)


func _cmd_status(ctx: DotCmdContext) -> void:
	var world := game as PhGame

	if world == null:
		ctx.reply("No world.")
		return

	ctx.reply_lines(world.describe_lines())


func _cmd_net(ctx: DotCmdContext) -> void:
	if bridge == null:
		ctx.reply("No bridge; this server is not replicating anything.")
		return

	ctx.reply_lines(bridge.call("describe_lines"))

	if services != null:
		ctx.reply_lines(services.call("describe_lines"))


func _cmd_maps(ctx: DotCmdContext) -> void:
	var world := game as PhGame

	if world == null or world.catalogue == null:
		ctx.reply("No world.")
		return

	ctx.reply_lines(world.catalogue.describe_lines())
	ctx.reply("playing: %s" % str(world.map_doc.get("id", "-")))


func _cmd_map(ctx: DotCmdContext) -> void:
	var world := game as PhGame
	var id := StringName(ctx.arg(0)) if ctx.argc() > 0 else &""

	if world == null or world.catalogue == null:
		ctx.reply("No world.")
		return

	if id == &"" or not world.catalogue.playable(world.config.map_ids).has(id):
		ctx.reply("Which map? %s" % ", ".join(world.catalogue.playable(world.config.map_ids)))
		return

	world.next_map_id = id
	ctx.reply("%s is next, from the end of this round." % String(id))


func _cmd_taunts(ctx: DotCmdContext) -> void:
	var world := game as PhGame

	if world == null or world.taunts == null:
		ctx.reply("No world.")
		return

	for id in world.taunt_ids():
		var entry := world.taunts.entry(id)
		ctx.reply("  %-18s %-20s %.1f s" % [String(id), str(entry.get("title", "")), float(entry.get("seconds", 0.0))])

	ctx.reply(str(world.taunts.describe()))


func _cmd_reload(ctx: DotCmdContext) -> void:
	var world := game as PhGame

	if world == null or world.catalogue == null:
		ctx.reply("No world.")
		return

	var loaded := world.catalogue.load_from(world.config.map_directory)
	loaded += await _add_delivered_maps(world)

	if vote != null:
		vote.refresh_maps()

	ctx.reply("%d documents read; %d refused. The next map draws from them." % [
		loaded, world.catalogue.refused.size()])


## This game's columns on the Tab board: the points, and which side.
func _game_board_fields(session: Object) -> Dictionary:
	var world := game as PhGame
	var who: PhPlayer = world.players.get(PhNetBridge.player_key(int(session.get(&"userid")))) if world != null and session != null else null

	if who == null:
		return {}

	return {"points": who.points, "team": world.team_of(who.player_id)}


func describe() -> Dictionary:
	var out := super.describe()
	var world := game as PhGame

	if world != null:
		out.merge({"round": world.round_number, "world": world.describe()}, true)

	return out
