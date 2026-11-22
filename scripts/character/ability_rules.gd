class_name AbilityRules
extends RefCounted
## Resolves one ability (spell, prayer, device or technique) against one
## target. Pure rules like Rules: no scene access. CombatManager picks the
## targets (area, chain, allies) and applies the results.
##
## Ability fields are documented in docs/character-system.md.


static func discipline(ab: Dictionary) -> Dictionary:
	return DB.disciplines.get(str(ab.get("discipline", "")), {})


static func is_magic(ab: Dictionary) -> bool:
	return str(ab.get("school", "")) in ["arcane", "divine"]


static func _rank_bonus(caster, ab: Dictionary) -> int:
	if caster.has_method("cast_rank_bonus"):
		return caster.cast_rank_bonus(str(ab.get("discipline", "")))
	return Rules.PROFICIENCY


## d20 bonus for an ability attack: key stat + governing skill + modifiers.
static func cast_bonus(caster, ab: Dictionary) -> int:
	var b := Rules.mod(int(caster.stats[str(ab.get("stat", "int"))])) + _rank_bonus(caster, ab)
	b += Rules.mods(caster, "attack") + Rules.mods(caster, "attack:" + str(ab.get("pool", "neutral")))
	return b


static func save_dc(caster, ab: Dictionary) -> int:
	return 8 + Rules.mod(int(caster.stats[str(ab.get("stat", "int"))])) + _rank_bonus(caster, ab)


static func power(caster, ab: Dictionary, weapon_spell_power: int) -> int:
	if not is_magic(ab):
		return 0
	return weapon_spell_power + Rules.mods(caster, "spell_power") + Rules.mods(caster, "spell_power:" + str(ab.get("school", "")))


## How strongly it works here: Resonance and aptitude for magic, 1.0 otherwise.
static func multiplier(caster, ab: Dictionary, resonance: int) -> float:
	if is_magic(ab):
		return Rules.magic_multiplier(str(ab["school"]), resonance, int(caster.aptitude))
	return 1.0


static func misfire_chance(caster, ab: Dictionary, resonance: int) -> float:
	if ab.get("device", false) or str(ab.get("pool", "")) == "gear" and ab.has("misfire"):
		var base := float(ab.get("misfire", 0.03)) + Rules.mods_f(caster, "misfire")
		return Rules.misfire_chance(base, resonance, int(caster.aptitude))
	if is_magic(ab):
		return clampf(Rules.mods_f(caster, "backfire"), 0.0, 0.9)
	return 0.0


static func resolve(caster, target, ab: Dictionary, resonance: int, weapon_spell_power := 0, primary := true) -> Dictionary:
	var r := Rules._blank()
	var cn: String = caster.display_name
	var tn: String = target.display_name
	var an := str(ab.get("name", "ability"))
	var tier := int(ab.get("tier", 1))
	if primary:
		var mc := misfire_chance(caster, ab, resonance)
		if mc > 0.0 and Rules.rng.randf() < mc:
			r["misfire"] = true
			r["self_damage"] = Rules.roll_dice("1d4") + tier
			var what := "misfires" if not is_magic(ab) else "backfires"
			r["lines"].append("[color=#ffb347]%s's %s %s![/color] (%d%% chance) %s takes %d damage." % [cn, an, what, roundi(mc * 100), cn, r["self_damage"]])
			return r
	var mult := multiplier(caster, ab, resonance)
	var sp := power(caster, ab, weapon_spell_power)
	var kind := str(ab.get("kind", "attack"))
	var stat_mod := Rules.mod(int(caster.stats[str(ab.get("stat", "int"))]))
	var dc := save_dc(caster, ab)
	var save: Dictionary = ab.get("save", {}) if ab.get("save") is Dictionary else {}
	var save_stat := str(save.get("stat", ""))
	var magic := is_magic(ab)
	var mult_txt := " (x%.2f at Resonance %d)" % [mult, resonance] if magic else ""
	r["damage_type"] = str(ab.get("damage_type", "force"))
	match kind:
		"heal":
			var amount := maxi(1, roundi((Rules.roll_dice(str(ab.get("heal", "1d6"))) + stat_mod + sp) * mult))
			r["hit"] = true
			r["heal"] = amount
			r["repair"] = bool(ab.get("construct_only", false)) or (bool(ab.get("construct_ok", false)) and Rules.has_flag(target, "heal_immune"))
			if ab.get("construct_only", false) and not Rules.has_flag(target, "heal_immune"):
				r["heal"] = 0
				r["lines"].append("%s's %s only works on machines and Wrought." % [cn, an])
				return r
			r["lines"].append("%s uses %s on %s: heals %d%s." % [cn, an, tn, amount, mult_txt])
		"cleanse":
			r["hit"] = true
			r["cleanse"] = "harm"
			r["heal"] = maxi(0, Rules.roll_dice(str(ab.get("heal", "0"))))
			r["lines"].append("%s uses %s on %s." % [cn, an, tn])
		"boon":
			r["hit"] = true
			r["lines"].append("%s uses %s on %s." % [cn, an, tn])
			Rules.roll_statuses(caster, target, ab.get("effects", []), dc, "", false, r)
		"control", "curse":
			r["hit"] = true
			var resisted := save_stat != "" and Rules.saving_throw(target, save_stat, dc, magic)
			if ab.has("damage"):
				var dmg := maxi(1, roundi((Rules.roll_dice(str(ab["damage"])) + sp) * mult))
				if resisted:
					dmg = maxi(1, dmg / 2)
				r["damage"] = dmg
			if resisted:
				r["lines"].append("%s uses %s on %s, who resists (%s save vs DC %d)%s." % [cn, an, tn, save_stat.to_upper(), dc, (", %d damage" % r["damage"]) if r["damage"] > 0 else ""])
			else:
				r["lines"].append("%s uses %s on %s%s%s." % [cn, an, tn, (": [b]%d damage[/b]" % r["damage"]) if r["damage"] > 0 else "", mult_txt if r["damage"] > 0 else ""])
				Rules.roll_statuses(caster, target, ab.get("effects", []), dc, "", magic, r)
		_:
			# attack: either an attack roll against AC, or (area) a save for half
			var crit := false
			if save_stat != "":
				var ok := Rules.saving_throw(target, save_stat, dc, magic)
				var dmg := maxi(1, roundi((Rules.roll_dice(str(ab.get("damage", "1d6"))) + sp) * mult))
				if ok and save.get("half", false):
					dmg = maxi(1, dmg / 2)
				r["hit"] = true
				r["damage"] = dmg
				r["lines"].append("%s's %s engulfs %s%s: [b]%d damage[/b]%s." % [cn, an, tn, " (saved, half)" if ok else "", dmg, mult_txt])
				if not ok:
					Rules.roll_statuses(caster, target, ab.get("effects", []), dc, "", magic, r)
			else:
				var bonus := cast_bonus(caster, ab)
				var d := Rules.attack_d20(caster)
				var total := d + bonus
				var ac: int = int(target.ac)
				crit = d >= Rules.crit_threshold(caster)
				r["crit"] = crit
				r["hit"] = crit or (d != 1 and total >= ac)
				if not r["hit"]:
					r["lines"].append("%s uses %s on %s: %d+%d=%d vs AC %d, miss." % [cn, an, tn, d, bonus, total, ac])
					return r
				var dmg := maxi(1, roundi((Rules.roll_dice(str(ab.get("damage", "1d6")), crit) + sp) * mult))
				r["damage"] = dmg
				r["lines"].append("%s uses %s on %s%s: %d+%d=%d vs AC %d, [b]%d damage[/b]%s." % [cn, an, tn, " [color=#ffd700]CRITICAL[/color]" if crit else "", d, bonus, total, ac, dmg, mult_txt])
				Rules.roll_statuses(caster, target, ab.get("effects", []), dc, "", magic, r)
			if ab.has("drain"):
				r["drain_heal"] = maxi(1, roundi(r["damage"] * float(ab["drain"])))
			r["push"] = int(ab.get("push", 0))
	return r


## Builds the attack profile for a weapon technique from the equipped weapon.
static func technique_profile(weapon: Dictionary, ab: Dictionary) -> Dictionary:
	var p := Rules.attack_profile(weapon, false)
	p["ap"] = maxi(1, int(p.get("ap", 3)) + int(ab.get("ap_delta", 0)))
	p["to_hit"] = int(ab.get("to_hit", 0))
	if ab.has("extra_damage"):
		p["extra_damage"] = str(ab["extra_damage"])
	if ab.has("effects"):
		p["ability_effects"] = ab["effects"]
	if ab.has("save"):
		p["save"] = ab["save"]
	if ab.has("push"):
		p["push"] = int(ab["push"])
	if ab.has("misfire_add"):
		p["misfire_add"] = float(ab["misfire_add"])
	p["label"] = "%s (%s)" % [str(ab.get("name", "technique")), str(weapon.get("name", "weapon"))]
	return p


## True when the equipped weapon suits the technique ("" reason) or why not.
static func technique_blocker(weapon: Dictionary, ab: Dictionary) -> String:
	var need: Array = ab.get("weapon_skill", [])
	if need.is_empty():
		return ""
	var have := DB.weapon_skill(weapon)
	if need.has(have):
		return ""
	var names: PackedStringArray = []
	for n in need:
		names.append(str(DB.char_skills.get(n, {}).get("name", n)))
	return "%s needs a %s weapon." % [str(ab.get("name", "?")), " or ".join(names)]


## One-line rules summary for tooltips and the character sheet.
static func describe(ab: Dictionary) -> String:
	var parts: PackedStringArray = []
	var kind := str(ab.get("kind", ""))
	parts.append("%s (%s, tier %d, %s)" % [ab.get("name", "?"), str(discipline(ab).get("name", "?")), int(ab.get("tier", 1)), kind])
	if kind == "passive":
		var m: PackedStringArray = []
		for mod in ab.get("modifiers", []):
			if mod.has("flag"):
				m.append(str(mod["flag"]).replace("_", " "))
			else:
				m.append("%s %+g" % [str(mod.get("target", "?")).replace(":", " "), float(mod.get("add", 0))])
		parts.append("Always on: " + ", ".join(m))
	else:
		var bits: PackedStringArray = []
		if kind == "weapon":
			bits.append("weapon AP %+d" % int(ab.get("ap_delta", 0)))
			if ab.has("to_hit"):
				bits.append("%+d to hit" % int(ab["to_hit"]))
			if ab.has("extra_damage"):
				bits.append("+%s damage" % ab["extra_damage"])
			if int(ab.get("hits", 1)) > 1:
				bits.append("%d hits" % int(ab["hits"]))
			if ab.get("cleave", false):
				bits.append("hits everyone adjacent")
			var need: Array = ab.get("weapon_skill", [])
			if not need.is_empty():
				bits.append("needs " + "/".join(need))
		else:
			bits.append("%d AP" % int(ab.get("ap", 0)))
			if int(ab.get("range", 0)) > 0:
				bits.append("%d ft" % int(ab["range"]))
		if ab.has("damage"):
			bits.append("%s %s" % [ab["damage"], ab.get("damage_type", "")])
		if ab.has("heal"):
			bits.append("heals %s" % ab["heal"])
		if int(ab.get("area", 0)) > 0:
			bits.append("%d ft radius" % int(ab["area"]))
		if int(ab.get("chain", 0)) > 0:
			bits.append("chains to %d more" % int(ab["chain"]))
		for e in ab.get("effects", []):
			if e.get("type") == "status":
				bits.append("%s %d rounds" % [str(DB.statuses.get(e["status"], {}).get("name", e["status"])).to_lower(), int(e.get("duration", 1))])
		if ab.get("save") is Dictionary:
			bits.append("%s save%s" % [str(ab["save"].get("stat", "")).to_upper(), " for half" if ab["save"].get("half", false) else ""])
		if ab.has("summon"):
			bits.append("summons %s for %d rounds" % [DB.get_actor_template(str(ab["summon"])).get("name", "?"), int(ab.get("duration", 5))])
		if ab.get("device", false):
			bits.append("device, can misfire")
		parts.append(", ".join(bits))
	parts.append(str(ab.get("desc", "")))
	return "\n".join(parts)
