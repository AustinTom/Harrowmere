class_name Actor
extends Node3D
## Any character on the map: player, follower, resident or enemy.
## Built from a template in data/actors.json. Visuals are primitives
## so a real model can be dropped in later by replacing _build_visual().
##
## The character's build lives in `sheet` (CharacterSheet). The plain fields
## below (stats, max_hp, ac, ap_max, aptitude, known_skills) are derived from
## it by refresh(), so combat code can keep reading them directly.

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
var known_skills: Array = [] ## active ability ids (derived from the sheet)
var sheet: CharacterSheet = null
var statuses: Array = [] ## [{id, rounds, source}]
var natural_weapon: Dictionary = {}
var summoned := false
var summon_rounds := 0
var relentless_used := false
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
	faction = str(tpl.get("faction", faction))
	if tpl.has("sheet"):
		sheet = CharacterSheet.from_dict(tpl["sheet"])
	elif tpl.has("gen"):
		sheet = CharacterGen.generate(tpl["gen"])
		if tpl.has("grade"):
			sheet.grade = str(tpl["grade"])
	else:
		sheet = CharacterGen.from_legacy(tpl)
	race = sheet.race
	if tpl.has("name"):
		display_name = str(tpl["name"])
	else:
		var nrng := RandomNumberGenerator.new()
		nrng.seed = int(tpl.get("gen", {}).get("seed", hash(template_id)))
		display_name = NameGen.make(race, sheet.gender, nrng)
	natural_weapon = tpl.get("natural_weapon", {})
	summoned = bool(tpl.get("summoned", false))
	refresh(true)
	ap = ap_max
	schedule = tpl.get("schedule", [])
	dialogue_id = str(tpl.get("dialogue", ""))
	group = str(tpl.get("group", ""))
	aggro_radius = int(tpl.get("aggro", 0))
	ai_controlled = faction != "player"
	follows_player = bool(tpl.get("follows_player", false))
	color = Color(str(tpl.get("color", "#ffffff")))
	_build_visual()
	inventory.changed.connect(_update_weapon_visual)
	inventory.changed.connect(refresh)
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
		if not natural_weapon.is_empty():
			var nw := natural_weapon.duplicate(true)
			nw["id"] = "natural"
			return nw
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


# ---------------------------------------------------------------- character
# The API other systems use (crafting, residents, UI). See docs/character-system.md.

## Recomputes stats, HP, AC, AP, aptitude and abilities from the sheet,
## statuses and equipment. Called whenever any of those change.
func refresh(full_heal := false) -> void:
	if sheet == null:
		return
	var mods: Array = []
	for st in statuses:
		mods.append_array(DB.statuses.get(st["id"], {}).get("modifiers", []))
	var e = equipped_entry()
	if e != null and e.get("identified", true):
		mods.append_array(DB.get_item(e["id"]).get("modifiers", []))
		mods.append_array(e.get("modifiers", []))
	sheet.extra_modifiers = mods
	stats = sheet.stats_dict()
	var old_max := max_hp
	max_hp = sheet.max_hp()
	if full_heal:
		hp = max_hp
	elif max_hp > old_max:
		hp += max_hp - old_max
	hp = mini(hp, max_hp)
	ac = sheet.ac()
	ap_max = sheet.ap_max()
	aptitude = sheet.aptitude()
	known_skills = sheet.active_abilities()


func level() -> int:
	return sheet.level


func skill_bonus(id: String) -> int:
	return sheet.skill_bonus(id)


func skill_rank(id: String) -> int:
	return sheet.skill_rank(id)


func tier(discipline_id: String) -> int:
	return sheet.tier(discipline_id)


func weapon_skill_bonus(skill_id: String) -> int:
	return sheet.weapon_skill_bonus(skill_id)


func cast_rank_bonus(discipline_id: String) -> int:
	return sheet.cast_rank_bonus(discipline_id)


func save_bonus(stat_id: String, vs_magic := false) -> int:
	return sheet.save_bonus(stat_id, vs_magic)


func initiative_bonus() -> int:
	return sheet.initiative_bonus()


func mod_total(target: String) -> float:
	return sheet.mod_total(target)


func has_flag(flag: String) -> bool:
	return sheet.has_flag(flag)


func can_buy(kind: String, id: String) -> Dictionary:
	return sheet.can_buy(kind, id)


func buy(kind: String, id: String) -> bool:
	if not sheet.buy(kind, id):
		return false
	_changed()
	return true


func spend_points(kind: String, amount: int, pool := "neutral") -> bool:
	if not sheet.spend_points(kind, amount, pool):
		return false
	_changed()
	return true


func schematic_picks_left(discipline_id: String) -> int:
	return sheet.schematic_picks_left(discipline_id)


func pick_schematic(discipline_id: String, schematic_id: String) -> bool:
	if not sheet.pick_schematic(discipline_id, schematic_id):
		return false
	_changed()
	return true


## Adds XP and handles level-ups. AI-run characters spend their new CP
## the way their archetype would; the player spends theirs on the sheet.
func add_xp(amount: int) -> int:
	var gained := sheet.add_xp(amount)
	if gained > 0:
		if ai_controlled and sheet.archetype != "":
			var rng := RandomNumberGenerator.new()
			rng.seed = hash(template_id) + sheet.level
			CharacterGen.auto_spend(sheet, rng)
		refresh()
		hp = max_hp
		Events.leveled_up.emit(self, sheet.level)
		if world != null:
			world.float_text(global_position + Vector3(0, 0.6, 0), "LEVEL %d" % sheet.level, Color("#ffd84d"))
	Events.character_changed.emit(self)
	return gained


func _changed() -> void:
	sheet.invalidate()
	refresh()
	Events.character_changed.emit(self)


# ---------------------------------------------------------------- statuses

func has_status(id: String) -> bool:
	for st in statuses:
		if st["id"] == id:
			return true
	return false


func add_status(id: String, rounds: int, source := "") -> void:
	if is_dead or not DB.statuses.has(id):
		return
	for st in statuses:
		if st["id"] == id:
			st["rounds"] = maxi(int(st["rounds"]), rounds)
			return
	statuses.append({"id": id, "rounds": rounds, "source": source})
	refresh()
	if world != null:
		var sd: Dictionary = DB.statuses[id]
		world.float_text(global_position + Vector3(0, 0.3, 0), str(sd.get("name", id)).to_lower(), Color(str(sd.get("color", "#ffffff"))))


func remove_status(id: String) -> void:
	for i in range(statuses.size() - 1, -1, -1):
		if statuses[i]["id"] == id:
			statuses.remove_at(i)
	refresh()


## Removes every status of a kind ("harm" or "boon"), or all with "".
func clear_statuses(kind := "") -> int:
	var n := 0
	for i in range(statuses.size() - 1, -1, -1):
		if kind == "" or DB.statuses.get(statuses[i]["id"], {}).get("kind") == kind:
			statuses.remove_at(i)
			n += 1
	refresh()
	return n


## One round passes: per-round effects fire, durations count down.
func tick_statuses() -> void:
	if is_dead or statuses.is_empty():
		return
	var expired := false
	for st in statuses.duplicate():
		var sd: Dictionary = DB.statuses.get(st["id"], {})
		var tick: Dictionary = sd.get("tick", {})
		if tick.get("type") == "damage":
			var n := Rules.roll_dice(str(tick.get("dice", "1")))
			Events.post("%s takes %d from %s." % [display_name, n, str(sd.get("name", st["id"])).to_lower()])
			take_damage(n, false, str(tick.get("damage_type", "physical")))
		elif tick.get("type") == "heal":
			heal(Rules.roll_dice(str(tick.get("dice", "1"))))
		if is_dead:
			return
		st["rounds"] = int(st["rounds"]) - 1
		if st["rounds"] <= 0:
			statuses.erase(st)
			expired = true
	if expired:
		refresh()


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
		if combat != null and combat.active and in_combat and has_flag("rooted"):
			if not ai_controlled:
				Events.post("[color=gray]%s is rooted and can't move.[/color]" % display_name)
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

func take_damage(n: int, crit := false, damage_type := "") -> void:
	if is_dead:
		return
	if damage_type != "" and sheet != null:
		var res := sheet.resist(damage_type)
		if res != 0.0:
			n = maxi(0, roundi(n * (1.0 - res / 100.0)))
			if n == 0:
				world.float_text(global_position, "immune", Color("#bbbbbb"))
				return
	if hp - n <= 0 and has_flag("relentless") and not relentless_used and hp > 1:
		relentless_used = true
		n = hp - 1
		Events.post("[color=#ffb347]%s refuses to fall![/color]" % display_name)
	hp = maxi(0, hp - n)
	world.float_text(global_position, ("-%d!" if crit else "-%d") % n, Color("#ff6b5b"))
	_flash(Color("#ffffff"))
	if hp <= 0:
		die()


## Heals and returns the amount. Wrought (heal_immune) only take repairs.
func heal(n: int, repair := false) -> int:
	if is_dead:
		return 0
	if has_flag("heal_immune") and not repair:
		world.float_text(global_position, "no effect", Color("#bbbbbb"))
		return 0
	var before := hp
	hp = mini(max_hp, hp + n)
	world.float_text(global_position, "+%d" % n, Color("#7dff9a"))
	_flash(Color("#b9ffc8"))
	return hp - before


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
	var sc: Array = DB.races.get(race, {}).get("body", {}).get("scale", [1.0, 1.0, 1.0])
	_visual.scale = Vector3(float(sc[0]), float(sc[1]), float(sc[2])) * (0.7 if summoned and race == "" else 1.0)

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
