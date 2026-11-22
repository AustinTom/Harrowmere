class_name Enchanting
extends RefCounted
## Binding essences and glyphs onto items (data/crafting/enchantments.json).
##
## To enchant you need: the enchantment's formula (a schematic entry with
## "enchantment": id, learned like any other), the essences it lists, an
## etching tool, an identified item of the right kind with a free slot, and
## the item not cursed. Slots come from quality (crude 0, standard 1, fine 2,
## masterwork 3) plus the material ("enchant_slots_bonus").
##
## Check: d20 + skill (enchanting for arcane, faith for divine) + Resonance
## + aptitude vs the formula's DC, +2 DC for each enchantment already on it.
##   success          the enchantment binds
##   fail             the essences are spent, the item is unharmed
##   botch (nat 1 or -10)  essences spent and a flaw curse sets into the item
##
## Machines fight magic. On an item with Gear content (guns, boilers, coils)
## every success also risks a quirk: chance = gear_content x 50%, and each
## enchantment on a machine adds 2% misfire on top (see ItemStats).

const EXISTING_ENCHANT_DC := 2
const QUIRK_CHANCE_PER_GEAR := 0.5


static func formula_for(enchant_id: String) -> String:
	for sid in DB.schematics:
		if str(DB.schematics[sid].get("enchantment", "")) == enchant_id:
			return sid
	return ""


## Enchantment ids this character holds formulae for.
static func known_enchantments(actor) -> Array:
	var out: Array = []
	for sid in actor.crafting.known:
		var s := DB.get_schematic(sid)
		if s.has("enchantment"):
			out.append(str(s["enchantment"]))
	out.sort()
	return out


static func fits(en: Dictionary, item: Dictionary) -> bool:
	var targets: Array = en.get("applies_to", ["weapon"])
	if targets.has("any"):
		return true
	if targets.has(str(item.get("type", ""))):
		return true
	for t in item.get("tags", []):
		if targets.has(t):
			return true
	if item.get("type") == "weapon":
		if targets.has("ranged") and item.get("ranged", false):
			return true
		if targets.has("melee") and not item.get("ranged", false):
			return true
	return false


static func skill_for(en: Dictionary) -> String:
	return "faith" if en.get("school", "arcane") == "divine" else "enchanting"


static func dc(e: Dictionary, en: Dictionary) -> int:
	return int(en.get("dc", 12)) + EXISTING_ENCHANT_DC * ItemStats.enchant_ids(e).size()


static func check_bonus(actor, en: Dictionary, resonance: int) -> Dictionary:
	var school := str(en.get("school", "arcane"))
	return Crafting.check_bonus(actor, {"pool": school, "skill": skill_for(en),
		"discipline": DB.get_schematic(formula_for(str(en["id"]))).get("discipline", ""),
		"tier": DB.get_schematic(formula_for(str(en["id"]))).get("tier", 1)}, resonance)


static func quirk_chance(e: Dictionary) -> float:
	return ItemStats.gear_content(ItemStats.base(e)) * QUIRK_CHANCE_PER_GEAR


static func requirements(actor, e: Dictionary, enchant_id: String, packs: Array) -> Dictionary:
	var en := DB.get_enchantment(enchant_id)
	var problems: PackedStringArray = []
	if en.is_empty() or en.get("curse", false):
		return {"ok": false, "problems": ["Unknown enchantment."]}
	var item := ItemStats.base(e)
	var sid := formula_for(enchant_id)
	if not actor.crafting.knows(sid):
		problems.append("%s doesn't know the %s formula." % [actor.display_name, en.get("name", enchant_id)])
	if not ItemStats.is_identified(e):
		problems.append("Identify the item first; you can't bind to a pattern you can't read.")
	if not fits(en, item):
		problems.append("%s only takes to: %s." % [en.get("name", "?"), ", ".join(PackedStringArray(en.get("applies_to", ["weapon"])))])
	if ItemStats.free_slots(e) <= 0:
		problems.append("No free enchant slots (%d)." % ItemStats.enchant_slots(e))
	if ItemStats.is_cursed(e):
		problems.append("The curse in it rejects new bindings. Lift it first.")
	if ItemStats.enchant_ids(e).has(enchant_id):
		problems.append("It already carries %s." % en.get("name", "?"))
	var ess: Dictionary = en.get("essences", {})
	for key in ess:
		var h := Crafting.have(packs, key)
		if h < int(ess[key]):
			problems.append("Need %d %s (have %d)." % [int(ess[key]), Crafting.input_label(key), h])
	var tool := str(en.get("tool", "etching_tools"))
	if tool != "" and not Crafting.has_tool(packs, tool):
		problems.append("Need a tool: %s." % tool.replace("_", " "))
	var min_res := int(en.get("min_resonance", 0))
	return {"ok": problems.is_empty(), "problems": problems, "min_resonance": min_res}


static func enchant(actor, e: Dictionary, enchant_id: String, packs: Array, resonance: int) -> Dictionary:
	var en := DB.get_enchantment(enchant_id)
	var req := requirements(actor, e, enchant_id, packs)
	var r := {"ok": false, "outcome": "", "lines": []}
	if not req["ok"]:
		r["lines"] = req["problems"]
		return r
	if resonance < int(req["min_resonance"]):
		r["lines"] = ["%s needs Resonance %d or more to take hold. It is %d here." % [en.get("name", "?"), req["min_resonance"], resonance]]
		return r
	var b := check_bonus(actor, en, resonance)
	var target := dc(e, en)
	var d := Rules.d20()
	var margin: int = d + int(b["total"]) - target
	var ess: Dictionary = en.get("essences", {})
	for key in ess:
		Crafting.take(packs, key, int(ess[key]))
	GameState.minutes += float(en.get("minutes", 60))
	r["ok"] = true
	var head := "%s binds %s to the %s: %d%+d=%d vs DC %d (%s)" % [actor.display_name, en.get("name", "?"), ItemStats.display_name(e), d, b["total"], d + int(b["total"]), target, Crafting.bonus_text(b)]
	if d == 1 or (d != 20 and margin <= -10):
		r["outcome"] = "botched"
		e["curse"] = "flawed_glyph"
		e["curse_known"] = true
		r["lines"].append("%s. [color=#ff5252]The glyph cracks and sets crooked. The item is flawed.[/color]" % head)
	elif d != 20 and margin < 0:
		r["outcome"] = "failed"
		r["lines"].append("%s. [color=#ff8a65]It won't take. The essences are spent.[/color]" % head)
	else:
		r["outcome"] = "success"
		var list: Array = e.get("enchants", [])
		list.append(enchant_id)
		e["enchants"] = list
		r["lines"].append("%s. [color=#c49bff]%s takes hold.[/color]" % [head, en.get("name", "?")])
		if Rules.rng.randf() < quirk_chance(e):
			var q: Dictionary = e.get("quirks", {})
			q["misfire_add"] = float(q.get("misfire_add", 0.0)) + 0.03
			e["quirks"] = q
			r["lines"].append("[color=#ffb347]The machinery fights the binding. It runs rough now: +3% misfire.[/color]")
	Events.inventory_changed.emit()
	return r
