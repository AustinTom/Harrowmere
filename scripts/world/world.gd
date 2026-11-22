class_name World
extends Node3D
## Builds an area from data/areas/*.json: ground per location (tinted by
## Resonance), structures (custom models from the Models registry, or
## placeholder primitives), pathfinding grid and actors. Also runs
## out-of-combat systems: aggro, follower following, resident schedules.

var area: Dictionary = {}
var size := Vector2i(40, 30)
var astar := AStarGrid2D.new()
var static_solid: Dictionary = {}
var actors: Array = []
var player = null
var combat = null

var _ground: Dictionary = {}
var _shrine_lights: Array = []
var _smoke: Array = []
var _hover: MeshInstance3D
var _hover_mat: StandardMaterial3D
var _tick := 0.0
var _triggers: Array = []


func load_area(path: String) -> void:
	area = DB.load_json(path)
	var sz: Array = area.get("size", [40, 30])
	size = Vector2i(int(sz[0]), int(sz[1]))
	GameState.set_locations(area.get("locations", []))
	_triggers = area.get("triggers", [])
	astar.region = Rect2i(Vector2i.ZERO, size)
	astar.cell_size = Vector2(1, 1)
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_CHEBYSHEV
	astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_CHEBYSHEV
	astar.update()
	_build_environment()
	_build_ground()
	for s in area.get("structures", []):
		_build_structure(s)
	for sp in area.get("spawns", []):
		spawn(str(sp["template"]), _v2i(sp["tile"]))
	_build_hover()
	Events.resonance_changed.connect(_on_resonance_changed)
	Events.flags_changed.connect(_on_flags_changed)
	_on_flags_changed()


func _v2i(a: Array) -> Vector2i:
	return Vector2i(int(a[0]), int(a[1]))


# ---------------------------------------------------------------- queries

func tile_to_world(t: Vector2i) -> Vector3:
	return Vector3(t.x + 0.5, 0.0, t.y + 0.5)


func in_bounds(t: Vector2i) -> bool:
	return t.x >= 0 and t.y >= 0 and t.x < size.x and t.y < size.y


func actor_at(t: Vector2i, include_dead := false) -> Variant:
	for a in actors:
		if a.tile == t and (include_dead or not a.is_dead):
			return a
	return null


func is_blocked(t: Vector2i, mover) -> bool:
	if not in_bounds(t) or static_solid.has(t):
		return true
	var o = actor_at(t)
	return o != null and o != mover


func party() -> Array:
	var out: Array = []
	for a in actors:
		if not a.is_dead and (a.faction == "player" or a.faction == "ally"):
			out.append(a)
	return out


func party_all() -> Array:
	var out: Array = []
	for a in actors:
		if a.faction == "player" or a.faction == "ally":
			out.append(a)
	return out


func resonance_at(t: Vector2i) -> int:
	return GameState.resonance_at(t)


func find_path(from: Vector2i, to: Vector2i, mover) -> Array:
	if not in_bounds(to) or static_solid.has(to) or from == to:
		return []
	var temp: Array = []
	for a in actors:
		if a.is_dead or a == mover:
			continue
		if a.tile == to:
			return []
		astar.set_point_solid(a.tile, true)
		temp.append(a.tile)
	var path := astar.get_id_path(from, to)
	for t in temp:
		astar.set_point_solid(t, static_solid.has(t))
	var out: Array = []
	for p in path:
		out.append(p)
	return out


## Shortest path to any free tile within `reach` tiles of target_tile.
func path_to_range(mover, target_tile: Vector2i, reach: int) -> Array:
	if Rules.tile_distance(mover.tile, target_tile) <= reach:
		return [mover.tile]
	var cands: Array = []
	var r := mini(reach, 12)
	for dx in range(-r, r + 1):
		for dy in range(-r, r + 1):
			var t := target_tile + Vector2i(dx, dy)
			if t == target_tile or is_blocked(t, mover):
				continue
			cands.append(t)
	var from: Vector2i = mover.tile
	cands.sort_custom(func(a, b): return Rules.tile_distance(a, from) < Rules.tile_distance(b, from))
	var best: Array = []
	for i in mini(cands.size(), 10):
		var p := find_path(from, cands[i], mover)
		if p.size() >= 2 and (best.is_empty() or p.size() < best.size()):
			best = p
	return best


## Screen point -> {actor, tile}. Actors are picked by their on-screen body,
## which matters in an isometric view where bodies overlap tiles behind them.
func pick(camera: Camera3D, screen_pos: Vector2) -> Dictionary:
	var best = null
	var px_per_unit := camera.get_viewport().get_visible_rect().size.y / camera.size
	var best_d := 0.45 * px_per_unit
	for a in actors:
		if a.is_dead:
			continue
		for h in [0.3, 0.8, 1.4]:
			var sp := camera.unproject_position(a.global_position + Vector3(0, h, 0))
			var d := sp.distance_to(screen_pos)
			if d < best_d:
				best_d = d
				best = a
	var tile = null
	var hit = Plane(Vector3.UP, 0.0).intersects_ray(camera.project_ray_origin(screen_pos), camera.project_ray_normal(screen_pos))
	if hit != null:
		var t := Vector2i(floori(hit.x), floori(hit.z))
		if in_bounds(t):
			tile = t
	return {"actor": best, "tile": tile}


# ---------------------------------------------------------------- spawning

func spawn(template_id: String, t: Vector2i) -> Variant:
	var tpl: Dictionary = DB.get_actor_template(template_id)
	if tpl.is_empty():
		push_error("Unknown actor template: " + template_id)
		return null
	var a := Actor.new()
	a.name = template_id
	a.world = self
	add_child(a)
	a.apply_template(tpl)
	a.set_tile_immediate(t)
	a.died.connect(_on_actor_died)
	actors.append(a)
	if a.faction == "player":
		player = a
	return a


func start_combat_with(h) -> void:
	var members: Array = []
	for a in actors:
		if a.is_dead or a.faction != "hostile":
			continue
		if a == h or (h.group != "" and a.group == h.group):
			members.append(a)
	combat.start(members)


func _on_actor_died(a) -> void:
	Events.post("%s falls." % a.display_name)
	if a.faction == "hostile" and player != null and not player.is_dead:
		var got: PackedStringArray = []
		for e in a.inventory.entries.duplicate():
			player.inventory.add(e["id"], int(e["qty"]), e["identified"])
			got.append(DB.entry_name(e) + (" x%d" % e["qty"] if e["qty"] > 1 else ""))
		a.inventory.clear()
		if not got.is_empty():
			Events.post("Looted from %s: %s" % [a.display_name, ", ".join(got)])
	combat.on_actor_died(a)
	_check_triggers()


func _check_triggers() -> void:
	for tr in _triggers:
		if tr.get("on") != "group_cleared":
			continue
		var alive := false
		for a in actors:
			if a.group == tr["group"] and not a.is_dead:
				alive = true
		if alive:
			continue
		var cur := str(GameState.get_flag(str(tr["flag"]), ""))
		if cur in tr.get("unless", []):
			continue
		GameState.set_flag(str(tr["flag"]), tr["value"])
		if tr.has("log"):
			Events.post("[color=#ffd84d]%s[/color]" % tr["log"])


# ---------------------------------------------------------------- systems

func _process(delta: float) -> void:
	_tick += delta
	if _tick < 0.25:
		return
	_tick = 0.0
	if combat == null or combat.active or player == null or player.is_dead:
		return
	_check_aggro()
	_update_followers()
	_update_schedules()


func _check_aggro() -> void:
	for h in actors:
		if h.is_dead or h.faction != "hostile" or h.aggro_radius <= 0:
			continue
		for p in party():
			if Rules.tile_distance(h.tile, p.tile) <= h.aggro_radius:
				Events.post("%s spots you." % h.display_name)
				start_combat_with(h)
				return


func _free_tile_near(center: Vector2i, mover) -> Variant:
	var best = null
	var best_d := 999
	for ring in [1, 2]:
		for dx in range(-ring, ring + 1):
			for dy in range(-ring, ring + 1):
				var t := center + Vector2i(dx, dy)
				if Rules.tile_distance(t, center) != ring or is_blocked(t, mover):
					continue
				var d := Rules.tile_distance(t, mover.tile)
				if d < best_d:
					best = t
					best_d = d
		if best != null:
			return best
	return best


func _update_followers() -> void:
	for f in actors:
		if f.is_dead or not f.follows_player or f.moving or f.busy:
			continue
		if Rules.tile_distance(f.tile, player.tile) <= 2:
			continue
		var dest = _free_tile_near(player.tile, f)
		if dest == null:
			continue
		var path := find_path(f.tile, dest, f)
		if path.size() >= 2:
			f.move_along(path, combat)


func _update_schedules() -> void:
	var hour := GameState.hour()
	for a in actors:
		if a.is_dead or a.schedule.is_empty() or a.moving or a.busy or a.in_combat:
			continue
		var dest: Vector2i = a.schedule_tile(hour)
		if dest == a.tile:
			continue
		var path := find_path(a.tile, dest, a)
		if path.size() >= 2:
			a.move_along(path.slice(0, 6), combat)


func on_turn_changed(actor) -> void:
	for a in actors:
		a.set_turn_highlight(a == actor)


# ---------------------------------------------------------------- visuals

func set_hover(t: Vector2i, on: bool, c := Color(1, 1, 1, 0.22)) -> void:
	_hover.visible = on
	if on:
		_hover.position = tile_to_world(t) + Vector3(0, 0.03, 0)
		_hover_mat.albedo_color = c


func float_text(at: Vector3, text: String, c: Color) -> void:
	var l := Label3D.new()
	l.text = text
	l.modulate = c
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.font_size = 56
	l.outline_size = 12
	l.pixel_size = 0.009
	add_child(l)
	l.global_position = at + Vector3(0, 2.3, 0)
	var tw := l.create_tween()
	tw.tween_property(l, "global_position", l.global_position + Vector3(0, 1.0, 0), 0.9)
	tw.parallel().tween_property(l, "modulate:a", 0.0, 0.9)
	tw.tween_callback(l.queue_free)


func fire_projectile(from: Vector3, to: Vector3, c: Color) -> void:
	var m := MeshInstance3D.new()
	var s := SphereMesh.new()
	s.radius = 0.09
	s.height = 0.18
	m.mesh = s
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = c
	m.material_override = mat
	add_child(m)
	m.global_position = from
	var tw := m.create_tween()
	tw.tween_property(m, "global_position", to, clampf(from.distance_to(to) / 30.0, 0.08, 0.35))
	await tw.finished
	m.queue_free()


static func resonance_color(v: int) -> Color:
	return Color("#6b5f52").lerp(Color("#4c8f72"), clampf(v / 100.0, 0.0, 1.0))


func _on_resonance_changed(id: String, value: int) -> void:
	if _ground.has(id):
		var m: StandardMaterial3D = _ground[id].material_override
		m.albedo_color = resonance_color(value)
	for e in _shrine_lights:
		if e["loc"] == id:
			e["light"].light_energy = value / 30.0


func _on_flags_changed() -> void:
	var lit := str(GameState.get_flag("pump_choice", "")) == "lit"
	for p in _smoke:
		p.emitting = lit


func _build_environment() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -30, 0)
	sun.shadow_enabled = true
	sun.light_energy = 0.85
	sun.light_color = Color("#fff1dc")
	add_child(sun)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("#1b2129")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("#a9bdd1")
	env.ambient_light_energy = 0.4
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	# Frozen ground beyond the playable area.
	var outer := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(size.x + 60, size.y + 60)
	outer.mesh = pm
	outer.position = Vector3(size.x / 2.0, -0.02, size.y / 2.0)
	outer.material_override = _mat(Color("#c9d3db"))
	add_child(outer)


func _build_ground() -> void:
	for loc in GameState.locations:
		var r: Rect2i = loc["rect"]
		var mi := MeshInstance3D.new()
		var pm := PlaneMesh.new()
		pm.size = Vector2(r.size.x, r.size.y)
		mi.mesh = pm
		mi.position = Vector3(r.position.x + r.size.x / 2.0, 0, r.position.y + r.size.y / 2.0)
		mi.material_override = _mat(resonance_color(int(loc["resonance"])))
		add_child(mi)
		_ground[loc["id"]] = mi


func _build_hover() -> void:
	_hover = MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(0.95, 0.95)
	_hover.mesh = pm
	_hover_mat = StandardMaterial3D.new()
	_hover_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_hover_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_hover_mat.albedo_color = Color(1, 1, 1, 0.22)
	_hover.material_override = _hover_mat
	_hover.visible = false
	add_child(_hover)


func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.95
	return m


func _box(parent: Node3D, sz: Vector3, pos: Vector3, c: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = sz
	mi.mesh = b
	mi.position = pos
	mi.material_override = _mat(c)
	parent.add_child(mi)
	return mi


func _cyl(parent: Node3D, radius: float, h: float, pos: Vector3, c: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = radius
	cm.bottom_radius = radius
	cm.height = h
	mi.mesh = cm
	mi.position = pos
	mi.material_override = _mat(c)
	parent.add_child(mi)
	return mi


func _build_structure(s: Dictionary) -> void:
	var ra: Array = s["rect"]
	var r := Rect2i(int(ra[0]), int(ra[1]), int(ra[2]), int(ra[3]))
	for x in range(r.position.x, r.end.x):
		for y in range(r.position.y, r.end.y):
			var t := Vector2i(x, y)
			static_solid[t] = true
			astar.set_point_solid(t, true)
	var node := Node3D.new()
	node.position = Vector3(r.position.x + r.size.x / 2.0, 0, r.position.y + r.size.y / 2.0)
	add_child(node)
	var w := float(r.size.x)
	var d := float(r.size.y)
	var kind := str(s.get("kind", "box"))
	var model: Node3D = null
	var spec := Models.structure_spec(s)
	if not spec.is_empty():
		model = Models.instantiate(spec)
	if model != null:
		# Footprint is centred on the node; "facing" turns the model in 90 degree steps.
		model.rotation_degrees.y += float(s.get("facing", 0))
		node.add_child(model)
	else:
		_build_structure_placeholder(node, kind, w, d)
	_add_structure_fx(node, kind, r, model)


## Gameplay effects that belong to a kind of structure, model or not. A model
## can place them with Empties named marker_light / marker_smoke.
func _add_structure_fx(node: Node3D, kind: String, r: Rect2i, model: Node3D) -> void:
	var w := float(r.size.x)
	var d := float(r.size.y)
	match kind:
		"shrine":
			var light := OmniLight3D.new()
			light.position = _marker_pos(node, model, "marker_light", Vector3(0, 2.3, 0))
			light.light_color = Color("#7fd6ff")
			light.omni_range = 8.0
			var loc := GameState.location_at(r.position)
			light.light_energy = int(loc.get("resonance", 50)) / 30.0
			node.add_child(light)
			_shrine_lights.append({"loc": loc.get("id", ""), "light": light})
		"pumphouse":
			var smoke := CPUParticles3D.new()
			smoke.position = _marker_pos(node, model, "marker_smoke", Vector3(w / 2.0 - 0.9, 5.6, -d / 2.0 + 0.9))
			smoke.amount = 30
			smoke.lifetime = 3.0
			smoke.direction = Vector3(0.2, 1, 0)
			smoke.spread = 12.0
			smoke.gravity = Vector3(0.3, 0.5, 0)
			smoke.initial_velocity_min = 0.6
			smoke.initial_velocity_max = 1.1
			smoke.scale_amount_min = 0.6
			smoke.scale_amount_max = 1.4
			var pm2 := SphereMesh.new()
			pm2.radius = 0.25
			pm2.height = 0.5
			smoke.mesh = pm2
			var sm2 := StandardMaterial3D.new()
			sm2.albedo_color = Color(0.25, 0.25, 0.27, 0.6)
			sm2.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			smoke.material_override = sm2
			smoke.emitting = false
			node.add_child(smoke)
			_smoke.append(smoke)


func _marker_pos(node: Node3D, model: Node3D, marker: String, fallback: Vector3) -> Vector3:
	if model == null:
		return fallback
	var m := Models.find_socket(model, marker)
	if m == null:
		return fallback
	return Models._local_xf(m, node).origin


func _build_structure_placeholder(node: Node3D, kind: String, w: float, d: float) -> void:
	match kind:
		"house":
			_box(node, Vector3(w - 0.1, 1.8, d - 0.1), Vector3(0, 0.9, 0), Color("#a39074"))
			var roof := MeshInstance3D.new()
			var pm := PrismMesh.new()
			pm.size = Vector3(w + 0.3, 1.0, d + 0.3)
			roof.mesh = pm
			roof.position.y = 2.3
			roof.material_override = _mat(Color("#6e4a3a"))
			node.add_child(roof)
			_box(node, Vector3(0.6, 1.1, 0.05), Vector3(0, 0.55, d / 2.0 - 0.02), Color("#4a3426"))
		"shrine":
			_box(node, Vector3(w, 0.4, d), Vector3(0, 0.2, 0), Color("#8d939c"))
			_box(node, Vector3(0.45, 1.6, 0.45), Vector3(0, 1.2, 0), Color("#b9c0c9"))
			var orb := MeshInstance3D.new()
			var sm := SphereMesh.new()
			sm.radius = 0.3
			sm.height = 0.6
			orb.mesh = sm
			orb.position.y = 2.3
			var om := StandardMaterial3D.new()
			om.albedo_color = Color("#9fe7ff")
			om.emission_enabled = true
			om.emission = Color("#62c6d9")
			om.emission_energy_multiplier = 2.0
			orb.material_override = om
			node.add_child(orb)
		"well":
			_cyl(node, 0.42, 0.7, Vector3(0, 0.35, 0), Color("#7f858c"))
			_cyl(node, 0.32, 0.72, Vector3(0, 0.37, 0), Color("#2b4a5c"))
		"pumphouse":
			_box(node, Vector3(w - 0.1, 3.0, d - 0.1), Vector3(0, 1.5, 0), Color("#5a4a44"))
			_box(node, Vector3(w + 0.2, 0.25, d + 0.2), Vector3(0, 3.1, 0), Color("#3b3533"))
			var chimney_pos := Vector3(w / 2.0 - 0.9, 4.2, -d / 2.0 + 0.9)
			_cyl(node, 0.38, 2.6, chimney_pos, Color("#3b3533"))
			_cyl(node, 0.7, 1.6, Vector3(-w / 2.0 - 0.1, 0.8, 0.8), Color("#8a6a3e")).rotation_degrees.z = 90
		"coal":
			_box(node, Vector3(w - 0.2, 0.6, d - 0.2), Vector3(0, 0.3, 0), Color("#1f1f22"))
			_box(node, Vector3(w * 0.5, 0.4, d * 0.5), Vector3(0.1, 0.75, 0.1), Color("#26262a"))
		"crate":
			_box(node, Vector3(0.8, 0.8, 0.8), Vector3(0, 0.4, 0), Color("#8a6a3e"))
		"fence":
			var fsz := Vector3(0.12, 1.0, d) if w == 1.0 else Vector3(w, 1.0, 0.12)
			_box(node, fsz, Vector3(0, 0.5, 0), Color("#5d4b3a"))
		_:
			_box(node, Vector3(w, 1.0, d), Vector3(0, 0.5, 0), Color("#888888"))
