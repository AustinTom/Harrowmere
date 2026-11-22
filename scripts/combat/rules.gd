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


static func attack_bonus(attacker, profile: Dictionary) -> int:
	return mod(int(attacker.stats[attack_stat(profile)])) + PROFICIENCY


static func hit_chance(bonus: int, ac: int) -> float:
	var faces := clampi(21 - (ac - bonus), 1, 19)
	return faces / 20.0


static func _blank() -> Dictionary:
	return {"hit": false, "crit": false, "misfire": false, "damage": 0,
		"self_damage": 0, "heal": 0, "effects": [], "lines": []}


static func resolve_attack(attacker, target, p: Dictionary, resonance: int) -> Dictionary:
	var r := _blank()
	var an: String = attacker.display_name
	var tn: String = target.display_name
	var wn: String = str(p.get("label", p.get("name", "attack")))
	if p.get("pool", "neutral") == "gear":
		var chance := misfire_chance(float(p.get("misfire", 0.02)), resonance, int(attacker.aptitude))
		if rng.randf() < chance:
			r["misfire"] = true
			var line := "[color=#ffb347]%s's %s misfires![/color] (%d%% chance at Resonance %d)" % [an, wn, roundi(chance * 100), resonance]
			if p.has("burst_damage"):
				r["self_damage"] = maxi(1, roll_dice(str(p["burst_damage"])))
				line += " The boiler bursts for %d damage." % r["self_damage"]
			r["lines"].append(line)
			return r
	var bonus := attack_bonus(attacker, p)
	var d := d20()
	var total := d + bonus
	var ac: int = int(target.ac)
	r["crit"] = d == 20
	r["hit"] = d == 20 or (d != 1 and total >= ac)
	if not r["hit"]:
		r["lines"].append("%s attacks %s with %s: %d+%d=%d vs AC %d, miss." % [an, tn, wn, d, bonus, total, ac])
		return r
	var dmg := roll_dice(str(p.get("damage", "1d3")), r["crit"]) + mod(int(attacker.stats[attack_stat(p)]))
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
	return r


static func resolve_spell(caster, target, skill: Dictionary, resonance: int, spell_power: int) -> Dictionary:
	var r := _blank()
	var school: String = skill.get("school", "arcane")
	var mult := magic_multiplier(school, resonance, int(caster.aptitude))
	var stat_mod := mod(int(caster.stats[skill.get("stat", "int")]))
	var cn: String = caster.display_name
	var tn: String = target.display_name
	var sn: String = skill.get("name", "spell")
	if skill.get("kind") == "heal":
		var amount := maxi(1, roundi((roll_dice(str(skill["heal"])) + stat_mod + spell_power) * mult))
		r["heal"] = amount
		r["hit"] = true
		r["lines"].append("%s casts %s on %s: heals %d (x%.2f at Resonance %d)." % [cn, sn, tn, amount, mult, resonance])
		return r
	var bonus := stat_mod + PROFICIENCY
	var d := d20()
	var total := d + bonus
	var ac: int = int(target.ac)
	r["crit"] = d == 20
	r["hit"] = d == 20 or (d != 1 and total >= ac)
	if not r["hit"]:
		r["lines"].append("%s casts %s at %s: %d+%d=%d vs AC %d, miss." % [cn, sn, tn, d, bonus, total, ac])
		return r
	var dmg := maxi(1, roundi((roll_dice(str(skill["damage"]), r["crit"]) + spell_power) * mult))
	r["damage"] = dmg
	r["lines"].append("%s casts %s at %s%s: %d+%d=%d vs AC %d, [b]%d damage[/b] (x%.2f at Resonance %d)." % [cn, sn, tn, " [color=#ffd700]CRITICAL[/color]" if r["crit"] else "", d, bonus, total, ac, dmg, mult, resonance])
	return r
