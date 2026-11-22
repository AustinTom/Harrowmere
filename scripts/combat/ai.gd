class_name AI
extends RefCounted
## Simple combat brain shared by enemies and followers. It only ever calls
## the same CombatManager actions the player uses, so it obeys the same rules
## in both modes.


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


func most_hurt_ally(a, combat) -> Variant:
	var best = null
	var best_ratio := 0.5
	for o in combat.combatants:
		if o.is_dead or not same_side(a, o):
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


func attack_options(a, world) -> Array:
	var opts: Array = []
	var res: int = world.resonance_at(a.tile)
	var w: Dictionary = a.weapon_data()
	for use_alt in [false, true]:
		if use_alt and not w.has("alt"):
			continue
		var p := Rules.attack_profile(w, use_alt)
		var score := Rules.dice_average(str(p.get("damage", "1d3")))
		if p.has("bonus_damage"):
			score += Rules.dice_average(str(p["bonus_damage"])) * Rules.magic_multiplier("arcane", res, a.aptitude)
		if p.get("pool") == "gear":
			score *= 1.0 - Rules.misfire_chance(float(p.get("misfire", 0.02)), res, a.aptitude)
		opts.append({"kind": "weapon", "alt": use_alt, "cost": float(p.get("ap", 3)),
			"reach": Rules.ft_to_tiles(int(p.get("range", 5))), "score": score})
	for sid in a.known_skills:
		var sk: Dictionary = DB.get_skill(sid)
		if sk.get("kind") != "attack":
			continue
		var s: float = (Rules.dice_average(str(sk["damage"])) + a.spell_power()) * Rules.magic_multiplier(str(sk.get("school", "arcane")), res, a.aptitude)
		opts.append({"kind": "skill", "id": sid, "cost": float(sk.get("ap", 4)),
			"reach": Rules.ft_to_tiles(int(sk.get("range", 30))), "score": s})
	return opts


## Performs one action. Returns true if it did something.
func take_step(a, world, combat) -> bool:
	if a.is_dead or a.busy or a.moving or not combat.active:
		return false
	if a.known_skills.has("mend_wounds"):
		var hurt = most_hurt_ally(a, combat)
		if hurt != null:
			var sk: Dictionary = DB.get_skill("mend_wounds")
			if Rules.tile_distance(a.tile, hurt.tile) <= Rules.ft_to_tiles(int(sk["range"])) and affordable(a, combat, float(sk["ap"])):
				return await combat.do_cast(a, hurt, "mend_wounds")
	var target = nearest_enemy(a, combat)
	if target == null:
		return false
	var options := attack_options(a, world)
	var dist := Rules.tile_distance(a.tile, target.tile)
	var best = null
	var want = null
	for o in options:
		if want == null or o["score"] > want["score"]:
			want = o
		if dist <= o["reach"] and affordable(a, combat, o["cost"]):
			if best == null or o["score"] > best["score"]:
				best = o
	if best != null:
		if best["kind"] == "skill":
			return await combat.do_cast(a, target, best["id"])
		return await combat.do_attack(a, target, best["alt"])
	if want == null or dist <= want["reach"]:
		return false # in range but can't afford anything: end turn
	if combat.is_turn_based() and a.ap < 1.0:
		return false
	var path: Array = world.path_to_range(a, target.tile, want["reach"])
	if path.size() < 2:
		return false
	if combat.mode == combat.REAL_TIME:
		path = path.slice(0, mini(path.size(), 4))
	var before: Vector2i = a.tile
	await a.move_along(path, combat)
	return a.tile != before
