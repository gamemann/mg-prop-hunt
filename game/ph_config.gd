extends DotConfig

## Every number this game has, layered like every other [DotConfig] in the family:
## [code]exported defaults < JSON file < environment < command line[/code].
##
## [b]Metres and seconds.[/b] The maps are documents in the same units (see [PhMapDoc]), so a
## length a mapper writes and a length this file tunes against are the same number.
##
## [b]Every rule the brief named is here, and its default is the brief's.[/b] Which side a
## player is on and how hunters are chosen, how long the props get to hide, what showing your
## face pays, when a taunt is forced, when the last props are given away, what shooting the
## furniture costs a hunter: a server owner changes any of them in `user://cfg/prophunt.json`,
## an environment variable (`PH_HIDE_SECONDS`) or a flag (`--ph-hide-seconds`), and the
## commonly turned ones are cvars as well (see `PhModule._add_tunables`).

# --- The round -------------------------------------------------------------

@export_group("The round")

## Seconds the props have to hide while the hunters are blindfolded and held still.
@export_range(0.0, 180.0, 1.0) var hide_seconds: float = 30.0

## Seconds the hunters have to find everybody once they are let go. A map may ask for less.
@export_range(30.0, 1800.0, 5.0) var round_seconds: float = 300.0

## Seconds between rounds.
@export_range(0.0, 60.0, 1.0) var intermission_seconds: float = 8.0

## Seconds of warmup before the first round. 0 starts immediately.
@export_range(0.0, 300.0, 1.0) var warmup_seconds: float = 8.0

## Who wins a round the clock ends: 1 the props, 2 the hunters, 0 nobody.
##
## [b]The props, because surviving the clock is their whole objective.[/b]
@export_enum("draw", "props", "hunters") var timeout_winner: int = 1

# --- The sides -------------------------------------------------------------

@export_group("The sides")

## One hunter for every this many players, rounded up, at least [member min_hunters] and at
## most [member max_hunters] — and never everybody.
@export_range(1.0, 32.0, 0.5) var players_per_hunter: float = 3.0
@export_range(1, 16, 1) var min_hunters: int = 1
@export_range(1, 32, 1) var max_hunters: int = 8

## How hunters are chosen each round: 0 a random draw that skips last round's hunters, 1 a queue
## so everybody gets an equal share of turns, 2 the sides swap over every round. See
## [DotTeamRotation].
@export_enum("random", "queue", "swap") var hunter_pick: int = 0

## Whether a player's own wish (`!hunter`, `!prop`, `!any`) counts: those who asked are picked
## first, and those who asked to stay a prop only to fill the round.
@export var allow_side_choice: bool = true

# --- Hiding ----------------------------------------------------------------

@export_group("Hiding")

## How far from the eye a prop may be copied, in metres.
@export_range(0.5, 10.0, 0.1) var disguise_reach: float = 3.0

## A disguise's health at one cubic metre, and how fast it rises with size. See
## [DotPropDisguiseRules]: a cabinet is about nine bottles, not a hundred and fifty.
@export_range(1.0, 1000.0, 1.0) var prop_health_scale: float = 190.0
@export_range(0.0, 1.0, 0.01) var prop_health_exponent: float = 0.45
@export_range(1.0, 1000.0, 1.0) var prop_min_health: float = 10.0
@export_range(1.0, 1000.0, 1.0) var prop_max_health: float = 200.0

## The smallest dimension and the largest volume a player may hide as.
@export_range(0.0, 2.0, 0.01) var prop_min_dimension: float = 0.1
@export_range(0.0, 100.0, 0.1) var prop_max_volume: float = 8.0

## Seconds a prop must wait after putting a disguise back on before taking it off again.
@export_range(0.0, 600.0, 0.5) var reveal_cooldown: float = 10.0

## Points a second for showing your own face, and the most seconds of it that pay per reveal.
@export_range(0.0, 100.0, 0.1) var reveal_points_per_second: float = 1.0
@export_range(0.0, 600.0, 1.0) var reveal_paid_seconds: float = 20.0

## Degrees one press of a tilt key turns a prop, and the most it may lean.
@export_range(1.0, 90.0, 1.0) var tilt_step: float = 15.0
@export_range(0.0, 180.0, 1.0) var max_tilt: float = 90.0

# --- Taunts ----------------------------------------------------------------

@export_group("Taunts")

## Where the taunt list is read from, relative to this game's root. A list of
## `{"id", "title", "seconds", "sound"}`; see `taunts/taunts.json`.
@export var taunt_file: String = "taunts/taunts.json"

## Seconds a prop may stand within [member auto_taunt_radius] before a taunt is forced. 0 never.
@export_range(0.0, 600.0, 1.0) var auto_taunt_seconds: float = 45.0
@export_range(0.1, 20.0, 0.1) var auto_taunt_radius: float = 1.5

## Whether a prop sees the meter filling toward a forced taunt.
@export var show_taunt_meter: bool = true

## Seconds between taunts, on top of the last one's length.
@export_range(0.0, 60.0, 0.5) var taunt_cooldown: float = 2.0

## Points for a taunt a prop chose, and for one forced on them.
@export_range(0, 100, 1) var taunt_points: int = 2
@export_range(0, 100, 1) var forced_taunt_points: int = 0

## Metres a taunt carries.
@export_range(5.0, 300.0, 1.0) var taunt_range: float = 60.0

# --- Giving the last props away ---------------------------------------------

@export_group("The beacon")

## Every prop still alive is beaconed once this few are left. 0 never.
@export_range(0, 32, 1) var beacon_props_left: int = 1

## Every prop still alive is beaconed once this few seconds are left. 0 never.
@export_range(0.0, 600.0, 1.0) var beacon_seconds_left: float = 30.0

## Seconds between a beacon's pings.
@export_range(0.25, 10.0, 0.25) var beacon_period: float = 2.0

# --- Hunters ---------------------------------------------------------------

@export_group("Hunters")

## The weapons a hunter is handed, by id from zee-dot-weapons.
@export var hunter_weapons: PackedStringArray = PackedStringArray(["smg", "shotgun", "hatchet"])

## What shooting the furniture costs a hunter: this fraction of the damage the shot would have
## done comes off their own health. 0 turns it off.
@export_range(0.0, 5.0, 0.05) var decoy_penalty: float = 0.2

## The least a decoy shot costs, so a shotgun's pellets are not each worth nothing.
@export_range(0.0, 50.0, 0.5) var decoy_penalty_min: float = 1.0

## What happens to a hunter who dies to the furniture: 0 nothing drawn, 1 they fall apart, 2
## they burst. See [DotPlayerBreakRules].
@export_enum("none", "limbs", "explode") var hunter_break: int = 2

# --- Points ----------------------------------------------------------------

@export_group("Points")

## Points to everybody on the winning side.
@export_range(0, 100, 1) var winner_points: int = 10

## Points to a hunter for each prop they find.
@export_range(0, 100, 1) var find_points: int = 5

## Points to every prop still alive when the round ends.
@export_range(0, 100, 1) var survive_points: int = 5

# --- The players -----------------------------------------------------------

@export_group("The players")

@export_range(1.0, 400.0, 1.0) var hunter_health: float = 100.0

## A prop's health before they are disguised: their own body.
@export_range(1.0, 400.0, 1.0) var prop_body_health: float = 100.0

@export_range(1.0, 20.0, 0.1) var run_speed: float = 6.5
@export_range(0.1, 1.0, 0.01) var walk_speed_scale: float = 0.45
@export_range(0.1, 5.0, 0.05) var jump_height: float = 1.15
@export_range(1.0, 60.0, 0.5) var gravity: float = 20.0
@export var auto_bunny_hop: bool = false
@export_range(0.0, 200.0, 1.0) var air_accelerate: float = 20.0

# --- The maps --------------------------------------------------------------

@export_group("The maps")

## Which maps this server may play, by id. Empty means every one it has.
@export var map_ids: PackedStringArray = PackedStringArray()

## Whether the next map is drawn at random (seeded) rather than taken in order.
@export var shuffle_maps: bool = true

## Rounds played on a map before the next one, unless the players vote first.
@export_range(1, 50, 1) var rounds_per_map: int = 4

## Where map documents are read from, relative to this game's root.
@export var map_directory: String = "maps"

## Seed every random choice is drawn from: the map, the hunters, the bots.
@export var seed_value: int = 20261009

# --- Bots ------------------------------------------------------------------

@export_group("Bots")

## How many players the server keeps in the round by adding stand-ins.
@export_range(0, 24, 1) var minimum_players: int = 4

## How far a stand-in hunter's aim is off, in degrees.
@export_range(0.0, 45.0, 0.5) var bot_aim_spread_degrees: float = 4.0

## Chance in a hundred, a second, that a stand-in hunter shoots at a prop it walks past.
@export_range(0.0, 100.0, 1.0) var bot_suspicion: float = 12.0

# --- Watching --------------------------------------------------------------

@export_group("Watching")

## Who somebody who is out may watch: 0 anybody, 1 their own side, 2 nobody.
@export_enum("anybody", "own side", "nobody") var spectate_camera: int = 0

# --- Progress --------------------------------------------------------------

@export_group("Progress")

@export var keep_progress: bool = true
@export var progress_directory: String = ""
@export var report_progress: bool = false


func env_prefix() -> String:
	return "PH_"


func cli_prefix() -> String:
	return "--ph-"


## How many hunters a round with [param players] in it has.
func hunters_for(players: int) -> int:
	return DotTeamRotation.count_for(players, players_per_hunter, min_hunters, max_hunters)


## The disguise rules, from this configuration.
func disguise_rules() -> DotPropDisguiseRules:
	var r := DotPropDisguiseRules.new()
	r.health_scale = prop_health_scale
	r.health_exponent = prop_health_exponent
	r.min_health = prop_min_health
	r.max_health = prop_max_health
	r.min_dimension = prop_min_dimension
	r.max_volume = prop_max_volume
	r.reach = disguise_reach
	r.tilt_step = tilt_step
	r.max_tilt = max_tilt
	r.reveal_cooldown = reveal_cooldown
	r.reveal_points_per_second = reveal_points_per_second
	r.reveal_paid_seconds = reveal_paid_seconds
	return r


func validate() -> DotResult:
	if round_seconds <= 0.0:
		return DotResult.fail(DotError.CODE_INVALID, "A round has to last some time.")

	if min_hunters > max_hunters:
		return DotResult.fail(DotError.CODE_INVALID, "min_hunters is over max_hunters.")

	if timeout_winner < 0 or timeout_winner > 2:
		return DotResult.fail(DotError.CODE_INVALID,
			"timeout_winner is %d; it is 0 (draw), 1 (props) or 2 (hunters)." % timeout_winner)

	if hunter_pick < 0 or hunter_pick > 2:
		return DotResult.fail(DotError.CODE_INVALID,
			"hunter_pick is %d; it is 0 (random), 1 (queue) or 2 (swap)." % hunter_pick)

	var rules := disguise_rules().validate()

	if not rules.ok:
		return rules

	return DotResult.success(null)


func describe() -> Dictionary:
	return {
		"round": "%.0f s hide, %.0f s seek" % [hide_seconds, round_seconds],
		"hunters": "1 per %.1f, %d..%d, %s" % [players_per_hunter, min_hunters, max_hunters,
			["random", "queue", "swap"][hunter_pick]],
		"timeout": ["draw", "props", "hunters"][timeout_winner],
		"taunts": "forced after %.0f s within %.1f m" % [auto_taunt_seconds, auto_taunt_radius]
			if auto_taunt_seconds > 0.0 else "never forced",
		"beacon": "%d left or %.0f s" % [beacon_props_left, beacon_seconds_left],
		"decoys": "%.0f%% back" % (decoy_penalty * 100.0),
		"maps": "all" if map_ids.is_empty() else ",".join(map_ids),
		"bots": minimum_players,
	}


func describe_lines(_redact_sensitive: bool = true) -> PackedStringArray:
	var lines := PackedStringArray()
	lines.append("prophunt configuration")
	var facts := describe()
	for key: String in facts:
		lines.append("  %-10s %s" % [key, facts[key]])
	return lines
