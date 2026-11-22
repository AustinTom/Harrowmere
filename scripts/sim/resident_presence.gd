class_name ResidentPresence
extends Node
## The ACTIVE level of detail: turns the loaded settlement's residents into
## Actors when their schedule puts them somewhere visible on this map, and
## removes them when they go indoors or leave the map.
##
## The area JSON maps the settlement's generated places onto tiles
## ("place_anchors"): outdoor places are where residents stand, indoor places
## are a door they walk into, and anything without an anchor is off the map
## (they walk to the nearest "exit"). Hand-written anchor characters already
## spawned by the area keep their own schedules; they're only linked to their
## resident record so they share gossip and opinions.

const MAX_ACTORS := 36
const TICK := 0.4
const HOMES_PER_DOOR := 3

var world = null
var s: Dictionary = {}
var anchors: Dictionary = {}
var place_info: Dictionary = {}
var spawned: Dictionary = {}
var targets: Dictionary = {}
var enabled := true

var _tick := 0.0
var _hour_seen := -1
var _rng := RandomNumberGenerator.new()


func setup(w, area: Dictionary) -> void:
	world = w
	s = Residents.settlement(str(area.get("settlement", "")))
	if s.is_empty():
		enabled = false
		return
	_rng.seed = 99
	var pa: Dictionary = area.get("place_anchors", {})
	for k in pa:
		if k.begins_with("_"):
			continue
		var tiles: Array = []
		for t in pa[k]:
			tiles.append(Vector2i(int(t[0]), int(t[1])))
		anchors[k] = tiles
	_build_place_info()
	_link_anchor_actors()
	sync(true)


func _build_place_info() -> void:
	var exits: Array = anchors.get("exit", [Vector2i.ZERO])
	var home_n := 0
	for pi in s["places"].size():
		var p: Dictionary = s["places"][pi]
		var kind: String = p["kind"]
		var h := hash([s["id"], pi])
		var info := {"mode": "exit", "tile": exits[h % exits.size()]}
		if anchors.has(kind):
			var list: Array = anchors[kind]
			if kind == "home":
				if home_n < list.size() * HOMES_PER_DOOR:
					info = {"mode": "door", "tile": list[home_n % list.size()]}
				home_n += 1
			elif p["outdoor"]:
				info = {"mode": "outdoor", "tile": list[h % list.size()]}
			else:
				info = {"mode": "door", "tile": list[h % list.size()]}
		place_info[pi] = info


func _link_anchor_actors() -> void:
	for id in s["residents"]:
		var r: Dictionary = Residents.resident(id)
		if r.get("tier", "") != "anchor":
			continue
		for a in world.actors:
			if a.template_id == r.get("template", ""):
				a.set_meta("resident_id", id)
				Residents.visible_ids[id] = true


func _process(delta: float) -> void:
	if not enabled or world == null:
		return
	_tick += delta
	if _tick < TICK:
		return
	_tick = 0.0
	if world.combat != null and world.combat.active:
		return
	if world.player == null or world.player.is_dead:
		return
	if GameState.hour() != _hour_seen:
		sync(false)
	_drive()


## Decides who should be on screen this hour and where they're heading.
func sync(initial: bool) -> void:
	_hour_seen = GameState.hour()
	var want := {}
	for id in s["residents"]:
		var r: Dictionary = Residents.resident(id)
		if r.get("tier", "") == "anchor" or not r.has("at"):
			continue
		var pi: int = r["at"]
		if pi < 0 or r["act"] == "sleep":
			continue
		var info: Dictionary = place_info.get(pi, {})
		if info.get("mode", "") == "outdoor":
			want[id] = info
	if want.size() > MAX_ACTORS:
		var ids: Array = want.keys()
		var ptile: Vector2i = world.player.tile if world.player != null else Vector2i.ZERO
		ids.sort_custom(func(a, b): return Rules.tile_distance(want[a]["tile"], ptile) < Rules.tile_distance(want[b]["tile"], ptile))
		var keep := {}
		for i in MAX_ACTORS:
			keep[ids[i]] = want[ids[i]]
		want = keep
	# Leaving: walk to where they're going (a door or an exit), then vanish.
	for id in spawned.keys():
		if want.has(id):
			continue
		var r: Dictionary = Residents.resident(id)
		var info: Dictionary = place_info.get(r.get("at", -1), {})
		var dest: Vector2i = info.get("tile", _nearest_exit(spawned[id].tile))
		if info.get("mode", "") == "outdoor":
			dest = _nearest_exit(spawned[id].tile)
		targets[id] = {"tile": dest, "leave": true, "stuck": 0}
	# Arriving or moving between outdoor places.
	for id in want:
		var dest := _spot_near(want[id]["tile"], id)
		if spawned.has(id):
			targets[id] = {"tile": dest, "leave": false, "stuck": 0, "anchor": want[id]["tile"]}
			continue
		if spawned.size() >= MAX_ACTORS:
			break
		var from := dest
		if not initial:
			from = _came_from(id)
		var a = _spawn(id, from)
		if a == null:
			continue
		targets[id] = {"tile": dest, "leave": false, "stuck": 0, "anchor": want[id]["tile"]}


func _came_from(id: int) -> Vector2i:
	var r: Dictionary = Residents.resident(id)
	var day := GameState.day()
	var hour := GameState.hour() - 1
	if hour < 0:
		hour = 23
		day -= 1
	var b := ResidentSchedule.block_at(Residents, r, s, day, hour)
	var info: Dictionary = place_info.get(b[0], {})
	if info.get("mode", "") == "door":
		return info["tile"]
	return _nearest_exit(info.get("tile", Vector2i.ZERO))


func _spawn(id: int, t: Vector2i) -> Variant:
	var tile := _free_near(t)
	if tile == Vector2i(-1, -1):
		return null
	var a = world.spawn_template(Residents.to_actor_template(id), tile)
	if a == null:
		return null
	a.set_meta("resident_id", id)
	a.quiet_label = true
	spawned[id] = a
	Residents.visible_ids[id] = true
	return a


func _despawn(id: int) -> void:
	var a = spawned.get(id)
	spawned.erase(id)
	targets.erase(id)
	Residents.visible_ids.erase(id)
	if a != null and is_instance_valid(a):
		world.despawn(a)


## Walks everyone a few tiles toward their target each tick.
func _drive() -> void:
	for id in spawned.keys():
		var a = spawned[id]
		if not is_instance_valid(a):
			spawned.erase(id)
			continue
		if a.busy or a.moving:
			continue
		var t: Dictionary = targets.get(id, {})
		if t.is_empty():
			continue
		var dest: Vector2i = t["tile"]
		if a.tile == dest or (t["leave"] and Rules.tile_distance(a.tile, dest) <= 0):
			if t["leave"]:
				_despawn(id)
			elif _rng.randf() < 0.06:
				# Idle: shuffle to another spot near where they're hanging about.
				t["tile"] = _spot_near(t.get("anchor", dest), id + _rng.randi_range(1, 99))
			continue
		var path: Array = world.find_path(a.tile, dest, a)
		if path.size() >= 2:
			a.move_along(path.slice(0, 8), world.combat)
			t["stuck"] = 0
		else:
			t["stuck"] += 1
			if t["leave"] and (Rules.tile_distance(a.tile, dest) <= 1 or t["stuck"] > 6):
				_despawn(id)
			elif t["stuck"] > 3:
				t["tile"] = _free_near(dest)


func _nearest_exit(from: Vector2i) -> Vector2i:
	var best := Vector2i.ZERO
	var bd := 1 << 30
	for e in anchors.get("exit", [Vector2i.ZERO]):
		var d := Rules.tile_distance(e, from)
		if d < bd:
			bd = d
			best = e
	return best


## A standing spot near an anchor, spread per resident so a crowd doesn't
## stack on one tile.
func _spot_near(anchor: Vector2i, salt: int) -> Vector2i:
	var h := hash([salt, anchor.x, anchor.y])
	var t := anchor + Vector2i(h % 5 - 2, (h / 5) % 5 - 2)
	if not world.in_bounds(t) or world.static_solid.has(t):
		return _free_near(anchor)
	return t


func _free_near(center: Vector2i) -> Vector2i:
	for ring in range(0, 4):
		for dx in range(-ring, ring + 1):
			for dy in range(-ring, ring + 1):
				var t := center + Vector2i(dx, dy)
				if maxi(absi(dx), absi(dy)) != ring:
					continue
				if not world.is_blocked(t, null):
					return t
	return Vector2i(-1, -1)
