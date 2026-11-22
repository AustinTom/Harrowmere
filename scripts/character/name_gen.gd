class_name NameGen
extends RefCounted
## Names from the tables in data/character/races.json ("names"):
## a given name for the gender, plus a family name built from a prefix
## and a suffix. Deterministic for a given RandomNumberGenerator state.


static func make(race: String, gender: String, rng: RandomNumberGenerator) -> String:
	var n: Dictionary = DB.races.get(race, {}).get("names", {})
	if n.is_empty():
		n = DB.races.get("human", {}).get("names", {})
	var pool: Array = n.get("given_" + gender, [])
	if pool.is_empty() or rng.randf() < 0.08:
		pool = pool + n.get("given_x", [])
	if pool.is_empty():
		pool = n.get("given_m", []) + n.get("given_f", []) + n.get("given_x", [])
	var given := str(pool[rng.randi_range(0, pool.size() - 1)]) if not pool.is_empty() else "Someone"
	var pre: Array = n.get("family_prefix", [])
	var suf: Array = n.get("family_suffix", [])
	if pre.is_empty() or suf.is_empty():
		return given
	var family := str(pre[rng.randi_range(0, pre.size() - 1)]) + str(suf[rng.randi_range(0, suf.size() - 1)])
	if race == "wrought":
		return "%s, %s" % [given, family]
	return "%s %s" % [given, family]
