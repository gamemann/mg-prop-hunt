extends RefCounted

## Every key this game reads, as one [DotMenuBindings] table: the action, the setting that
## stores it, the words a player sees, the default, and the card it goes on.
##
## [b]A table, because four things read it:[/b] the client matches events against the actions,
## the settings document stores one binding per row, the menu's Controls page draws a key per
## row, and the help screen lists them with the key each is on now.
##
## [b]A prop's keys and a hunter's never share a default.[/b] Reload is R for a hunter, so the
## prop's rotation lock is C; a player who is a prop this round and a hunter the next must not
## find that the key they reloaded with now does something else in the same round.

const DISGUISE := &"ph_disguise"
const REVEAL := &"ph_reveal"
const LOCK := &"ph_lock"
const TAUNT := &"ph_taunt"
const TAUNT_MENU := &"ph_taunt_menu"
const TILT_FORWARD := &"ph_tilt_forward"
const TILT_BACK := &"ph_tilt_back"
const TILT_LEFT := &"ph_tilt_left"
const TILT_RIGHT := &"ph_tilt_right"
const STRAIGHTEN := &"ph_straighten"
const RELOAD := &"ph_reload"
const VIEW := &"ph_view"
const SCOREBOARD := &"ph_scoreboard"


static func make() -> DotMenuBindings:
	var keys := DotMenuBindings.new()
	keys.add_movement()
	keys.add(DISGUISE, &"bind_disguise", "Become what you look at", "E", "Props")
	keys.add(REVEAL, &"bind_reveal", "Show yourself / hide again", "Q", "Props")
	keys.add(LOCK, &"bind_lock", "Lock rotation", "C", "Props")
	keys.add(TAUNT, &"bind_taunt", "Taunt", "T", "Props")
	keys.add(TAUNT_MENU, &"bind_taunt_menu", "Pick a taunt", "F3", "Props")
	keys.add(TILT_FORWARD, &"bind_tilt_forward", "Tilt forward", "Up", "Props")
	keys.add(TILT_BACK, &"bind_tilt_back", "Tilt back", "Down", "Props")
	keys.add(TILT_LEFT, &"bind_tilt_left", "Lean left", "Left", "Props")
	keys.add(TILT_RIGHT, &"bind_tilt_right", "Lean right", "Right", "Props")
	keys.add(STRAIGHTEN, &"bind_straighten", "Stand upright", "Z", "Props")
	keys.add(RELOAD, &"bind_reload", "Reload", "R", "Hunters")
	keys.add(VIEW, &"bind_view", "First or third person", "F5", "General")
	keys.add(SCOREBOARD, &"bind_scoreboard", "Scoreboard (hold)", "Tab", "General")
	return keys
