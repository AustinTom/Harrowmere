class_name Rules
extends RefCounted
## The rules layer. Pure functions, no scene access, so turn-based and
## real-time combat (and tests) all resolve actions identically.

const PROFICIENCY := 2
const TRIP_DC := 12

static var rng := RandomNumberGenerator.new()


## Parses "XdY+Z" into Vector3i(count, sides, bonus).
static func parse_dice(expr: String) -> Vector3i:
	var s := expr.replace(" ", "").to_lower()
	var bonus := 0
	var idx := s.find("+")
	if idx >= 0:
		bonus = int(s.substr(idx + 1))
		s = s.substr(0, idx)
	else:
		idx = s.find("-", 1)
		if idx > 0:
			bonus = -int(s.substr(idx + 1))
			s = s.substr(0, idx)
	if not s.contains("d"):
		return Vector3i(0, 0, int(s) + bonus)
	var parts := s.split("d")
	var n := 1 if parts[0] == "" else int(parts[0])
	return Vector3i(n, int(parts[1]), bonus)


static func roll_dice(expr: String, crit := false) -> int:
	var p := parse_dice(expr)
	var total := p.z
	var n := p.x * (2 if crit else 1)
	for i in n:
		total += rng.randi_range(1, p.y)
	return total


static func dice_average(expr: String) -> float:
	var p := parse_dice(expr)
	return p.x * (p.y + 1) / 2.0 + p.z


static func d20() -> int:
	return rng.randi_range(1, 20)


static func mod(score: int) -> int:
	return floori((score - 10) / 2.0)


static func ft_to_tiles(ft: int) -> int:
	return maxi(1, ft / 5)


static func tile_distance(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))


## How strongly magic works here. Arcane swings hard with Resonance,
## divine less so. Arcane-leaning aptitude (+) boosts it, Gear-leaning (-) weakens it.
static func magic_multiplier(school: String, resonance: int, aptitude: int) -> float:
	var r := resonance / 100.0
	var res_factor := lerpf(0.4, 1.6, r) if school == "arcane" else lerpf(0.7, 1.3, r)
	var apt_factor := 1.0 + aptitude / 200.0
	return clampf(res_factor * apt_factor, 0.1, 2.5)


## Chance a Gear device fails. Rises with Resonance above 40 and with the
## user's arcane aptitude; Gear-leaning users get a small reliability bonus.
static func misfire_chance(base: float, resonance: int, aptitude: int) -> float:
	var c := base + maxf(0.0, resonance - 40) * 0.006 + maxf(0.0, aptitude) * 0.002 - maxf(0.0, -aptitude) * 0.001
	return clampf(c, 0.0, 0.9)


## Merges a weapon's alt mode over its base stats.
static func attack_profile(weapon: Dictionary, use_alt: bool) -> Dictionary:
	var p := weapon.duplicate(true)
	if use_alt and weapon.has("alt"):
		p.merge(weapon["alt"], true)
		p["is_alt"] = true
	p.erase("alt")
	return p


static func attack_stat(profile: Dictionary) -> String:
	if profile.get("ranged", false) or profile.get("finesse", false):
		return "dex"
	return "str"


## Sum of a modifier on an actor. Works with anything that has mod_total()
## (Actor, CharacterSheet); plain test doubles count as 0.
static func mods(actor, target: String) -> int:
	if actor != null and actor.has_method("mod_total"):
		return roundi(actor.mod_total(target))
	return 0


static func has_flag(actor, flag: String) -> bool:
	return actor != null and actor.has_method("has_flag") and actor.has_flag(flag)


static func reach_kind(profile: Dictionary) -> String:
	return "ranged" if profile.get("ranged", false) else "melee"


## d20 bonus: stat modifier + weapon skill (rank-based proficiency) + modifiers.
static func attack_bonus(attacker, profile: Dictionary) -> int:
	var skill := DB.weapon_skill(profile)
	var b := mod(int(attacker.stats[attack_stat(profile)]))
	if attacker.has_method("weapon_skill_bonus"):
		b += attacker.weapon_skill_bonus(skill)
	else:
		b += PROFICIENCY
	b += mods(attacker, "attack") + mods(attacker, "attack:" + skill) + mods(attacker, "attack:" + reach_kind(profile))
	b += mods(attacker, "attack:" + str(profile.get("pool", "neutral")))
	return b + int(profile.get("to_hit", 0))


static func damage_bonus(attacker, profile: Dictionary) -> int:
	var skill := DB.weapon_skill(profile)
	return mods(attacker, "damage") + mods(attacker, "damage:" + skill) + mods(attacker, "damage:" + reach_kind(profile))


static func crit_threshold(attacker) -> int:
	return clampi(20 - mods(attacker, "crit_range"), 15, 20)


## Rolls a d20 for an attack; the Lucky trait rerolls a natural 1 once.
static func attack_d20(attacker) -> int:
	var d := d20()
	if d == 1 and has_flag(attacker, "reroll_natural_1"):
		d = d20()
	return d


## A target's saving throw against a DC. Returns true when it succeeds.
static func saving_throw(target, stat_id: String, dc: int, vs_magic := false) -> bool:
	var b := mod(int(target.stats.get(stat_id, 10)))
	if target.has_method("save_bonus"):
		b = target.save_bonus(stat_id, vs_magic)
	return d20() + b >= dc


## Statuses a technique or spell puts on a target that it hit.
static func roll_statuses(attacker, target, effects: Array, dc: int, save_stat: String, vs_magic: bool, r: Dictionary) -> void:
	for e in effects:
		if e.get("type") != "status":
			continue
		if rng.randf() > float(e.get("chance", 1.0)):
			continue
		var sd: Dictionary = DB.statuses.get(str(e["status"]), {})
		if save_stat != "" and saving_throw(target, save_stat, dc, vs_magic):
			r["lines"].append("%s resists being %s (%s save vs DC %d)." % [target.display_name, str(sd.get("name", e["status"])).to_lower(), save_stat.to_upper(), dc])
			continue
		r["statuses"].append({"id": str(e["status"]), "duration": int(e.get("duration", 2))})
		r["lines"].append("%s is [color=%s]%s[/color] for %d rounds." % [target.display_name, str(sd.get("color", "#ffffff")), str(sd.get("name", e["status"])).to_lower(), int(e.get("duration", 2))])


static func hit_chance(bonus: int, ac: int) -> float:
	var faces := clampi(21 - (ac - bonus), 1, 19)
	return faces / 20.0


static func _blank() -> Dictionary:
	return {"hit": false, "crit": false, "misfire": false, "damage": 0, "damage_type": "physical",
		"self_damage": 0, "heal": 0, "effects": [], "statuses": [], "push": 0, "drain_heal": 0,
		"cleanse": "", "repair": false, "lines": []}


static func resolve_attack(attacker, target, p: Dictionary, resonance: int) -> Dictionary:
	var r := _blank()
	var an: String = attacker.display_name
	var tn: String = target.display_name
	var wn: String = str(p.get("label", p.get("name", "attack")))
	if p.get("pool", "neutral") == "gear":
		var base := float(p.get("misfire", 0.02)) + float(p.get("misfire_add", 0.0)) + mods_f(attacker, "misfire")
		var chance := misfire_chance(base, resonance, int(attacker.aptitude))
		if rng.randf() < chance:
			r["misfire"] = true
			var line := "[color=#ffb347]%s's %s misfires![/color] (%d%% chance at Resonance %d)" % [an, wn, roundi(chance * 100), resonance]
			if p.has("burst_damage"):
				r["self_damage"] = maxi(1, roll_dice(str(p["burst_damage"])))
				line += " The boiler bursts for %d damage." % r["self_damage"]
			r["lines"].append(line)
			return r
	var bonus := attack_bonus(attacker, p)
	var d := attack_d20(attacker)
	var total := d + bonus
	var ac: int = int(target.ac)
	r["crit"] = d >= crit_threshold(attacker)
	r["hit"] = r["crit"] or (d != 1 and total >= ac)
	if not r["hit"]:
		r["lines"].append("%s attacks %s with %s: %d+%d=%d vs AC %d, miss." % [an, tn, wn, d, bonus, total, ac])
		return r
	var dmg := roll_dice(str(p.get("damage", "1d3")), r["crit"]) + mod(int(attacker.stats[attack_stat(p)])) + damage_bonus(attacker, p)
	if p.has("extra_damage"):
		dmg += roll_dice(str(p["extra_damage"]), r["crit"])
	var extra_txt := ""
	if p.has("bonus_damage"):
		var mult := magic_multiplier("arcane", resonance, int(attacker.aptitude))
		var extra := roundi(roll_dice(str(p["bonus_damage"]), r["crit"]) * mult)
		dmg += extra
		extra_txt = " (incl. %d %s, x%.2f from Resonance)" % [extra, p.get("bonus_type", "arcane"), mult]
	dmg = maxi(1, dmg)
	r["damage"] = dmg
	r["lines"].append("%s hits %s with %s%s: %d+%d=%d vs AC %d, [b]%d damage[/b]%s." % [an, tn, wn, " [color=#ffd700]CRITICAL[/color]" if r["crit"] else "", d, bonus, total, ac, dmg, extra_txt])
	var special: Array = p.get("special", [])
	if special.has("trip"):
		var save := d20() + mod(int(target.stats["dex"]))
		if save < TRIP_DC:
			r["effects"].append({"name": "tripped", "ap_loss": 2})
			r["lines"].append("%s is tripped (save %d vs DC %d) and loses 2 AP." % [tn, save, TRIP_DC])
	if special.has("slow_on_crit") and r["crit"]:
		r["effects"].append({"name": "slowed", "ap_loss": 3})
		r["lines"].append("Frost spreads through %s. Slowed, loses 3 AP." % tn)
	if p.has("ability_effects"):
		var save: Dictionary = p.get("save", {}) if p.get("save") is Dictionary else {}
		var dc := 8 + bonus - int(p.get("to_hit", 0))
		roll_statuses(attacker, target, p["ability_effects"], dc, str(save.get("stat", "")), false, r)
	r["push"] = int(p.get("push", 0))
	return r


static func mods_f(actor, target: String) -> float:
	if actor != null and actor.has_method("mod_total"):
		return float(actor.mod_total(target))
	return 0.0


## Old entry point for spells, kept for compatibility. All abilities now
## resolve through AbilityRules.resolve().
static func resolve_spell(caster, target, skill: Dictionary, resonance: int, spell_power: int) -> Dictionary:
	return AbilityRules.resolve(caster, target, skill, resonance, spell_power)
