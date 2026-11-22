extends Node
## Mouse and keyboard input for the player character. Every action goes
## through CombatManager, the same entry points the AI uses.

var world = null
var combat = null
var hud = null
var rig = null
var slot := 1
var ability_page := 0

const ABILITY_SLOTS := 7 ## keys 3-9


func _p() -> Variant:
	return world.player


# ---------------------------------------------------------------- slots

func _slot_profile() -> Dictionary:
	return _profile_for(slot)


func _page_abilities() -> Array:
	var p = _p()
	var all: Array = p.known_skills
	var start := ability_page * ABILITY_SLOTS
	if start >= all.size():
		ability_page = 0
		start = 0
	return all.slice(start, start + ABILITY_SLOTS)


func _profile_for(n: int) -> Dictionary:
	var p = _p()
	var w: Dictionary = p.weapon_data()
	match n:
		1:
			return {"kind": "weapon", "alt": false, "profile": Rules.attack_profile(w, false)}
		2:
			if w.has("alt"):
				return {"kind": "weapon", "alt": true, "profile": Rules.attack_profile(w, true)}
			return {}
		_:
			var page := _page_abilities()
			var idx := n - 3
			if idx < page.size():
				var sid: String = page[idx]
				var ab: Dictionary = DB.get_ability(sid)
				var prof := ab
				if ab.get("kind") == "weapon":
					prof = AbilityRules.technique_profile(w, ab)
					prof["kind"] = "weapon"
					prof["target"] = "enemy"
				return {"kind": "skill", "id": sid, "profile": prof, "ability": ab}
			return {}


## Abilities that go on the party rather than on an enemy.
func _is_support(sp: Dictionary) -> bool:
	if sp.get("kind") != "skill":
		return false
	return str(sp["ability"].get("target", "enemy")) in ["ally", "allies", "self", "tile"] or str(sp["ability"].get("kind")) == "utility"


func _is_self_cast(sp: Dictionary) -> bool:
	if sp.get("kind") != "skill":
		return false
	var ab: Dictionary = sp["ability"]
	return str(ab.get("target")) == "self" or int(ab.get("range", 0)) == 0 or str(ab.get("kind")) in ["summon", "utility"]


func hotbar_text() -> String:
	var p = _p()
	if p == null:
		return ""
	var parts: PackedStringArray = []
	for n in range(1, 3 + ABILITY_SLOTS):
		var prof := _profile_for(n)
		if prof.is_empty():
			if n <= 2:
				parts.append("[%d] -" % n)
			continue
		var nm := ""
		if n == 1:
			nm = str(prof["profile"].get("name", "Fists"))
		elif n == 2:
			nm = str(prof["profile"].get("label", "Alt"))
		else:
			nm = str(prof["ability"].get("name", "?"))
		var cost := " (%d)" % int(prof["profile"].get("ap", 0))
		parts.append(("[%d] %s%s" if n != slot else ">> [%d] %s%s <<") % [n, nm, cost])
	var pages := ceili(p.known_skills.size() / float(ABILITY_SLOTS))
	var tail := ("   [ ] page %d/%d" % [ability_page + 1, pages]) if pages > 1 else ""
	return "  ".join(parts) + tail


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
			KEY_C, KEY_K:
				hud.toggle_character()
			KEY_BRACKETLEFT:
				ability_page = maxi(0, ability_page - 1)
			KEY_BRACKETRIGHT:
				ability_page += 1
				if ability_page * ABILITY_SLOTS >= p.known_skills.size():
					ability_page = 0
			KEY_ESCAPE:
				hud.close_panels()
			KEY_1:
				slot = 1
			KEY_2:
				slot = 2
			KEY_3:
				slot = 3
				if _is_self_cast(_profile_for(slot)) and not hud.is_blocking():
					_cast_self.call_deferred(slot)
			KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9:
				slot = k.keycode - KEY_0
				if _profile_for(slot).is_empty():
					slot = 1
				elif _is_self_cast(_profile_for(slot)) and not hud.is_blocking():
					_cast_self.call_deferred(slot)
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
	var support := _is_support(sp)
	if _is_self_cast(sp):
		_cast_self(slot)
		return
	if target != null:
		if target.faction == "hostile" and not support:
			_act_on(target)
		elif support and target.faction in ["player", "ally"]:
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


## Self, party-wide, summon and utility abilities: cast at once on the caster.
func _cast_self(n: int) -> void:
	var p = _p()
	var sp := _profile_for(n)
	if sp.is_empty() or p.is_dead or p.busy:
		return
	if combat.active and not combat.can_act(p):
		Events.post("[color=gray]Not your turn.[/color]")
		return
	await combat.do_cast(p, p, sp["id"])
	slot = 1


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
		var st: PackedStringArray = []
		for s in a.statuses:
			st.append("%s %d" % [str(DB.statuses.get(s["id"], {}).get("name", s["id"])), int(s["rounds"])])
		Events.post("[color=#9fd8ff]%s[/color]: level %d %s (%s), HP %d/%d, AC %d, wielding %s, %s.%s" % [a.display_name, a.sheet.level, a.sheet.race_name(), a.faction, a.hp, a.max_hp, a.ac, w.get("name", "fists"), CharacterSheet.aptitude_word(a.aptitude), ("  Effects: " + ", ".join(st)) if not st.is_empty() else ""])
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
	if a.faction == "hostile" and not p.is_dead:
		var sp := _slot_profile()
		if not sp.is_empty():
			var prof: Dictionary = sp["profile"]
			var res: int = world.resonance_at(p.tile)
			var bonus := 0
			if sp["kind"] == "skill" and prof.get("kind") != "weapon":
				var ab: Dictionary = sp["ability"]
				var save: Dictionary = ab.get("save", {}) if ab.get("save") is Dictionary else {}
				if save.has("stat") or ab.get("kind") in ["control", "curse"]:
					txt += "\n%s: %s save vs DC %d" % [ab.get("name", "?"), str(save.get("stat", "wis")).to_upper(), AbilityRules.save_dc(p, ab)]
				else:
					bonus = AbilityRules.cast_bonus(p, ab)
					txt += "\n%s: hit %d%%" % [ab.get("name", "?"), roundi(Rules.hit_chance(bonus, a.ac) * 100)]
				if AbilityRules.is_magic(ab):
					txt += ", power x%.2f" % AbilityRules.multiplier(p, ab, res)
				var mc := AbilityRules.misfire_chance(p, ab, res)
				if mc > 0.0:
					txt += ", %s %d%%" % ["misfire" if not AbilityRules.is_magic(ab) else "backfire", roundi(mc * 100)]
			else:
				bonus = Rules.attack_bonus(p, prof)
				txt += "\n%s: hit %d%%" % [prof.get("label", prof.get("name", "?")), roundi(Rules.hit_chance(bonus, a.ac) * 100)]
				if prof.get("pool") == "gear":
					var base := float(prof.get("misfire", 0.02)) + float(prof.get("misfire_add", 0.0)) + Rules.mods_f(p, "misfire")
					txt += ", misfire %d%%" % roundi(Rules.misfire_chance(base, res, p.aptitude) * 100)
			var dist := Rules.tile_distance(p.tile, a.tile)
			txt += "\nDistance %d ft, reach %d ft" % [dist * 5, int(prof.get("range", 5))]
	elif a.dialogue_id != "":
		txt += "\nClick to talk"
	hud.set_hover(txt, pos)
