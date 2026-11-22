class_name CharacterGen
extends RefCounted
## Builds character sheets from a few numbers, so generated residents,
## enemies and summons only need {archetype, level, race, heritage, seed}.
## The same seed always gives the same character.


## opts: archetype, level, race, heritage, background, gender, grade, seed.
static func generate(opts: Dictionary) -> CharacterSheet:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(opts.get("seed", 0))
	var s := CharacterSheet.new()
	s.race = str(opts.get("race", "human")) if opts.get("race") != null else ""
	s.heritage = str(opts.get("heritage", "")) if opts.get("heritage") != null else ""
	s.background = str(opts.get("background", "none"))
	s.archetype = str(opts.get("archetype", "labourer"))
	s.grade = str(opts.get("grade", "standard"))
	s.gender = str(opts.get("gender", "")) if opts.get("gender") != null else ""
	if s.gender == "":
		var g := rng.randf()
		s.gender = "m" if g < 0.48 else ("f" if g < 0.96 else "x")
	var arch: Dictionary = DB.archetypes.get(s.archetype, {})
	buy_stats(s, arch.get("stats", {}), rng)
	for sk in DB.backgrounds.get(s.background, {}).get("start_skill_ranks", {}):
		s.skill_ranks[sk] = int(DB.backgrounds[s.background]["start_skill_ranks"][sk])
	var target := clampi(int(opts.get("level", 1)), 1, s.max_level())
	s.level = 1
	s.cp = s.starting_cp()
	auto_spend(s, rng)
	for lvl in range(2, target + 1):
		s.level = lvl
		s.cp += s.cp_for_level(lvl)
		auto_spend(s, rng)
	s.xp = CharacterSheet.xp_to_reach(s.level)
	s.invalidate()
	return s


## Spends the creation point-buy following archetype stat weights.
static func buy_stats(s: CharacterSheet, weights: Dictionary, rng: RandomNumberGenerator) -> void:
	var c: Dictionary = DB.progression.get("creation", {})
	var base := int(c.get("stat_base", 8))
	var cap := int(c.get("stat_max_before_race", 17))
	var points := int(c.get("stat_points", 20))
	var st := {}
	for k in CharacterSheet.STATS:
		st[k] = base
	var guard := 0
	while points > 0 and guard < 200:
		guard += 1
		var best := ""
		var best_score := -1.0
		for k in CharacterSheet.STATS:
			var w := float(weights.get(k, 1)) + 0.25
			if st[k] >= cap:
				continue
			var trial: Dictionary = st.duplicate()
			trial[k] += 1
			var step := CharacterSheet.creation_cost(trial) - CharacterSheet.creation_cost(st)
			if step > points:
				continue
			var score := w * rng.randf_range(0.85, 1.15) / (1.0 + (st[k] - base) * 0.35) / step
			if score > best_score:
				best_score = score
				best = k
		if best == "":
			break
		var nxt: Dictionary = st.duplicate()
		nxt[best] += 1
		points -= CharacterSheet.creation_cost(nxt) - CharacterSheet.creation_cost(st)
		st = nxt
	s.base_stats = st


## Spends all unspent CP the way the archetype would: its skills, its
## disciplines (buying the governing skill first when needed), its top stat.
static func auto_spend(s: CharacterSheet, rng: RandomNumberGenerator) -> void:
	var arch: Dictionary = DB.archetypes.get(s.archetype, {})
	var skills: Array = arch.get("skills", [])
	var discs: Array = arch.get("disciplines", [])
	var weights: Dictionary = arch.get("stats", {})
	var top_stats: Array = CharacterSheet.STATS.duplicate()
	top_stats.sort_custom(func(a, b): return float(weights.get(a, 0)) > float(weights.get(b, 0)))
	var guard := 0
	while s.cp > 0 and guard < 100:
		guard += 1
		var opts: Array = [] # [kind, id, weight]
		for i in skills.size():
			var id := str(skills[i])
			if s.can_buy("skill", id)["ok"]:
				opts.append(["skill", id, 3.0 / (i + 1) / (s.skill_rank(id) + 1)])
		for j in discs.size():
			var id := str(discs[j])
			if s.can_buy("tier", id)["ok"]:
				opts.append(["tier", id, 5.0 / (j + 1) / (s.tier(id) + 1)])
			else:
				# Unblock the discipline: raise its governing skill or key stat.
				var d: Dictionary = DB.disciplines.get(id, {})
				for gs in CharacterSheet.governing_skills(d):
					if s.can_buy("skill", str(gs))["ok"]:
						opts.append(["skill", str(gs), 2.0 / (j + 1)])
						break
				var key := str(d.get("stat", "int"))
				if s.can_buy("stat", key)["ok"] and s.level >= 3:
					opts.append(["stat", key, 0.6 / (j + 1)])
		for k in 2:
			var stid := str(top_stats[k])
			if s.can_buy("stat", stid)["ok"]:
				opts.append(["stat", stid, 0.5 / (k + 1)])
		if opts.is_empty():
			break
		var total := 0.0
		for o in opts:
			total += float(o[2])
		var roll := rng.randf() * total
		var pick: Array = opts[opts.size() - 1]
		for o in opts:
			roll -= float(o[2])
			if roll <= 0.0:
				pick = o
				break
		if not s.buy(str(pick[0]), str(pick[1])):
			break


## Converts an old flat template (stats, hp, ac, aptitude, skills) into a
## sheet that reproduces it exactly, so old content keeps working.
static func from_legacy(tpl: Dictionary) -> CharacterSheet:
	var s := CharacterSheet.new()
	s.race = str(tpl.get("race", ""))
	s.heritage = str(tpl.get("heritage", "")) if tpl.get("heritage") != null else ""
	s.level = int(tpl.get("level", 1))
	s.xp = CharacterSheet.xp_to_reach(s.level)
	s.grade = str(tpl.get("grade", "standard"))
	s.legacy_proficient = true
	var st: Dictionary = tpl.get("stats", {})
	for k in CharacterSheet.STATS:
		s.base_stats[k] = int(st.get(k, 10)) - s.race_stat_mod(k)
	for aid in tpl.get("skills", []):
		s.learned.append(str(aid))
	if tpl.has("aptitude"):
		s.aptitude_override = int(tpl["aptitude"])
	if tpl.has("hp"):
		s.hp_bonus = int(tpl["hp"]) - s.max_hp()
	if tpl.has("ac"):
		s.natural_ac = int(tpl["ac"]) - s.ac()
	s.invalidate()
	return s
