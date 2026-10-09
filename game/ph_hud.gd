extends CanvasLayer

const PhGame := preload("ph_game.gd")
const PhPlayer := preload("ph_player.gd")
const PhBindings := preload("ph_bindings.gd")

## What a player needs on screen: the clock and who it is counting for, which side they are on
## and how much of them is left, what they are hiding as, and — while the props hide — a
## blindfold for the hunters.
##
## [b]The blindfold is a screen, and the HUD is drawn over it.[/b] The brief: hunters cannot see
## the map, the props or each other while the props hide, but they can still see their HUD and
## use the menus. So it is a black rect UNDER every widget here, with its own line saying how
## long is left; the world behind it is not drawn at all. It does not depend on the client
## being honest about drawing: a blindfolded hunter is also held still by a movement modifier
## the server owns (see [PhController]), and their gun is the server's to fire.
##
## [b]The keys are read from the bindings, not written here.[/b] The hints in the corner say
## the key each action is on NOW, from the same table the menu's Controls page edits, so a
## rebound key is never a hint that lies.

const BLIND_FADE_SEC := 0.25
const BLIND_COLOUR := Color(0.01, 0.01, 0.015)

## The blindfold is not quite black: a hunter should be able to tell it from a client that
## stopped drawing.
const BLINDFOLD_COLOUR := Color(0.03, 0.025, 0.04)

var game: PhGame = null
var player: PhPlayer = null

## `func(action: StringName) -> String`: the key an action is on, from the bindings.
var key_fn: Callable = Callable()

## What a player who is out is looking at, and the keys that change it. Empty while playing.
var watching_label: Label = null

## An administrator's `blind`, over the world and under the HUD.
var blind_overlay: ColorRect = null

## The hunters' blindfold while the props hide, under the HUD's widgets.
var blindfold: ColorRect = null

var _root: Control = null
var _clock: Label = null
var _clock_caption: Label = null
var _map: Label = null
var _shout: Label = null
var _hints: Label = null
var _disc: Panel = null
var _disc_label: Label = null
var _as: Label = null
var _lock: Label = null
var _field: Label = null
var _meter_back: ColorRect = null
var _meter_fill: ColorRect = null
var _meter_label: Label = null
var _blindfold_label: Label = null
var _crosshair: ColorRect = null
var _shout_for: float = 0.0


func bind(p_game: PhGame, p_player: PhPlayer) -> void:
	game = p_game
	player = p_player

	if _root == null:
		_build()


func _build() -> void:
	# A full-rect Control between the CanvasLayer and the labels: a CanvasLayer does not lay its
	# children out, so anchors on a Label parented straight to one resolve against nothing.
	_root = Control.new()
	_root.name = "Screen"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	blindfold = _cover("Blindfold", BLINDFOLD_COLOUR)
	blind_overlay = _cover("Blind", BLIND_COLOUR)

	_blindfold_label = _label(30)
	_blindfold_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_blindfold_label.offset_left = -520.0
	_blindfold_label.offset_right = 520.0
	_blindfold_label.offset_top = -40.0
	_blindfold_label.offset_bottom = 40.0
	_blindfold_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_blindfold_label.add_theme_color_override("font_color", Color(0.98, 0.78, 0.45))

	_clock_caption = _label(18)
	_clock_caption.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_clock_caption.offset_top = 12.0
	_clock_caption.offset_bottom = 36.0
	_clock_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	_clock = _label(34)
	_clock.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_clock.offset_top = 34.0
	_clock.offset_bottom = 78.0
	_clock.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	_map = _label(15)
	_map.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_map.offset_top = 78.0
	_map.offset_bottom = 100.0
	_map.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_map.add_theme_color_override("font_color", Color(0.80, 0.88, 0.98))

	# Top left: the keys this side has, as the player has them bound.
	_hints = _label(15)
	_hints.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_hints.offset_left = 22.0
	_hints.offset_top = 18.0
	_hints.offset_right = 420.0
	_hints.offset_bottom = 260.0

	_shout = _label(40)
	_shout.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_shout.offset_top = 170.0
	_shout.offset_bottom = 240.0
	_shout.offset_left = -600.0
	_shout.offset_right = 600.0
	_shout.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_shout.add_theme_color_override("font_color", Color(0.99, 0.86, 0.40))

	# Bottom left: the health disc in the side's colour, what you are, and the rotation lock.
	# Above the chat box, which also draws bottom-left.
	_disc = Panel.new()
	_disc.name = "Disc"
	_disc.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_disc.offset_left = 22.0
	_disc.offset_right = 102.0
	_disc.offset_top = -300.0
	_disc.offset_bottom = -220.0
	_disc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_disc)

	_disc_label = Label.new()
	_disc_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_disc_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_disc_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_disc_label.add_theme_font_size_override("font_size", 26)
	_disc_label.add_theme_color_override("font_color", Color.WHITE)
	_disc_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.6))
	_disc_label.add_theme_constant_override("outline_size", 4)
	_disc.add_child(_disc_label)

	_as = _label(17)
	_as.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_as.offset_left = 112.0
	_as.offset_right = 600.0
	_as.offset_top = -296.0
	_as.offset_bottom = -266.0

	_lock = _label(15)
	_lock.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_lock.offset_left = 112.0
	_lock.offset_right = 600.0
	_lock.offset_top = -264.0
	_lock.offset_bottom = -240.0
	_lock.add_theme_color_override("font_color", Color(0.85, 0.92, 1.0))

	# The forced-taunt meter, under the disc's words: how long a prop has before it gives
	# itself away for standing still.
	_meter_back = _bar(Color(0.0, 0.0, 0.0, 0.45))
	_meter_fill = _bar(Color(0.98, 0.62, 0.20, 0.95))
	_meter_label = _label(13)
	_meter_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_meter_label.offset_left = 112.0
	_meter_label.offset_right = 420.0
	_meter_label.offset_top = -256.0
	_meter_label.offset_bottom = -236.0

	_field = _label(18)
	_field.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_field.offset_left = -460.0
	_field.offset_right = -24.0
	_field.offset_top = -64.0
	_field.offset_bottom = -26.0
	_field.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	watching_label = _label(20)
	watching_label.name = "Watching"
	watching_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	watching_label.offset_left = -520.0
	watching_label.offset_right = 520.0
	watching_label.offset_top = -140.0
	watching_label.offset_bottom = -104.0
	watching_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	watching_label.add_theme_color_override("font_color", Color(0.80, 0.90, 1.0))

	_crosshair = ColorRect.new()
	_crosshair.name = "Crosshair"
	_crosshair.color = Color(1.0, 1.0, 1.0, 0.75)
	_crosshair.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_crosshair.offset_left = -3.0
	_crosshair.offset_top = -3.0
	_crosshair.offset_right = 3.0
	_crosshair.offset_bottom = 3.0
	_crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_crosshair)


func _cover(cover_name: String, colour: Color) -> ColorRect:
	var rect := ColorRect.new()
	rect.name = cover_name
	rect.color = colour
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.modulate.a = 0.0
	rect.visible = false
	_root.add_child(rect)
	return rect


func _bar(colour: Color) -> ColorRect:
	var rect := ColorRect.new()
	rect.color = colour
	rect.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	rect.offset_left = 112.0
	rect.offset_right = 312.0
	rect.offset_top = -234.0
	rect.offset_bottom = -226.0
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.visible = false
	_root.add_child(rect)
	return rect


func _label(size: int) -> Label:
	var label := Label.new()
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", Color(1, 1, 1))
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	label.add_theme_constant_override("outline_size", 6)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(label)
	return label


func set_watching(text: String) -> void:
	if watching_label != null:
		watching_label.text = text


## One line in the middle of the screen, for a few seconds.
func shout(text: String, seconds: float = 3.5) -> void:
	if _shout == null:
		return

	_shout.text = text
	_shout_for = seconds


func _process(delta: float) -> void:
	present_blind(delta)

	if game == null or game.config == null or _root == null:
		return

	var side := game.team_of(player.player_id) if player != null else 0
	var left := game.seconds_left()

	match game.phase:
		PhGame.Phase.HIDE:
			_clock_caption.text = "Hunters released in"
		PhGame.Phase.SEEK:
			_clock_caption.text = "Props win in" if game.config.timeout_winner == PhGame.PROPS else "Time left"
		_:
			_clock_caption.text = "waiting for players" if not game.sides_are_playable() else "between rounds"

	_clock.text = "%d:%02d" % [int(left) / 60, int(left) % 60] if game.phase != PhGame.Phase.IDLE else ""
	_map.text = str(game.map_doc.get("name", ""))
	var props_left := game.alive_on(PhGame.PROPS)
	var hunters_left := game.alive_on(PhGame.HUNTERS)
	_field.text = "%d %s left  ·  %d %s" % [props_left, "prop" if props_left == 1 else "props",
		hunters_left, "hunter" if hunters_left == 1 else "hunters"] if game.phase != PhGame.Phase.IDLE else ""

	_draw_disc(side)
	_draw_hints(side)
	_draw_meter(side)
	_crosshair.visible = side == PhGame.HUNTERS and player != null and player.is_alive() and not is_blindfolded()

	if _shout_for > 0.0:
		_shout_for -= delta
		if _shout_for <= 0.0:
			_shout.text = ""


func _draw_disc(side: int) -> void:
	var shown := player != null and player.is_alive() and not player.watching and side != 0
	_disc.visible = shown
	_as.text = ""
	_lock.text = ""

	if not shown:
		return

	var style := StyleBoxFlat.new()
	style.bg_color = game.side_colour(side)
	style.set_corner_radius_all(40)
	style.border_color = Color(1, 1, 1, 0.85)
	style.set_border_width_all(3)
	_disc.add_theme_stylebox_override("panel", style)
	_disc_label.text = "%d" % int(round(player.health.health)) if player.health != null else ""

	if side != PhGame.PROPS:
		_as.text = "HUNTER"
		return

	if player.is_disguised():
		_as.text = "You are: %s" % game.props_catalogue.title_of(player.disguise.prop_id)
		_lock.text = "ROTATION LOCKED" if player.disguise.locked else "rotation free  (%s locks)" % _key(PhBindings.LOCK)
	elif player.set_aside != null:
		_as.text = "Showing yourself  (+points)"
		_lock.text = "%s to hide again" % _key(PhBindings.REVEAL)
	else:
		_as.text = "Look at a prop and press %s" % _key(PhBindings.DISGUISE)


func _draw_hints(side: int) -> void:
	if player == null or not player.is_alive() or player.watching or side == 0 or is_blindfolded():
		_hints.text = ""
		return

	var lines := PackedStringArray()

	if side == PhGame.PROPS:
		lines.append("%s  Become what you look at" % _key(PhBindings.DISGUISE))
		lines.append("%s  Show yourself / hide again" % _key(PhBindings.REVEAL))
		lines.append("%s  Lock rotation" % _key(PhBindings.LOCK))
		lines.append("%s / %s  Taunt / pick one" % [_key(PhBindings.TAUNT), _key(PhBindings.TAUNT_MENU)])
		lines.append("%s %s %s %s  Tilt   %s  Upright" % [
			_key(PhBindings.TILT_FORWARD), _key(PhBindings.TILT_BACK),
			_key(PhBindings.TILT_LEFT), _key(PhBindings.TILT_RIGHT), _key(PhBindings.STRAIGHTEN)])

		if player.reveal_wait > 0.0 and player.is_disguised():
			lines.append("show yourself again in %d s" % int(ceilf(player.reveal_wait)))
	else:
		lines.append("Shoot the props. Shooting furniture hurts you.")
		lines.append("%s  Reload   1-3  Weapons" % _key(PhBindings.RELOAD))

	_hints.text = "\n".join(lines)


func _draw_meter(side: int) -> void:
	var shown := side == PhGame.PROPS and player != null and player.is_alive() \
		and game.phase == PhGame.Phase.SEEK and game.config.show_taunt_meter and player.taunt_meter > 0.02
	_meter_back.visible = shown
	_meter_fill.visible = shown
	_meter_label.text = ""

	if not shown:
		return

	_meter_fill.offset_right = 112.0 + 200.0 * clampf(player.taunt_meter, 0.0, 1.0)
	var until := (1.0 - player.taunt_meter) * game.config.auto_taunt_seconds
	_meter_label.text = "Move, or you taunt in %d s" % int(ceilf(until))


func _key(action: StringName) -> String:
	return str(key_fn.call(action)) if key_fn.is_valid() else String(action)


func present_blind(delta: float) -> void:
	if blind_overlay == null:
		return

	var step := maxf(delta, 0.0) / BLIND_FADE_SEC
	blind_overlay.modulate.a = move_toward(blind_overlay.modulate.a, 1.0 if is_blind() else 0.0, step)
	blind_overlay.visible = blind_overlay.modulate.a > 0.0

	var folded := is_blindfolded()
	blindfold.modulate.a = move_toward(blindfold.modulate.a, 1.0 if folded else 0.0, step)
	blindfold.visible = blindfold.modulate.a > 0.0

	if _blindfold_label != null:
		_blindfold_label.visible = folded

		if folded and game != null:
			var left := game.seconds_left()
			_blindfold_label.text = "Blindfolded while the props hide\n%d:%02d" % [int(left) / 60, int(left) % 60]


func is_blind() -> bool:
	return player != null and is_instance_valid(player) and player.blinded


## Whether this player is a hunter while the props hide.
func is_blindfolded() -> bool:
	return player != null and is_instance_valid(player) and game != null \
		and game.phase == PhGame.Phase.HIDE and game.team_of(player.player_id) == PhGame.HUNTERS \
		and player.is_alive()
