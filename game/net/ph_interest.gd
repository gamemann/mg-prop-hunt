extends DotNetInterest

const PhGame := preload("../ph_game.gd")
const PhPlayer := preload("../ph_player.gd")

## Who a client is told about: everybody, except that a hunter is told nothing about the props
## while they hide.
##
## [b]The blindfold, made true on the wire.[/b] The HUD draws a hunter's screen black while the
## props hide, and a client that skipped drawing it would watch every prop pick its spot. dot-net's
## own note on interest management is the reason this exists: a client that is never told where
## somebody is cannot draw them, whatever it does to its renderer, and every other defence is a
## delaying action. So during the hide a hunter's snapshots carry no prop at all; their mirrors
## stand where the round put them until the seeking starts.
##
## [b]Evaluated every snapshot, and nothing lingers.[/b] The default caches an answer for a
## quarter of a second and keeps sending an entity that has left interest for a while, both to
## save work on big servers; here the answer changes at a phase boundary and a prop that kept
## being sent for a second after the hide began would be a second of where everybody ran.
## Two dozen players is not a set worth caching.

## The world whose phase and sides this reads. Set by the bridge.
var game: PhGame = null


func _init() -> void:
	strategy_name = "prophunt"
	evaluation_interval_sec = 0.0


func _is_relevant(observer: DotNetIdentity, entity: DotNetIdentity, _context: Dictionary) -> bool:
	if game == null or observer == null or entity == null:
		return true

	if game.phase != PhGame.Phase.HIDE:
		return true

	var watcher := observer.get_parent() as PhPlayer
	var seen := entity.get_parent() as PhPlayer

	if watcher == null or seen == null:
		return true

	return not (
		game.team_of(watcher.player_id) == PhGame.HUNTERS
		and game.team_of(seen.player_id) == PhGame.PROPS
	)
