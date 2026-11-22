class_name CharacterSheet
extends RefCounted
## A character's build: race, background, stats, skill ranks, discipline
## tiers, level, XP and unspent character points (CP). Pure data and maths,
## no scene access, so the same sheet drives the player, followers, 25k
## generated residents and the tests. Everything it knows about races,
## skills and abilities comes from data/character/*.json through DB.
##
## Saved form: to_dict() / from_dict(). Schema: docs/character-system.md.

const STATS := ["str", "dex", "con", "int", "wis", "cha"]
const POOLS := ["arcane", "gear", "neutral"]

var race := "human"
var heritage := ""
var background := "none"
var archetype := ""
var gender := "x"
var level := 1
var xp := 0
var cp := 0 ## unspent character points
var base_stats := {"str": 8, "dex": 8, "con": 8, "int": 8, "wis": 8, "cha": 8}
var skill_ranks := {} ## skill id -> 1..5
var tiers := {} ## discipline id -> 1..5
var learned: Array = [] ## abilities learned outside tiers (trainers, scrolls, books)
var schematics: Array = [] ## schematic ids, owned by the crafting system
var schematic_picks_used := {} ## discipline id -> picks spent
var external_spend := {"arcane": 0, "gear": 0, "neutral": 0} ## CP spent through spend_points()
var grade := "standard" ## minion, standard, elite, boss, hero (progression.json "grades")
var natural_ac := 0
var hp_bonus := 0
var aptitude_override = null ## int, or null to derive aptitude from spending
var legacy_proficient := false ## old flat templates: proficient with every weapon

## Not saved. Set by the owner (Actor.refresh) from statuses and equipment.
var extra_modifiers: Array = []

var _static_mods_cache = null


# ---------------------------------------------------------------- save / load

static func from_dict(d: Dictionary) -> CharacterSheet:
	var s := CharacterSheet.new()
	s.race = str(d.get("race", "human"))
	s.heritage = str(d.get("heritage", "")) if d.get("heritage") != null else ""
	s.background = str(d.get("background", "none"))
	s.archetype = str(d.get("archetype", ""))
	s.gender = str(d.get("gender", "x"))
	s.level = int(d.get("level", 1))
	s.xp = int(d.get("xp", xp_to_reach(s.level)))
	s.cp = int(d.get("cp", 0))
	var bs: Dictionary = d.get("base_stats", {})
	for k in STATS:
		s.base_stats[k] = int(bs.get(k, 8))
	for k in d.get("skill_ranks", {}):
		s.skill_ranks[k] = int(d["skill_ranks"][k])
	for k in d.get("tiers", {}):
		s.tiers[k] = int(d["tiers"][k])
	s.learned = d.get("learned", []).duplicate()
	s.schematics = d.get("schematics", []).duplicate()
	for k in d.get("schematic_picks_used", {}):
		s.schematic_picks_used[k] = int(d["schematic_picks_used"][k])
	for k in d.get("external_spend", {}):
		s.external_spend[k] = int(d["external_spend"][k])
	s.grade = str(d.get("grade", "standard"))
	s.natural_ac = int(d.get("natural_ac", 0))
	s.hp_bonus = int(d.get("hp_bonus", 0))
	if d.get("aptitude_override") != null:
		s.aptitude_override = int(d["aptitude_override"])
	s.legacy_proficient = bool(d.get("legacy_proficient", false))
	return s


func to_dict() -> Dictionary:
	var d := {
		"race": race, "heritage": heritage if heritage != "" else null, "background": background,
		"archetype": archetype, "gender": gender, "level": level, "xp": xp, "cp": cp,
		"base_stats": base_stats.duplicate(), "skill_ranks": skill_ranks.duplicate(),
		"tiers": tiers.duplicate(), "learned": learned.duplicate(), "schematics": schematics.duplicate(),
		"schematic_picks_used": schematic_picks_used.duplicate(), "external_spend": external_spend.duplicate(),
		"grade": grade,
	}
	if natural_ac != 0:
		d["natural_ac"] = natural_ac
	if hp_bonus != 0:
		d["hp_bonus"] = hp_bonus
	if aptitude_override != null:
		d["aptitude_override"] = aptitude_override
	if legacy_proficient:
		d["legacy_proficient"] = true
	return d


func invalidate() -> void:
	_static_mods_cache = null


# ---------------------------------------------------------------- data lookups

static func prog() -> Dictionary:
	return DB.progression


func race_data() -> Dictionary:
	return DB.races.get(race, {})


func heritage_data() -> Dictionary:
	var r := race_data()
	var h := heritage
	if h == "":
		h = str(r.get("default_heritage", ""))
	return r.get("heritages", {}).get(h, {})


func race_name() -> String:
	var h := heritage_data()
	var r := race_data()
	if not h.is_empty():
		return "%s %s" % [h.get("name", ""), r.get("name", race)]
	return str(r.get("name", race.capitalize() if race != "" else "Creature"))


func trait_ids() -> Array:
	var out: Array = []
	out.append_array(race_data().get("traits", []))
	out.append_array(heritage_data().get("traits", []))
	out.append_array(DB.backgrounds.get(background, {}).get("traits", []))
	return out


# ---------------------------------------------------------------- modifiers

## Modifiers from traits and passive abilities (cached until the build changes).
func static_modifiers() -> Array:
	if _static_mods_cache != null:
		return _static_mods_cache
	var out: Array = []
	for t in trait_ids():
		out.append_array(DB.traits.get(t, {}).get("modifiers", []))
	for aid in known_abilities(true):
		var a: Dictionary = DB.get_ability(aid)
		if a.get("kind") == "passive":
			out.append_array(a.get("modifiers", []))
	_static_mods_cache = out
	return out


func all_modifiers() -> Array:
	return static_modifiers() + extra_modifiers


## Sum of "add" for one modifier target, e.g. "ac", "skill:stealth", "resist:fire".
func mod_total(target: String) -> float:
	var t := 0.0
	for m in all_modifiers():
		if str(m.get("target", "")) == target:
			t += float(m.get("add", 0))
	return t


func mod_int(target: String) -> int:
	return roundi(mod_total(target))


func has_flag(flag: String) -> bool:
	for m in all_modifiers():
		if str(m.get("flag", "")) == flag:
			return true
	return false


# ---------------------------------------------------------------- stats

static func ability_mod(score: int) -> int:
	return floori((score - 10) / 2.0)


func race_stat_mod(s: String) -> int:
	return int(race_data().get("stat_mods", {}).get(s, 0)) + int(heritage_data().get("stat_mods", {}).get(s, 0))


## Base stat plus race: what the player bought, before temporary effects.
func natural_stat(s: String) -> int:
	return int(base_stats.get(s, 8)) + race_stat_mod(s)


func stat(s: String) -> int:
	return maxi(1, natural_stat(s) + mod_int("stat:" + s))


func stats_dict() -> Dictionary:
	var d := {}
	for s in STATS:
		d[s] = stat(s)
	return d


func smod(s: String) -> int:
	return ability_mod(stat(s))


# ---------------------------------------------------------------- skills

func proficiency() -> int:
	var p: Dictionary = prog().get("proficiency", {})
	return int(p.get("base", 2)) + (level - 1) / int(p.get("every_levels", 8))


func skill_rank(id: String) -> int:
	return int(skill_ranks.get(id, 0))


## Bonus a rank gives on top of the stat modifier: 0 untrained, else proficiency + rank - 1.
func rank_bonus(r: int) -> int:
	return 0 if r <= 0 else proficiency() + r - 1


static func governing_skills(disc: Dictionary) -> Array:
	var s = disc.get("skill", [])
	return s if s is Array else [s]


func best_rank(skills: Array) -> int:
	var best := 0
	for s in skills:
		best = maxi(best, skill_rank(str(s)))
	return best


## Total check bonus: stat modifier + rank bonus + skill modifiers. For a
## discipline id, the best governing skill's bonus plus the tier owned.
func skill_bonus(id: String) -> int:
	if DB.char_skills.has(id):
		var sk: Dictionary = DB.char_skills[id]
		var m := smod(str(sk.get("stat", "int")))
		if sk.has("alt_stat"):
			m = maxi(m, smod(str(sk["alt_stat"])))
		return m + rank_bonus(skill_rank(id)) + mod_int("skill:" + id)
	if DB.disciplines.has(id):
		var best := -99
		for s in governing_skills(DB.disciplines[id]):
			best = maxi(best, skill_bonus(str(s)))
		return best + tier(id)
	return 0


## Attack bonus with a weapon governed by skill_id (no stat modifier).
func weapon_skill_bonus(skill_id: String) -> int:
	var r := skill_rank(skill_id)
	if r == 0 and legacy_proficient:
		r = 1
	return rank_bonus(r)


## Casting bonus for a discipline (no stat modifier): best governing skill rank.
func cast_rank_bonus(disc_id: String) -> int:
	var disc: Dictionary = DB.disciplines.get(disc_id, {})
	var r := best_rank(governing_skills(disc))
	if r == 0 and (legacy_proficient or tier(disc_id) > 0):
		r = 1
	return rank_bonus(r)


# ---------------------------------------------------------------- derived

func grade_data() -> Dictionary:
	return prog().get("grades", {}).get(grade, {"hp_mult": 1.0, "xp_mult": 1.0})


func max_hp() -> int:
	var r := race_data()
	var con := stat("con")
	var per := maxi(1, int(r.get("hp_per_level", 5)) + ability_mod(con))
	var hp := float(int(r.get("hp_base", 8)) + con + (level - 1) * per)
	hp *= float(grade_data().get("hp_mult", 1.0))
	return maxi(1, roundi(hp) + hp_bonus + mod_int("hp_max"))


func ac() -> int:
	return 10 + smod("dex") + skill_rank("dodge") / 2 + natural_ac + mod_int("ac")


func ap_max() -> int:
	return maxi(1, int(prog().get("ap", {}).get("base", 6)) + mod_int("ap_max"))


func initiative_bonus() -> int:
	return smod("dex") + mod_int("initiative")


func save_bonus(stat_id: String, vs_magic := false) -> int:
	var b := smod(stat_id) + mod_int("save:" + stat_id) + mod_int("save:all")
	if vs_magic:
		b += mod_int("save:magic")
	return b


## Percent of damage of this type ignored (negative = vulnerable).
func resist(damage_type: String) -> float:
	return clampf(mod_total("resist:" + damage_type) + mod_total("resist:all"), -100.0, 100.0)


func crit_threshold() -> int:
	return clampi(20 - mod_int("crit_range"), 15, 20)


# ---------------------------------------------------------------- aptitude

## Weighted CP spent per pool: skill ranks x1, discipline tiers x2, plus spend_points().
func pool_points() -> Dictionary:
	var a: Dictionary = prog().get("aptitude", {})
	var rw := float(a.get("skill_rank_weight", 1))
	var tw := float(a.get("tier_weight", 2))
	var p := {"arcane": 0.0, "gear": 0.0, "neutral": 0.0}
	for id in skill_ranks:
		var pool := str(DB.char_skills.get(id, {}).get("pool", "neutral"))
		p[pool] += rw * int(skill_ranks[id])
	for id in tiers:
		var pool := str(DB.disciplines.get(id, {}).get("pool", "neutral"))
		p[pool] += tw * int(tiers[id])
	for k in external_spend:
		if p.has(k):
			p[k] += float(external_spend[k])
	return p


## -100 (Gear) .. +100 (Arcane). Race base + lean from spending + modifiers.
func aptitude() -> int:
	if int(race_data().get("aptitude_base", 0)) <= -100:
		return -100 # Wrought: pure Gear, always
	if aptitude_override != null:
		return clampi(int(aptitude_override) + mod_int("aptitude"), -100, 100)
	var a: Dictionary = prog().get("aptitude", {})
	var p := pool_points()
	var n := float(a.get("neutral_weight", 1)) * p["neutral"]
	var lean := 100.0 * (p["arcane"] - p["gear"]) / (p["arcane"] + p["gear"] + n + float(a.get("damping", 5)))
	var base := int(race_data().get("aptitude_base", 0)) + int(heritage_data().get("aptitude_base", 0))
	return clampi(base + roundi(lean) + mod_int("aptitude"), -100, 100)


static func aptitude_word(v: int) -> String:
	if v >= 60:
		return "Arcane %+d" % v
	if v >= 15:
		return "leans Arcane %+d" % v
	if v <= -60:
		return "Gear %d" % -v
	if v <= -15:
		return "leans Gear %d" % -v
	return "balanced %+d" % v


# ---------------------------------------------------------------- abilities

func tier(disc_id: String) -> int:
	return int(tiers.get(disc_id, 0))


## Abilities granted by owned tiers plus learned ones, in discipline/tier order.
func known_abilities(include_passive := true) -> Array:
	var out: Array = []
	for disc_id in tiers:
		var t := int(tiers[disc_id])
		for aid in DB.abilities_by_discipline.get(disc_id, []):
			var a: Dictionary = DB.get_ability(aid)
			if int(a.get("tier", 1)) <= t and (include_passive or a.get("kind") != "passive"):
				out.append(aid)
	for aid in learned:
		if not out.has(aid) and DB.abilities.has(aid):
			if include_passive or DB.get_ability(aid).get("kind") != "passive":
				out.append(aid)
	return out


func active_abilities() -> Array:
	return known_abilities(false)


func has_ability(id: String) -> bool:
	return known_abilities(true).has(id)


# ---------------------------------------------------------------- XP and levels

static func xp_to_reach(lvl: int) -> int:
	var t: Array = DB.progression.get("xp_to_reach", [])
	if lvl < t.size():
		return int(t[lvl])
	return 250 * (lvl - 1) * lvl


func max_level() -> int:
	return int(prog().get("max_level", 50))


func xp_to_next() -> int:
	if level >= max_level():
		return 0
	return maxi(0, xp_to_reach(level + 1) - xp)


## XP this character is worth when defeated.
func xp_value() -> int:
	return roundi(50.0 * level * (1.0 + level / 10.0) * float(grade_data().get("xp_mult", 1.0)))


func cp_for_level(new_level: int) -> int:
	var c: Dictionary = prog().get("character_points", {})
	var n := int(c.get("per_level", 1))
	if new_level % int(c.get("bonus_every_levels", 5)) == 0:
		n += int(c.get("bonus", 1))
	if new_level % 10 == 0:
		n += mod_int("cp_per_10_levels")
	return n


## Adds XP. Returns the number of levels gained (CP are added to `cp`).
func add_xp(amount: int) -> int:
	xp += maxi(0, amount)
	var gained := 0
	while level < max_level() and xp >= xp_to_reach(level + 1):
		level += 1
		cp += cp_for_level(level)
		gained += 1
	if gained > 0:
		invalidate()
	return gained


func starting_cp() -> int:
	return int(prog().get("character_points", {}).get("start", 5)) + mod_int("cp_start")


# ---------------------------------------------------------------- buying

static func _tier_cost(table: Array, value: int, key: String) -> int:
	for row in table:
		var limit := int(row[key])
		var fits := value < limit if key == "below" else value <= limit
		if fits:
			return int(row["cost"])
	return -1


func stat_raise_cost(s: String) -> int:
	var t: Dictionary = prog().get("stat_raise", {})
	var v := int(base_stats.get(s, 8)) + race_stat_mod(s)
	if v >= int(t.get("cap", 20)):
		return -1
	return _tier_cost(t.get("cost", []), v, "below")


## {ok: bool, cost: int, reason: String}. kind is "stat", "skill" or "tier".
func can_buy(kind: String, id: String) -> Dictionary:
	match kind:
		"stat":
			if not STATS.has(id):
				return _no("Unknown stat.")
			var c := stat_raise_cost(id)
			if c < 0:
				return _no("%s is at the natural cap." % id.to_upper())
			return _cost_ok(c)
		"skill":
			var sk: Dictionary = DB.char_skills.get(id, {})
			if sk.is_empty():
				return _no("Unknown skill.")
			var sr: Dictionary = prog().get("skill_ranks", {})
			var nxt := skill_rank(id) + 1
			if nxt > int(sr.get("max", 5)):
				return _no("Already a grandmaster.")
			if sk.get("pool") == "arcane" and has_flag("no_magic"):
				return _no("Magic is closed to you.")
			var lv := int(sr.get("level_req", [])[nxt])
			if level < lv:
				return _no("Needs level %d." % lv)
			var st := int(sr.get("stat_req", [])[nxt])
			var stat_id := str(sk.get("stat", "int"))
			var have := stat(stat_id)
			if sk.has("alt_stat"):
				have = maxi(have, stat(str(sk["alt_stat"])))
			if have < st:
				return _no("Needs %s %d." % [stat_id.to_upper(), st])
			return _cost_ok(int(sr.get("cost", 1)))
		"tier":
			var d: Dictionary = DB.disciplines.get(id, {})
			if d.is_empty():
				return _no("Unknown discipline.")
			var tr: Dictionary = prog().get("tiers", {})
			var nxt := tier(id) + 1
			if nxt > int(tr.get("max", 5)):
				return _no("Every tier is learned.")
			var pool := str(d.get("pool", "neutral"))
			if pool == "arcane" and has_flag("no_magic"):
				return _no("Magic is closed to you.")
			var lv := int(tr.get("level_req", [])[nxt])
			if level < lv:
				return _no("Needs level %d." % lv)
			var st := int(tr.get("stat_req", [])[nxt])
			var stat_id := str(d.get("stat", "int"))
			if stat(stat_id) < st:
				return _no("Needs %s %d." % [stat_id.to_upper(), st])
			var sk_req := int(tr.get("skill_rank_req", [])[nxt])
			var skills := governing_skills(d)
			if best_rank(skills) < sk_req:
				var names: PackedStringArray = []
				for s in skills:
					names.append(str(DB.char_skills.get(s, {}).get("name", s)))
				return _no("Needs %s rank %d." % [" or ".join(names), sk_req])
			var apt_req: Dictionary = tr.get("aptitude_req", {})
			if apt_req.has(pool):
				var need := int(apt_req[pool][nxt])
				var apt := aptitude()
				if pool == "arcane" and need > 0 and apt < need:
					return _no("Needs Arcane aptitude %d (you have %+d)." % [need, apt])
				if pool == "gear" and need < 0 and apt > need:
					return _no("Needs Gear aptitude %d (you have %+d)." % [-need, apt])
			return _cost_ok(int(tr.get("cost", 1)))
	return _no("Unknown purchase.")


func _no(reason: String) -> Dictionary:
	return {"ok": false, "cost": 0, "reason": reason}


func _cost_ok(c: int) -> Dictionary:
	if cp < c:
		return {"ok": false, "cost": c, "reason": "Needs %d CP." % c}
	return {"ok": true, "cost": c, "reason": ""}


func buy(kind: String, id: String) -> bool:
	var chk := can_buy(kind, id)
	if not chk["ok"]:
		return false
	cp -= int(chk["cost"])
	match kind:
		"stat":
			base_stats[id] = int(base_stats[id]) + 1
		"skill":
			skill_ranks[id] = skill_rank(id) + 1
		"tier":
			tiers[id] = tier(id) + 1
	invalidate()
	return true


## Generic spending for other systems (kind is a free label, pool drives aptitude).
func spend_points(_kind: String, amount: int, pool := "neutral") -> bool:
	if amount < 0 or cp < amount:
		return false
	cp -= amount
	if not external_spend.has(pool):
		pool = "neutral"
	external_spend[pool] = int(external_spend[pool]) + amount
	return true


func schematic_picks_left(disc_id: String) -> int:
	var d: Dictionary = DB.disciplines.get(disc_id, {})
	var per := int(d.get("schematic_picks", 0))
	if per <= 0:
		return 0
	return maxi(0, tier(disc_id) * (per + mod_int("schematic_picks")) - int(schematic_picks_used.get(disc_id, 0)))


## Records a schematic picked from a trade tier. Returns false with no picks left.
func pick_schematic(disc_id: String, schematic_id: String) -> bool:
	if schematic_picks_left(disc_id) <= 0 or schematics.has(schematic_id):
		return false
	schematics.append(schematic_id)
	schematic_picks_used[disc_id] = int(schematic_picks_used.get(disc_id, 0)) + 1
	return true


# ---------------------------------------------------------------- creation

## Point-buy cost of a stat block at creation (before race modifiers).
static func creation_cost(stats: Dictionary) -> int:
	var c: Dictionary = DB.progression.get("creation", {})
	var base := int(c.get("stat_base", 8))
	var total := 0
	for s in STATS:
		var v := int(stats.get(s, base))
		for x in range(base + 1, v + 1):
			var step := _tier_cost(c.get("cost", []), x, "up_to")
			total += step if step > 0 else 99
	return total
