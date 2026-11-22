class_name AI
extends RefCounted
## Simple combat brain shared by enemies and followers. It only ever calls
## the same CombatManager actions the player uses, so it obeys the same rules
## in both modes. It scores every action it knows (weapon, alt mode, spells,
## techniques, controls, boons, heals, summons) and takes the best one that is
## in reach and affordable, walking closer otherwise.


func same_side(a, b) -> bool:
	return (a.faction == "hostile") == (b.faction == "hostile")


func nearest_enemy(a, combat) -> Variant:
	var best = null
	var best_d := 99999
	for o in combat.combatants:
		if o.is_dead or same_side(a, o):
			continue
		var d := Rules.tile_distance(a.tile, o.tile)
		if d < best_d:
			best = o
			best_d = d
	return best


func most_hurt_ally(a, combat, below := 0.5) -> Variant:
	var best = null
	var best_ratio := below
	for o in combat.combatants:
		if o.is_dead or not same_side(a, o) or o.summoned:
			continue
		var ratio: float = float(o.hp) / o.max_hp
		if ratio < best_ratio:
			best = o
			best_ratio = ratio
	return best


func affordable(a, _combat, cost: float) -> bool:
	# Same check in both modes. In real time the brain simply re-thinks a
	# moment later once AP has refilled, so it never commits to a stale plan.
	return a.ap >= cost - 0.001


func _magic_ok(a, ab: Dictionary) -> bool:
	return not (AbilityRules.is_magic(ab) and a.has_flag("silenced"))


## Offensive options against `target`: {kind, id/alt, cost, reach, score}.
func attack_options(a, world, target = null) -> Array:
	var opts: Array = []
	var res: int = world.resonance_at(a.tile)
	var w: Dictionary = a.weapon_data()
	var weapon_avg := 0.0
	for use_alt in [false, true]:
		if use_alt and not w.has("alt"):
			continue
		var p := Rules.attack_profile(w, use_alt)
		var score := Rules.dice_average(str(p.get("damage", "1d3")))
		if p.has("bonus_damage"):
			score += Rules.dice_average(str(p["bonus_damage"])) * Rules.magic_multiplier("arcane", res, a.aptitude)
		if p.get("pool") == "gear":
			score *= 1.0 - Rules.misfire_chance(float(p.get("misfire", 0.02)), res, a.aptitude)
		if not use_alt:
			weapon_avg = score
		opts.append({"kind": "weapon", "alt": use_alt, "cost": float(p.get("ap", 3)),
			"reach": Rules.ft_to_tiles(int(p.get("range", 5))), "score": score})
	for aid in a.known_skills:
		var ab: Dictionary = DB.get_ability(aid)
		if not _magic_ok(a, ab):
			continue
		var kind := str(ab.get("kind", ""))
		var mult := AbilityRules.multiplier(a, ab, res) * (1.0 - AbilityRules.misfire_chance(a, ab, res))
		var s := 0.0
		var cost := float(ab.get("ap", 4))
		var reach := Rules.ft_to_tiles(int(ab.get("range", 30)))
		match kind:
			"attack":
				s = (Rules.dice_average(str(ab.get("damage", "1d6"))) + AbilityRules.power(a, ab, a.spell_power())) * mult
				if int(ab.get("area", 0)) > 0 or int(ab.get("chain", 0)) > 0:
					s *= 1.3
				s += 1.5 * ab.get("effects", []).size()
			"control", "curse":
				var st := str(ab.get("effects", [{}])[0].get("status", ""))
				if target != null and target.has_status(st):
					continue
				s = 6.0 if kind == "control" else 4.0
				if ab.has("damage"):
					s += Rules.dice_average(str(ab["damage"])) * mult
			"weapon":
				if AbilityRules.technique_blocker(w, ab) != "":
					continue
				var tp := AbilityRules.technique_profile(w, ab)
				s = (weapon_avg + Rules.dice_average(str(ab.get("extra_damage", "0")))) * int(ab.get("hits", 1))
				s += 1.5 * ab.get("effects", []).size() + 0.4 * int(ab.get("to_hit", 0))
				cost = float(tp["ap"])
				reach = Rules.ft_to_tiles(int(tp.get("range", 5)))
			_:
				continue
		opts.append({"kind": "skill", "id": aid, "cost": cost, "reach": reach, "score": s})
	return opts


## Support actions worth taking right now: heals, summons, buffs.
func support_action(a, world, combat) -> Variant:
	var best = null
	var best_score := 0.0
	for aid in a.known_skills:
		var ab: Dictionary = DB.get_ability(aid)
		if not _magic_ok(a, ab):
			continue
		var cost := float(ab.get("ap", 4))
		if not affordable(a, combat, cost):
			continue
		var kind := str(ab.get("kind", ""))
		var reach := Rules.ft_to_tiles(int(ab.get("range", 30)))
		var tgt = null
		var score := 0.0
		match kind:
			"heal":
				if ab.get("construct_only", false):
					continue
				tgt = most_hurt_ally(a, combat)
				if tgt != null:
					score = 10.0 + Rules.dice_average(str(ab.get("heal", "1d6")))
			"summon":
				var have := false
				for o in combat.combatants:
					if o.summoned and not o.is_dead and same_side(a, o):
						have = true
				if not have:
					tgt = a
					score = 9.0
			"boon":
				var st := str(ab.get("effects", [{}])[0].get("status", ""))
				var who = a
				if str(ab.get("target")) == "ally":
					who = most_hurt_ally(a, combat, 1.01)
					if who == null:
						who = a
				if who.has_status(st) or Rules.rng.randf() > 0.35:
					continue
				tgt = who
				score = 5.0
			_:
				continue
		if tgt == null:
			continue
		if tgt != a and Rules.tile_distance(a.tile, tgt.tile) > reach:
			continue
		if score > best_score:
			best_score = score
			best = {"id": aid, "target": tgt}
	return best


## Performs one action. Returns true if it did something.
func take_step(a, world, combat) -> bool:
	if a.is_dead or a.busy or a.moving or not combat.active:
		return false
	if a.has_flag("pacified"):
		return false
	var sup = support_action(a, world, combat)
	if sup != null:
		if await combat.do_cast(a, sup["target"], sup["id"]):
			return true
	var target = nearest_enemy(a, combat)
	if target == null:
		return false
	var options := attack_options(a, world, target)
	var dist := Rules.tile_distance(a.tile, target.tile)
	var best = null
	var want = null
	for o in options:
		if o["kind"] == "weapon" and (want == null or o["score"] > want["score"]):
			want = o
		if dist <= o["reach"] and affordable(a, combat, o["cost"]):
			# Value per AP, so a pricier technique has to earn its cost.
			if best == null or o["score"] / maxf(1.0, o["cost"]) > best["score"] / maxf(1.0, best["cost"]):
				best = o
	for o in options:
		if want == null or (o["score"] > want["score"] and o["reach"] >= want["reach"]):
			want = o
	if best != null:
		if best["kind"] == "skill":
			return await combat.do_cast(a, target, best["id"])
		return await combat.do_attack(a, target, best["alt"])
	if want == null or dist <= want["reach"]:
		return false # in range but can't afford anything: end turn
	if combat.is_turn_based() and a.ap < 1.0:
		return false
	if a.has_flag("rooted"):
		return false
	var path: Array = world.path_to_range(a, target.tile, want["reach"])
	if path.size() < 2:
		return false
	if combat.mode == combat.REAL_TIME:
		path = path.slice(0, mini(path.size(), 4))
	var before: Vector2i = a.tile
	await a.move_along(path, combat)
	return a.tile != before
