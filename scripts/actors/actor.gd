class_name Actor
extends Node3D
## Any character on the map: player, follower, resident or enemy.
## Built from a template in data/actors.json. Visuals are primitives
## so a real model can be dropped in later by replacing _build_visual().

signal died(actor)

const STEP_TIME := 0.2

var template_id := ""
var display_name := "Someone"
var race := ""
var faction := "neutral" # player, ally, neutral, hostile
var stats := {"str": 10, "dex": 10, "con": 10, "int": 10, "wis": 10, "cha": 10}
var max_hp := 10
var hp := 10
var ac := 10
var ap_max := 6
var ap: float = 6.0
var ap_debt := 0
var aptitude := 0 # -100 Gear ... 0 balanced ... +100 Arcane
var inventory := Inventory.new()
var known_skills: Array = []
var schedule: Array = []
var dialogue_id := ""
var group := ""
var aggro_radius := 0
var ai_controlled := true
var follows_player := false
var color := Color.WHITE

var tile := Vector2i.ZERO
var world = null
var is_dead := false
var busy := false
var moving := false
var in_combat := false
var initiative := 0
var skip_refill_once := false

var _move_token := 0
var _tween: Tween
var _body_mat: StandardMaterial3D
var _ring: MeshInstance3D
var _turn_ring: MeshInstance3D
var _label: Label3D
var _weapon_mesh: MeshInstance3D
var _weapon_mat: StandardMaterial3D
var _visual: Node3D


func apply_template(tpl: Dictionary) -> void:
	template_id = str(tpl.get("id", ""))
	display_name = str(tpl.get("name", display_name))
	race = str(tpl.get("race", ""))
	faction = str(tpl.get("faction", faction))
	var s: Dictionary = tpl.get("stats", {})
	for k in s:
		stats[k] = int(s[k])
	max_hp = int(tpl.get("hp", 10))
	hp = max_hp
	ac = int(tpl.get("ac", 10))
	ap_max = int(tpl.get("ap", 6))
	ap = ap_max
	aptitude = int(tpl.get("aptitude", 0))
	known_skills = tpl.get("skills", []).duplicate()
	schedule = tpl.get("schedule", [])
	dialogue_id = str(tpl.get("dialogue", ""))
	group = str(tpl.get("group", ""))
	aggro_radius = int(tpl.get("aggro", 0))
	ai_controlled = faction != "player"
	follows_player = bool(tpl.get("follows_player", false))
	color = Color(str(tpl.get("color", "#ffffff")))
	_build_visual()
	inventory.changed.connect(_update_weapon_visual)
	for inv in tpl.get("inventory", []):
		inventory.add(str(inv["id"]), int(inv.get("qty", 1)), inv.get("identified", null))
	if tpl.has("equip"):
		equip_entry(inventory.find_first(str(tpl["equip"])))


# ---------------------------------------------------------------- equipment

func equipped_entry() -> Variant:
	for e in inventory.entries:
		if e.get("equipped", false):
			return e
	return null


## The equipped weapon's data. Unidentified magic items keep their hidden
## powers dormant until identified.
func weapon_data() -> Dictionary:
	var e = equipped_entry()
	if e == null:
		return DB.get_item("fists").duplicate(true)
	var d: Dictionary = DB.get_item(e["id"]).duplicate(true)
	if not e["identified"]:
		d["name"] = d.get("unidentified_name", d.get("name", "?"))
		for k in ["bonus_damage", "special", "spell_power"]:
			d.erase(k)
	return d


func equip_entry(e) -> void:
	for x in inventory.entries:
		x["equipped"] = false
	if e != null:
		e["equipped"] = true
	inventory.changed.emit()
	Events.inventory_changed.emit()


func spell_power() -> int:
	return int(weapon_data().get("spell_power", 0))


# ---------------------------------------------------------------- schedule

func schedule_tile(hour: int) -> Vector2i:
	if schedule.is_empty():
		return tile
	var pick = schedule[schedule.size() - 1]
	for s in schedule:
		if int(s["hour"]) <= hour:
			pick = s
	return Vector2i(int(pick["tile"][0]), int(pick["tile"][1]))


# ---------------------------------------------------------------- movement

func set_tile_immediate(t: Vector2i) -> void:
	tile = t
	position = world.tile_to_world(t)


func cancel_move() -> void:
	_move_token += 1
	moving = false


func face_tile(t: Vector2i) -> void:
	var dir: Vector3 = world.tile_to_world(t) - position
	if dir.length_squared() > 0.001:
		rotation.y = atan2(-dir.x, -dir.z)


## Walks a path (first entry = current tile). In combat every step costs
## 1 AP through the combat manager, in either mode.
func move_along(path: Array, combat = null) -> void:
	_move_token += 1
	var token := _move_token
	moving = true
	for i in range(1, path.size()):
		if token != _move_token or is_dead:
			return
		var t: Vector2i = path[i]
		if world.is_blocked(t, self):
			break
		if combat != null and combat.active and in_combat:
			var ok: bool = await combat.wait_for_ap(self, 1.0)
			if not ok or token != _move_token:
				break
		while _tween != null and _tween.is_running():
			await get_tree().process_frame
		if token != _move_token or is_dead:
			return
		if world.is_blocked(t, self):
			break
		await step_to(t)
	if token == _move_token:
		moving = false


func step_to(t: Vector2i) -> void:
	face_tile(t)
	tile = t
	_tween = create_tween()
	_tween.tween_property(self, "position", world.tile_to_world(t), STEP_TIME)
	await _tween.finished


# ---------------------------------------------------------------- health

func take_damage(n: int, crit := false) -> void:
	if is_dead:
		return
	hp = maxi(0, hp - n)
	world.float_text(global_position, ("-%d!" if crit else "-%d") % n, Color("#ff6b5b"))
	_flash(Color("#ffffff"))
	if hp <= 0:
		die()


func heal(n: int) -> void:
	if is_dead:
		return
	hp = mini(max_hp, hp + n)
	world.float_text(global_position, "+%d" % n, Color("#7dff9a"))
	_flash(Color("#b9ffc8"))


func die() -> void:
	is_dead = true
	busy = false
	cancel_move()
	_label.visible = false
	_ring.visible = false
	_turn_ring.visible = false
	var tw := create_tween()
	tw.tween_property(_visual, "rotation:x", -PI / 2.0, 0.35)
	tw.parallel().tween_property(_visual, "position:y", 0.28, 0.35)
	died.emit(self)


# ---------------------------------------------------------------- visuals

func set_turn_highlight(on: bool) -> void:
	if _turn_ring:
		_turn_ring.visible = on and not is_dead


func play_attack(target, profile: Dictionary, tint := Color.WHITE) -> void:
	face_tile(target.tile)
	if profile.get("ranged", false) or profile.get("projectile", false):
		await world.fire_projectile(global_position + Vector3(0, 1.0, 0), target.global_position + Vector3(0, 0.9, 0), tint)
	else:
		var start := position
		var toward := position.lerp(target.position, 0.35)
		var tw := create_tween()
		tw.tween_property(self, "position", toward, 0.1)
		tw.tween_property(self, "position", start, 0.14)
		await tw.finished


func _process(_delta: float) -> void:
	if _label == null or is_dead:
		return
	var txt := display_name
	if in_combat or hp < max_hp:
		txt += "\n%d/%d" % [hp, max_hp]
	_label.text = txt


func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.85
	return m


func _build_visual() -> void:
	_visual = Node3D.new()
	add_child(_visual)
	var size_scale := 0.78 if race in ["halfling", "gnome"] else (0.9 if race == "dwarf" else 1.0)
	_visual.scale = Vector3(size_scale * (1.15 if race == "dwarf" else 1.0), size_scale, size_scale * (1.15 if race == "dwarf" else 1.0))

	_body_mat = _mat(color)
	var body := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.28
	cap.height = 1.3
	body.mesh = cap
	body.position.y = 0.65
	body.material_override = _body_mat
	_visual.add_child(body)

	var head := MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = 0.2
	sph.height = 0.4
	head.mesh = sph
	head.position.y = 1.48
	head.material_override = _mat(Color("#e8c9a8") if race != "orc" else Color("#7d9a5a"))
	_visual.add_child(head)

	_weapon_mat = _mat(Color.GRAY)
	_weapon_mesh = MeshInstance3D.new()
	var wb := BoxMesh.new()
	wb.size = Vector3(0.07, 0.07, 0.9)
	_weapon_mesh.mesh = wb
	_weapon_mesh.position = Vector3(0.33, 0.85, -0.25)
	_weapon_mesh.material_override = _weapon_mat
	_visual.add_child(_weapon_mesh)

	var ring_col: Color = {"player": Color("#4fa3ff"), "ally": Color("#5fe08a"), "hostile": Color("#ff4d4d")}.get(faction, Color("#d9d9d9"))
	_ring = _disc(0.42, ring_col, 0.55)
	add_child(_ring)
	_turn_ring = _disc(0.55, Color("#ffd84d"), 0.9)
	_turn_ring.position.y = 0.015
	_turn_ring.visible = false
	add_child(_turn_ring)

	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.font_size = 40
	_label.pixel_size = 0.008
	_label.outline_size = 8
	_label.position.y = 2.05
	_label.modulate = ring_col.lightened(0.3)
	add_child(_label)


func _disc(radius: float, c: Color, alpha: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = radius
	cyl.bottom_radius = radius
	cyl.height = 0.02
	mi.mesh = cyl
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(c, alpha)
	mi.material_override = m
	mi.position.y = 0.01
	return mi


func _update_weapon_visual() -> void:
	if _weapon_mesh == null:
		return
	var w := weapon_data()
	_weapon_mesh.visible = w.get("id", "fists") != "fists"
	var pool_col := {"gear": Color("#c79a4a"), "arcane": Color("#62c6d9"), "neutral": Color("#9a958c")}
	_weapon_mat.albedo_color = pool_col.get(str(w.get("pool", "neutral")), Color.GRAY)
	_weapon_mat.emission_enabled = w.get("pool") == "arcane"
	_weapon_mat.emission = Color("#62c6d9")


func _flash(c: Color) -> void:
	var tw := create_tween()
	tw.tween_property(_body_mat, "albedo_color", c, 0.05)
	tw.tween_property(_body_mat, "albedo_color", color, 0.2)
