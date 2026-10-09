extends DotNetMessage

const PhEvents := preload("ph_events.gd")

## Anything a client asks the authority for. Reliable, rare, to the server only.
##
## [b]None of these is a per-tick intent.[/b] Firing is a BUTTON, because it has to be
## ordered against the movement it was made with; this is for the other kind — "my world
## exists", "make me that lamp", "taunt", "I want to watch somebody else" — each of which
## happens once and must not be lost. A disguise is the server's look, not the client's: the
## request carries no prop, and the server casts the ray from where it has the player's eyes.

const NAME := &"ph.request"
const KIND_BITS := 4
const MAX_BODY := 256

var kind: int = 0
var body: PackedByteArray = PackedByteArray()


## [b]Built with [code]new(kind, body)[/code], and this file does not preload itself.[/b]
## It used to, for a typed [code]static func of() -> PhRequest[/code] factory. A script that
## [code]extends DotNetMessage[/code] and preloads ITSELF, first loaded from a module a
## running [DotServer] loads at runtime — which is how every deployed server loads this
## game — leaks the whole script graph at exit on Godot 4.7.2. Measured in
## mg-buses-from-hell (8ed866c) with a two-line reproduction. The registry decodes with a
## bare [code]new()[/code], which is why both arguments default.
func _init(p_kind: int = 0, p_body: PackedByteArray = PackedByteArray()) -> void:
	kind = p_kind
	body = p_body


func _type_name() -> StringName:
	return NAME


func _write(writer: DotNetWriter) -> void:
	writer.write_uint(kind, KIND_BITS)
	writer.write_bytes(body)


func _read(reader: DotNetReader) -> void:
	kind = reader.read_uint(KIND_BITS)
	body = reader.read_bytes(MAX_BODY)


func _validate() -> DotResult:
	if kind < 0 or kind >= PhEvents.Ask.size():
		return DotResult.fail(DotError.CODE_INVALID, "Unknown request kind %d." % kind)

	return DotResult.success(true)


func reader() -> DotNetReader:
	return DotNetReader.new(body)


func _to_string() -> String:
	return "PhRequest(%s, %d bytes)" % [PhEvents.ask_name(kind), body.size()]
