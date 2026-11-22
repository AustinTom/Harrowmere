class_name Identification
extends RefCounted
## Four ways to learn what a magic item does (from the world design):
##   1. Cast an identify spell or say a divination prayer. Arcane or divine
##      check; follows Resonance. Reveals everything, curses included.
##   2. Use an Assayer's Lens. Gear check; works best where Resonance is low.
##      Reads the properties but can miss a curse unless you beat the DC by 5.
##      The lens is used up either way.
##   3. Pay an appraiser. A town job; price and honesty vary per person
##      (actor template "appraiser" block). A dishonest one may say "clean".
##   4. Equip it and find out. A curse wakes at once. The powers reveal
##      themselves after a few hits in a fight (item "ident_uses", default 5).
##
## Every function returns {ok, lines, ...} and changes the entry in place.

const DEFAULT_USES := 5
const LENS_CURSE_MARGIN := 5


static func dc(e: Dictionary) -> int:
	var it := ItemStats.base(e)
	if it.has("ident_dc"):
		return int(it["ident_dc"])
	return 10 + 2 * ItemStats.enchant_ids(e).size() + (3 if ItemStats.is_cursed(e) else 0)


static func _reveal(e: Dictionary, with_curse: bool) -> void:
	e["identified"] = true
	if with_curse and ItemStats.is_cursed(e):
		e["curse_known"] = true
	Events.inventory_changed.emit()


static func _reveal_line(who: String, e: Dictionary, how: String) -> String:
	var it := ItemStats.base(e)
	var line := "[color=#9fd8ff]%s %s. It is a [b]%s[/b].[/color] %s" % [who, how, ItemStats.display_name(e), it.get("desc", "")]
	var names: Array = ItemStats.resolve(e).get("enchant_names", [])
	if not names.is_empty():
		line += " Enchantments: %s." % ", ".join(names)
	return line


static func spell_bonus(caster, skill: Dictionary, resonance: int) -> int:
	var school := str(skill.get("school", "arcane"))
	return Rules.mod(int(caster.stats.get(str(skill.get("stat", "int")), 10))) + Rules.PROFICIENCY \
		+ Crafting.resonance_mod(school, resonance) + Crafting.aptitude_mod(school, int(caster.aptitude))


## 1. Identify spell / divination prayer (skills.json kind "identify").
## A failed attempt can't be retried by the same caster until the next day.
static func by_spell(caster, e: Dictionary, skill_id: String, resonance: int) -> Dictionary:
	var skill := DB.get_skill(skill_id)
	if skill.get("kind") != "identify" or not caster.known_skills.has(skill_id):
		return {"ok": false, "lines": ["%s doesn't know that." % caster.display_name]}
	if ItemStats.is_identified(e) and (not ItemStats.is_cursed(e) or ItemStats.curse_known(e)):
		return {"ok": false, "lines": ["Nothing more to learn about it."]}
	var tries: Dictionary = e.get("ident_tries", {})
	if int(tries.get(caster.display_name, -1)) == GameState.day():
		return {"ok": false, "lines": ["%s already tried today. The item's pattern won't come clear until tomorrow." % caster.display_name]}
	var b := spell_bonus(caster, skill, resonance)
	var d := Rules.d20()
	var target := dc(e)
	var ok := d == 20 or (d != 1 and d + b >= target)
	GameState.minutes += 10.0
	var verb := "prays over it" if skill.get("school") == "divine" else "casts %s" % skill.get("name", "Identify")
	if not ok:
		tries[caster.display_name] = GameState.day()
		e["ident_tries"] = tries
		return {"ok": false, "lines": ["%s %s: %d%+d=%d vs DC %d. The pattern slips away. (Resonance %d)" % [caster.display_name, verb, d, b, d + b, target, resonance]]}
	_reveal(e, true)
	var lines := [_reveal_line(caster.display_name, e, verb)]
	if ItemStats.is_cursed(e):
		lines.append("[color=#ff8a65]%s[/color]" % ItemStats._curse_line(e))
	return {"ok": true, "lines": lines}


static func lens_bonus(user, lens_item: Dictionary, resonance: int) -> int:
	return SkillHooks.skill_bonus(user, "mechanics") + int(lens_item.get("identify_bonus", 0)) \
		+ Crafting.resonance_mod("gear", resonance) + Crafting.aptitude_mod("gear", int(user.aptitude))


## 2. Assayer's Lens (any item with "identify": true). Consumes the lens.
static func by_lens(user, e: Dictionary, lens_entry: Dictionary, lens_pack: Inventory, resonance: int) -> Dictionary:
	if ItemStats.is_identified(e):
		return {"ok": false, "lines": ["It's already identified."]}
	var lens := DB.get_item(str(lens_entry["id"]))
	var b := lens_bonus(user, lens, resonance)
	var d := Rules.d20()
	var target := dc(e)
	var margin := d + b - target
	lens_pack.remove_one(lens_entry)
	GameState.minutes += 10.0
	var head := "%s studies it through the %s: %d%+d=%d vs DC %d" % [user.display_name, lens.get("name", "lens"), d, b, d + b, target]
	if d == 1 or (d != 20 and margin < 0):
		return {"ok": false, "lines": [head + ". The readings make no sense, and the lens is spent."]}
	var saw_curse := margin >= LENS_CURSE_MARGIN or d == 20
	_reveal(e, saw_curse)
	var lines := [head + ".", _reveal_line(user.display_name, e, "reads the lens")]
	if ItemStats.is_cursed(e) and saw_curse:
		lines.append("[color=#ff8a65]The needle kicks: %s[/color]" % ItemStats._curse_line(e))
	elif not saw_curse:
		lines.append("[color=gray]The lens shows no curse, but lenses can miss them.[/color]")
	return {"ok": true, "lines": lines}


## 3. Appraiser fee for an entry. Template block:
##   "appraiser": {"rate": 0.25, "min_fee": 5, "honesty": 0.9, "reveals_curses": true, "skill": 8}
static func fee(appraiser: Dictionary, e: Dictionary) -> int:
	var v := float(ItemStats.base(e).get("value", 20)) + 40.0 * ItemStats.enchant_ids(e).size()
	return maxi(int(appraiser.get("min_fee", 5)), roundi(v * float(appraiser.get("rate", 0.25))))


static func by_appraiser(appraiser_actor, payer, e: Dictionary) -> Dictionary:
	var a: Dictionary = DB.get_actor_template(appraiser_actor.template_id).get("appraiser", {})
	var who: String = appraiser_actor.display_name
	if a.is_empty():
		return {"ok": false, "lines": ["%s doesn't appraise." % who]}
	if ItemStats.is_identified(e) and (not ItemStats.is_cursed(e) or ItemStats.curse_known(e) or not a.get("reveals_curses", false)):
		return {"ok": false, "lines": ["%s: \"You already know what that is.\"" % who]}
	var cost := fee(a, e)
	if payer.inventory.count("coin") < cost:
		return {"ok": false, "lines": ["%s wants %d coin. You have %d." % [who, cost, payer.inventory.count("coin")]]}
	if int(a.get("skill", 8)) + 10 < dc(e):
		return {"ok": false, "lines": ["%s turns it over and hands it back. \"Beyond me. Try the Collegium.\" No charge." % who]}
	payer.inventory.remove_id("coin", cost)
	GameState.minutes += 20.0
	var honest := Rules.rng.randf() < float(a.get("honesty", 1.0))
	var tell_curse: bool = a.get("reveals_curses", false) and honest
	_reveal(e, tell_curse)
	var lines := ["%s pays %s %d coin." % [payer.display_name, who, cost], _reveal_line(who, e, "names it")]
	if ItemStats.is_cursed(e):
		if tell_curse:
			lines.append("[color=#ff8a65]%s frowns: %s[/color]" % [who, ItemStats._curse_line(e)])
		else:
			lines.append("%s: \"Clean as a whistle.\"" % who)
	return {"ok": true, "lines": lines, "fee": cost}


## 4a. Equipping an unidentified (or unknown-cursed) item: the curse wakes.
static func on_equip(actor, e: Dictionary) -> Array:
	if not ItemStats.is_cursed(e) or ItemStats.curse_known(e):
		return []
	e["curse_known"] = true
	var c := DB.get_enchantment(ItemStats.curse_id(e))
	return ["[color=#ff5252]%s's grip closes on the %s. Cursed: %s.[/color] %s" % [actor.display_name, ItemStats.display_name(e), c.get("name", "?"), c.get("desc", "")]]


## 4b. Each hit with an unidentified equipped weapon teaches a little.
static func on_hit(actor, e: Dictionary) -> Array:
	if e == null or ItemStats.is_identified(e):
		return []
	e["uses"] = int(e.get("uses", 0)) + 1
	var need := int(ItemStats.base(e).get("ident_uses", DEFAULT_USES))
	if int(e["uses"]) < need:
		return []
	_reveal(e, true)
	return [_reveal_line(actor.display_name, e, "has fought with it long enough to know it")]


## Lifts a curse (priest service or Lantern Water). The item stays identified.
static func lift_curse(e: Dictionary) -> bool:
	if not ItemStats.is_cursed(e):
		return false
	e["curse"] = ""
	e["curse_known"] = false
	Events.inventory_changed.emit()
	return true


## Every way the party could identify `e` right now, for the UI.
## Each option: {label, chance, kind, ...}
static func options(e: Dictionary, party: Array, resonance: int) -> Array:
	var out: Array = []
	var target := dc(e)
	var unknown := not ItemStats.is_identified(e)
	for a in party:
		if a.is_dead:
			continue
		for sid in a.known_skills:
			var sk := DB.get_skill(sid)
			if sk.get("kind") == "identify":
				var tries: Dictionary = e.get("ident_tries", {})
				var blocked := int(tries.get(a.display_name, -1)) == GameState.day()
				out.append({"kind": "spell", "actor": a, "skill": sid,
					"label": "%s: %s" % [a.display_name.split(" ")[0], sk.get("name", sid)],
					"chance": 0.0 if blocked else Crafting.chance(spell_bonus(a, sk, resonance), target),
					"note": "tried today" if blocked else "reveals curses"})
	if unknown:
		for a in party:
			if a.is_dead:
				continue
			for le in a.inventory.entries:
				var li := DB.get_item(le["id"])
				if li.get("identify", false):
					out.append({"kind": "lens", "actor": a, "lens": le, "pack": a.inventory,
						"label": "%s: %s (x%d)" % [a.display_name.split(" ")[0], li.get("name", "lens"), int(le["qty"])],
						"chance": Crafting.chance(lens_bonus(a, li, resonance), target),
						"note": "uses one up, may miss curses"})
					break
	return out
