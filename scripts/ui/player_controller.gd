extends Node
## Mouse and keyboard input for the player character. Every action goes
## through CombatManager, the same entry points the AI uses.

var world = null
var combat = null
var hud = null
var rig = null
var slot := 1


func _p() -> Variant:
	return world.player


# ---------------------------------------------------------------- slots

func _slot_profile() -> Dictionary:
	var p = _p()
	var w: Dictionary = p.weapon_data()
	match slot:
		1:
			return {"kind": "weapon", "alt": false, "profile": Rules.attack_profile(w, false)}
		2:
			if w.has("alt"):
				return {"kind": "weapon", "alt": true, "profile": Rules.attack_profile(w, true)}
			return {}
		_:
			var idx := slot - 3
			if idx < p.known_skills.size():
				var sid: String = p.known_skills[idx]
				return {"kind": "skill", "id": sid, "profile": DB.get_skill(sid)}
			return {}


func hotbar_text() -> String:
	var p = _p()
	if p == null:
		return ""
	var w: Dictionary = p.weapon_data()
	var names := [str(w.get("name", "Fists")), str(w["alt"].get("label", "Alt")) if w.has("alt") else "-"]
	for i in 2:
		names.append(str(DB.get_skill(p.known_skills[i]).get("name", "?")) if i < p.known_skills.size() else "-")
	var parts: PackedStringArray = []
	for i in 4:
		var cost := ""
		var prof: Dictionary = {}
		var keep := slot
		slot = i + 1
		prof = _slot_profile()
		slot = keep
		if not prof.is_empty():
			cost = " (%d AP)" % int(prof["profile"].get("ap", 0))
		parts.append(("[%d] %s%s" if i + 1 != slot else ">> [%d] %s%s <<") % [i + 1, names[i], cost])
	return "   ".join(parts)


# ---------------------------------------------------------------- input

func _unhandled_input(event: InputEvent) -> void:
	var p = _p()
	if p == null:
		return
	if event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_LEFT:
				_on_click(mb.position)
			MOUSE_BUTTON_RIGHT:
				_examine(mb.position)
			MOUSE_BUTTON_WHEEL_UP:
				rig.zoom_by(0.9)
			MOUSE_BUTTON_WHEEL_DOWN:
				rig.zoom_by(1.1)
	elif event is InputEventMouseMotion:
		_on_hover((event as InputEventMouseMotion).position)
	elif event is InputEventKey and event.pressed and not event.echo:
		var k := event as InputEventKey
		match k.keycode:
			KEY_T:
				combat.toggle_mode()
			KEY_SPACE, KEY_E:
				combat.end_turn(p)
			KEY_I:
				hud.toggle_inventory()
			KEY_ESCAPE:
				hud.close_panels()
			KEY_1:
				slot = 1
			KEY_2:
				slot = 2
			KEY_3:
				slot = 3
			KEY_4:
				slot = 4
			KEY_R:
				if p.is_dead:
					get_tree().reload_current_scene()


func _on_click(pos: Vector2) -> void:
	var p = _p()
	if p.is_dead or hud.is_blocking() or p.busy:
		return
	if combat.active and not combat.can_act(p):
		Events.post("[color=gray]Not your turn.[/color]")
		return
	var pick: Dictionary = world.pick(rig.camera, pos)
	var target = pick["actor"]
	var sp := _slot_profile()
	var is_heal: bool = sp.get("kind") == "skill" and sp["profile"].get("kind") == "heal"
	if target != null:
		if target.faction == "hostile" and not is_heal:
			_act_on(target)
		elif is_heal and target.faction in ["player", "ally"]:
			_act_on(target)
		elif target != p:
			_talk(target)
		return
	if pick["tile"] != null:
		_move_to(pick["tile"])


func _move_to(t: Vector2i) -> void:
	var p = _p()
	var path: Array = world.find_path(p.tile, t, p)
	if path.size() >= 2:
		p.cancel_move()
		p.move_along(path, combat)


func _act_on(target) -> void:
	var p = _p()
	var sp := _slot_profile()
	if sp.is_empty():
		Events.post("[color=gray]Nothing in that slot.[/color]")
		return
	var prof: Dictionary = sp["profile"]
	var reach := Rules.ft_to_tiles(int(prof.get("range", 5)))
	if combat.is_turn_based() and p.ap < float(prof.get("ap", 0)) and Rules.tile_distance(p.tile, target.tile) <= reach:
		Events.post("[color=gray]Not enough AP (%d needed). Press Space to end your turn.[/color]" % int(prof.get("ap", 0)))
		return
	if Rules.tile_distance(p.tile, target.tile) > reach:
		var path: Array = world.path_to_range(p, target.tile, reach)
		if path.size() < 2:
			Events.post("[color=gray]Can't reach %s.[/color]" % target.display_name)
			return
		p.cancel_move()
		await p.move_along(path, combat)
		if Rules.tile_distance(p.tile, target.tile) > reach or not combat.can_act(p):
			return
	if sp["kind"] == "skill":
		await combat.do_cast(p, target, sp["id"])
	else:
		await combat.do_attack(p, target, sp["alt"])


func _talk(target) -> void:
	if target.dialogue_id == "":
		Events.post("%s has nothing to say." % target.display_name)
		return
	if combat.active:
		Events.post("[color=gray]Not in the middle of a fight.[/color]")
		return
	var p = _p()
	if Rules.tile_distance(p.tile, target.tile) > 2:
		var path: Array = world.path_to_range(p, target.tile, 1)
		if path.size() < 2:
			return
		p.cancel_move()
		await p.move_along(path, combat)
		if Rules.tile_distance(p.tile, target.tile) > 2 or combat.active:
			return
	p.face_tile(target.tile)
	hud.open_dialogue(target)


func _examine(pos: Vector2) -> void:
	var pick: Dictionary = world.pick(rig.camera, pos)
	var a = pick["actor"]
	if a != null:
		var w: Dictionary = a.weapon_data()
		Events.post("[color=#9fd8ff]%s[/color]: %s %s, HP %d/%d, AC %d, wielding %s, aptitude %+d." % [a.display_name, a.race, a.faction, a.hp, a.max_hp, a.ac, w.get("name", "fists"), a.aptitude])
	elif pick["tile"] != null:
		var loc: Dictionary = GameState.location_at(pick["tile"])
		var r := int(loc.get("resonance", 50))
		Events.post("[color=#9fd8ff]%s[/color]: Resonance %d (%s). Arcane x%.2f, Gear misfire +%d%%." % [loc.get("name", "Wilds"), r, GameState.resonance_word(r), Rules.magic_multiplier("arcane", r, 0), roundi(Rules.misfire_chance(0.0, r, 0) * 100)])


func _on_hover(pos: Vector2) -> void:
	var p = _p()
	if p == null or rig == null:
		return
	var pick: Dictionary = world.pick(rig.camera, pos)
	var a = pick["actor"]
	if pick["tile"] != null:
		var col := Color(1, 1, 1, 0.22)
		if a != null and a.faction == "hostile":
			col = Color(1, 0.3, 0.3, 0.4)
		world.set_hover(a.tile if a != null else pick["tile"], true, col)
	else:
		world.set_hover(Vector2i.ZERO, false)
	if a == null:
		hud.set_hover("", pos)
		return
	var txt := "%s  HP %d/%d  AC %d" % [a.display_name, a.hp, a.max_hp, a.ac]
	if a.has_meta("resident_id"):
		txt += "\n" + Residents.describe_short(int(a.get_meta("resident_id")))
	if a.faction == "hostile" and not p.is_dead:
		var sp := _slot_profile()
		if not sp.is_empty():
			var prof: Dictionary = sp["profile"]
			var res: int = world.resonance_at(p.tile)
			var bonus := 0
			if sp["kind"] == "skill":
				bonus = Rules.mod(int(p.stats[prof.get("stat", "int")])) + Rules.PROFICIENCY
				txt += "\n%s: hit %d%%, power x%.2f" % [prof.get("name", "?"), roundi(Rules.hit_chance(bonus, a.ac) * 100), Rules.magic_multiplier(str(prof.get("school", "arcane")), res, p.aptitude)]
			else:
				bonus = Rules.attack_bonus(p, prof)
				txt += "\n%s: hit %d%%" % [prof.get("name", "?"), roundi(Rules.hit_chance(bonus, a.ac) * 100)]
				if prof.get("pool") == "gear":
					txt += ", misfire %d%%" % roundi(Rules.misfire_chance(float(prof.get("misfire", 0.02)), res, p.aptitude) * 100)
			var dist := Rules.tile_distance(p.tile, a.tile)
			txt += "\nDistance %d ft, reach %d ft" % [dist * 5, int(prof.get("range", 5))]
	elif a.dialogue_id != "":
		txt += "\nClick to talk"
	hud.set_hover(txt, pos)
