extends Node
## Mutable world state: clock, quest flags, per-location Resonance.
## A save system would serialise this node (plus actor state).

const TURN_BASED := 0
const REAL_TIME := 1
const MINUTES_PER_SECOND := 2.0

var preferred_mode := TURN_BASED
var flags: Dictionary = {}
var locations: Array = []
var minutes := 8.0 * 60.0
var clock_running := true


func reset() -> void:
	flags = {}
	locations = []
	minutes = 8.0 * 60.0
	clock_running = true


func _process(delta: float) -> void:
	if clock_running:
		minutes += delta * MINUTES_PER_SECOND


func hour() -> int:
	return int(minutes / 60.0) % 24


func day() -> int:
	return int(minutes / 1440.0) + 1


func time_text() -> String:
	var m := int(minutes) % 1440
	return "Day %d, %02d:%02d" % [day(), m / 60, m % 60]


func set_locations(list: Array) -> void:
	locations = []
	for l in list:
		var r: Array = l["rect"]
		locations.append({
			"id": str(l["id"]),
			"name": str(l["name"]),
			"rect": Rect2i(int(r[0]), int(r[1]), int(r[2]), int(r[3])),
			"resonance": int(l.get("resonance", 50)),
		})


func location_at(t: Vector2i) -> Dictionary:
	for l in locations:
		var r: Rect2i = l["rect"]
		if r.has_point(t):
			return l
	return {}


func resonance_at(t: Vector2i) -> int:
	var l := location_at(t)
	return int(l.get("resonance", 50))


func get_location(id: String) -> Dictionary:
	for l in locations:
		if l["id"] == id:
			return l
	return {}


func shift_resonance(id: String, amount: int) -> void:
	var l := get_location(id)
	if l.is_empty():
		return
	var before: int = l["resonance"]
	l["resonance"] = clampi(before + amount, 0, 100)
	Events.resonance_changed.emit(id, l["resonance"])
	Events.post("[color=#9fd8ff]Resonance in %s: %d -> %d[/color]" % [l["name"], before, l["resonance"]])


static func resonance_word(v: int) -> String:
	if v < 25:
		return "dead, machines run true"
	if v < 45:
		return "thin"
	if v < 65:
		return "steady"
	if v < 85:
		return "strong, magic runs thick"
	return "overflowing"


func get_flag(flag: String, default: Variant = null) -> Variant:
	return flags.get(flag, default)


func set_flag(flag: String, value: Variant) -> void:
	flags[flag] = value
	flags_changed.emit()
	Events.flags_changed.emit()


signal flags_changed
