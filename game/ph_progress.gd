extends Node

const PhPlayer := preload("ph_player.gd")

## What a player keeps from a round: the numbers this game produces, and what they earn.
##
## [b]The numbers are the ones only this game has.[/b] A deathmatch counts kills; a hiding
## game counts both ends of a hide — how many rounds somebody got through as a piece of
## furniture, and as a hunter how many props they found and how often they shot a real chair
## instead. Each is declared once, in [method schema], counted as it happens and reported by
## dot-stats as a DELTA — "add one", never "now has forty" — so two servers reporting one
## player add up rather than overwrite.
##
## [b]Achievements are rules over those numbers and nothing else.[/b] dot-achievements never
## hears about a disguise; it hears that a number moved, through [DotAchievementStatsLink] —
## which is the differencer between dot-stats' SESSION totals and a lifetime total, and the
## reason this is not one `connect`.
##
## [b]Stand-ins are never counted.[/b] An achievement a bot can earn is noise in every log an
## operator reads, and a stand-in's numbers are no player's numbers.
##
## [b]Server side, and on an offline client — wherever the world is authoritative.[/b]
##
## [b]A player's numbers are filed under their scoped profile key when they have one[/b] — see
## mg-wipeout's note, which this is, unchanged: [member durable_key_fn] supplies it, and
## without one the key is the world's id and lasts a connection.

const CHANNEL := "ph.progress"

# --- The numbers -------------------------------------------------------------

## Rounds a player was in from the start to the end, and won.
const ROUNDS_PLAYED := &"ph.rounds_played"
const ROUNDS_WON := &"ph.rounds_won"
## Rounds as each side.
const PROP_ROUNDS := &"ph.prop_rounds"
const HUNTER_ROUNDS := &"ph.hunter_rounds"
## A round got through as a prop, alive at the end.
const SURVIVED := &"ph.survived"
## A prop found, by the hunter who found them.
const PROPS_FOUND := &"ph.props_found"
const BEST_ROUND_FOUND := &"ph.best_round_found"
## Found, as a prop.
const TIMES_FOUND := &"ph.times_found"
## Taken the shape of something.
const DISGUISES := &"ph.disguises"
## A taunt chosen, and one forced by standing still.
const TAUNTS := &"ph.taunts"
const FORCED_TAUNTS := &"ph.forced_taunts"
## A shot that hit the furniture, and a hunter the furniture finished.
const DECOYS_SHOT := &"ph.decoys_shot"
const DECOY_DEATHS := &"ph.decoy_deaths"
const DEATHS := &"ph.deaths"

signal earned(player_id: StringName, title: String, points: int)

var stats: DotStatsTracker = null
var achievements: DotAchievementTracker = null
var link: DotAchievementStatsLink = null

## The world's own dictionaries, shared. See [PhSpectate] for why not a reference to it.
var players: Dictionary = {}
var sides: Dictionary = {}

## Players present when this round began. Only they have played it.
var _in_round: Dictionary = {}

## player id -> props they found this round, for [constant BEST_ROUND_FOUND].
var _round_found: Dictionary = {}

## `func(player_id: StringName) -> String`: the durable key to file this player under, or
## "" for none. Set by the module from dot-platform; see the class note.
var durable_key_fn: Callable = Callable()

## World id -> the key their numbers are filed under, and back. Fixed at [method record]'s
## first reading for them.
var _keys: Dictionary = {}
var _ids: Dictionary = {}


# --- The documents -----------------------------------------------------------

static func ids() -> Array[StringName]:
	return [
		ROUNDS_PLAYED, ROUNDS_WON, PROP_ROUNDS, HUNTER_ROUNDS, SURVIVED, PROPS_FOUND,
		BEST_ROUND_FOUND, TIMES_FOUND, DISGUISES, TAUNTS, FORCED_TAUNTS, DECOYS_SHOT,
		DECOY_DEATHS, DEATHS,
	]


## Every number, once. [b]`publish` on the ones a player page would show[/b]; deaths and
## rounds played are inputs to a ratio rather than figures anybody reads.
static func schema() -> DotStatsSchema:
	var out := DotStatsSchema.new()
	_add(out, ROUNDS_PLAYED, DotStatsDef.Kind.COUNTER, "Rounds played", "rounds", false)
	_add(out, ROUNDS_WON, DotStatsDef.Kind.COUNTER, "Rounds won", "rounds", true)
	_add(out, PROP_ROUNDS, DotStatsDef.Kind.COUNTER, "Rounds as a prop", "rounds", true)
	_add(out, HUNTER_ROUNDS, DotStatsDef.Kind.COUNTER, "Rounds as a hunter", "rounds", true)
	_add(out, SURVIVED, DotStatsDef.Kind.COUNTER, "Rounds survived hidden", "rounds", true)
	_add(out, PROPS_FOUND, DotStatsDef.Kind.COUNTER, "Props found", "props", true)
	_add(out, BEST_ROUND_FOUND, DotStatsDef.Kind.BEST, "Most props found in a round", "props", true)
	_add(out, TIMES_FOUND, DotStatsDef.Kind.COUNTER, "Times found", "times", true)
	_add(out, DISGUISES, DotStatsDef.Kind.COUNTER, "Disguises", "props", true)
	_add(out, TAUNTS, DotStatsDef.Kind.COUNTER, "Taunts", "taunts", true)
	_add(out, FORCED_TAUNTS, DotStatsDef.Kind.COUNTER, "Taunts forced by standing still", "taunts", false)
	_add(out, DECOYS_SHOT, DotStatsDef.Kind.COUNTER, "Shots at the furniture", "shots", true)
	_add(out, DECOY_DEATHS, DotStatsDef.Kind.COUNTER, "Beaten by the furniture", "deaths", true)
	_add(out, DEATHS, DotStatsDef.Kind.COUNTER, "Deaths", "deaths", false)
	return out


static func _add(
	out: DotStatsSchema, id: StringName, kind: DotStatsDef.Kind, display: String,
	unit: String, publish: bool
) -> void:
	var def := DotStatsDef.make(id, kind, display)
	def.unit = unit
	def.publish = publish
	out.stats.append(def)


## What a player can earn, as rules over [method schema]'s numbers.
##
## [b]Every stat read here is one [method schema] declares and this file records[/b] — an
## achievement over a stat nothing reports never unlocks and nothing errors. The suite checks
## it both ways.
static func catalogue() -> DotAchievementCatalogue:
	var made: Array[DotAchievement] = []

	made.append(_sum(&"ph.hidden", "Hidden in Plain Sight", SURVIVED, 1.0, 10,
		"Get through a round as a prop.", &"ph.hider", 1))
	made.append(_sum(&"ph.furniture", "Part of the Furniture", SURVIVED, 25.0, 30,
		"Get through twenty-five rounds as a prop.", &"ph.hider", 2))
	made.append(_sum(&"ph.seeker", "Found One", PROPS_FOUND, 1.0, 10,
		"Find a prop.", &"ph.seeker", 1))
	made.append(_sum(&"ph.bloodhound", "Bloodhound", PROPS_FOUND, 50.0, 30,
		"Find fifty props.", &"ph.seeker", 2))
	made.append(_sum(&"ph.chameleon", "Chameleon", DISGUISES, 100.0, 20,
		"Take the shape of a hundred things."))
	made.append(_sum(&"ph.loudmouth", "Loudmouth", TAUNTS, 50.0, 15,
		"Taunt the hunters fifty times."))

	# A BEST: four in one round, not four over a career.
	var sweep := DotAchievement.make(&"ph.clean_sweep", "Clean Sweep", [
		DotAchievementRule.make(
			BEST_ROUND_FOUND, 4.0, DotAchievementRule.Op.AT_LEAST,
			DotAchievementRule.Merge.HIGHEST
		),
	])
	sweep.description = "Find four props in one round."
	sweep.points = 30
	made.append(sweep)

	# Secret: earned by the mistake every hunter makes, and only funny afterwards.
	var collateral := _sum(&"ph.collateral", "Collateral Damage", DECOY_DEATHS, 1.0, 10,
		"Be beaten by the furniture.")
	collateral.secret = true
	made.append(collateral)

	var out := DotAchievementCatalogue.new()
	out.achievements = made
	return out


static func _sum(
	id: StringName, title: String, stat: StringName, target: float, points: int,
	description: String, series: StringName = &"", tier: int = 0
) -> DotAchievement:
	var out := DotAchievement.make(id, title, [
		DotAchievementRule.make(
			stat, target, DotAchievementRule.Op.AT_LEAST, DotAchievementRule.Merge.SUM
		),
	])
	out.description = description
	out.points = points
	out.series = series
	out.tier = tier
	return out


# --- Building ---------------------------------------------------------------

## [param directory] empty keeps achievement progress in memory; see
## [member PhConfig.progress_directory]. [param report] is [member PhConfig.report_progress].
func setup(directory: String, report: bool) -> DotResult:
	stats = DotStatsTracker.new()
	stats.name = "Stats"
	stats.schema = schema()
	stats.report_to_backbone = report
	stats.define_on_start = report
	add_child(stats)

	var counted := stats.start()

	if not counted.ok:
		return counted.wrap("prophunt stats")

	achievements = DotAchievementTracker.new()
	achievements.name = "Achievements"
	achievements.catalogue = catalogue()
	achievements.report_to_backbone = report
	# Not published: a server and a client in one process — every suite here — would fight
	# over one registry name, and the link below is handed the tracker directly.
	achievements.register_as = &""

	if directory != "":
		var file_store := DotAchievementStoreFile.new()
		file_store.directory = directory
		achievements.store = file_store
	else:
		achievements.store = DotAchievementStoreMemory.new()

	add_child(achievements)

	var awarded := achievements.start()

	if not awarded.ok:
		return awarded.wrap("prophunt achievements")

	achievements.unlocked.connect(_on_unlocked)

	link = DotAchievementStatsLink.new()
	link.name = "StatsLink"
	link.tracker = achievements
	link.stats = stats
	add_child(link)

	return link.start().wrap("prophunt's stats-to-achievements link")


# --- Counting ---------------------------------------------------------------

## Files one reading for one person, and starts counting for them the first time.
##
## [b]Begun lazily, on the first number, and that is what keeps stand-ins out.[/b] A player
## is added to the world before a bridge or a client marks them a stand-in, so a check at
## join time would see every bot as a person; by the time anything is worth counting, the
## flag is set. The memory and file stores load synchronously, so the achievement tracker
## has them before the reading that follows.
func record(player_id: StringName, stat: StringName, value: float = 1.0) -> void:
	if stats == null:
		return

	var body: PhPlayer = players.get(player_id)

	if body == null or body.is_bot:
		return

	var key := _key(player_id)

	if not stats.has_player(key):
		stats.begin(key, body.display_name)
		_begin(key)

	var filed := stats.record(key, stat, value)

	if not filed.ok:
		# WARN: a number a player earned that nobody will ever see. It is a schema or a key
		# that is wrong, and it only ever happens for a reason worth looking at.
		DotLog.warn(CHANNEL, "a reading was refused", {
			"player": String(player_id), "stat": String(stat), "why": filed.error.message,
		})


## The key a player's numbers are filed under. Asked of [member durable_key_fn] once, then
## remembered; see the class note.
func _key(player_id: StringName) -> StringName:
	if _keys.has(player_id):
		return _keys[player_id]

	var key := player_id

	if durable_key_fn.is_valid():
		var durable := str(durable_key_fn.call(player_id))

		if durable != "":
			key = StringName(durable)

	_keys[player_id] = key
	_ids[key] = player_id
	return key


## Loads somebody's lifetime progress. A statement call, never assigned: the tracker's
## `begin` is a coroutine, and this is the family's pattern for starting one from code that
## is not — `await` inside, a bare call outside.
func _begin(player_id: StringName) -> void:
	var began: DotResult = await achievements.begin(String(player_id))

	if not began.ok:
		# WARN: this player will earn nothing this session, and they will not be told why.
		DotLog.warn(CHANNEL, "achievement progress could not be loaded", {
			"player": String(player_id), "why": began.error.message,
		})


## Saves somebody's progress as they go. See [method _begin].
func _end(player_id: StringName) -> void:
	var ended: DotResult = await achievements.end(String(player_id))

	if not ended.ok:
		DotLog.warn(CHANNEL, "achievement progress could not be saved", {
			"player": String(player_id), "why": ended.error.message,
		})


## Stops counting for somebody who left, and saves what they earned.
func leave(player_id: StringName) -> void:
	_in_round.erase(player_id)
	_round_found.erase(player_id)

	var key: StringName = _keys.get(player_id, player_id)
	_keys.erase(player_id)
	_ids.erase(key)

	if stats == null or not stats.has_player(key):
		return

	var _values := stats.end(key)
	link.forget(String(key))
	_end(key)


func session_values(player_id: StringName) -> DotStatsValues:
	return stats.session_values(_keys.get(player_id, player_id)) \
		if stats != null else DotStatsValues.new()


## The key [param player_id]'s numbers are filed under. For a console command and a suite.
func filed_under(player_id: StringName) -> StringName:
	return _keys.get(player_id, player_id)


# --- What the world reports -------------------------------------------------

func on_round_began() -> void:
	_in_round.clear()
	_round_found.clear()

	for id: StringName in players:
		_in_round[id] = true
		record(id, HUNTER_ROUNDS if int(sides.get(id, 0)) == 2 else PROP_ROUNDS)


## A round ended. [param winner] is a side, or 0 for a draw.
func on_round_over(winner: int) -> void:
	for id: StringName in _in_round.keys():
		if not players.has(id):
			continue

		record(id, ROUNDS_PLAYED)

		if winner > 0 and int(sides.get(id, 0)) == winner:
			record(id, ROUNDS_WON)

		var found := int(_round_found.get(id, 0))

		if found > 0:
			record(id, BEST_ROUND_FOUND, float(found))

	_in_round.clear()
	_round_found.clear()


## A prop alive at the end of a round.
func on_survived(player_id: StringName) -> void:
	record(player_id, SURVIVED)


func on_disguised(player_id: StringName) -> void:
	record(player_id, DISGUISES)


func on_taunted(player_id: StringName, forced: bool) -> void:
	record(player_id, FORCED_TAUNTS if forced else TAUNTS)


func on_decoy(player_id: StringName) -> void:
	record(player_id, DECOYS_SHOT)


## Somebody is out. [param by] is the hunter who found them, or empty; [param why] is the
## world's reason: `shot`, `decoy` (a hunter the furniture finished), `fell`.
func on_died(player_id: StringName, by: StringName, why: StringName) -> void:
	record(player_id, DEATHS)

	if why == &"decoy":
		record(player_id, DECOY_DEATHS)
		return

	if int(sides.get(player_id, 0)) == 1:
		record(player_id, TIMES_FOUND)

	if by == &"" or by == player_id or not players.has(by):
		return

	if int(sides.get(by, 0)) == 2 and int(sides.get(player_id, 0)) == 1:
		record(by, PROPS_FOUND)
		_round_found[by] = int(_round_found.get(by, 0)) + 1


func _on_unlocked(player: String, achievement: DotAchievement) -> void:
	# INFO: what an admin keeps. "I did the thing and was not told" is answered here.
	DotLog.info(CHANNEL, "an achievement was unlocked", {
		"player": player, "achievement": String(achievement.id), "points": achievement.points,
	})
	# Back to the world's id: the world tells the player, and the world knows them by that.
	earned.emit(_ids.get(StringName(player), StringName(player)),
		achievement.display_name, achievement.points)


func describe() -> Dictionary:
	return {
		"tracking": stats.players().size() if stats != null else 0,
		"in_round": _in_round.size(),
		"achievements": achievements.catalogue.size() if achievements != null else 0,
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	if stats != null:
		out.append_array(stats.describe_lines())

	if achievements != null:
		out.append_array(achievements.describe_lines())

	return out
