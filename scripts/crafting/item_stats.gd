class_name ItemStats
extends RefCounted
## Turns an inventory entry into the stats the game actually uses.
##
## An entry is a base item (data/items*.json) plus instance data:
##   quality   "crude" | "standard" | "fine" | "masterwork"  (data/crafting/qualities.json)
##   enchants  enchantment ids added by enchanting or rolled on loot
##   curse     curse id, or "" once lifted (overrides the base item's curse)
##   quirks    side effects from enchanting machinery, e.g. {"misfire_add": 0.03}
##   identified, curse_known, uses (hits landed while unidentified)
##
## A base item's hidden powers live in its "magic" block:
##   "magic": {"enchants": ["frost_edge"], "curse": "drowned_grip"}
## Enchantments stay dormant until the entry is identified. Curses always work.

const GEAR_ENCHANT_MISFIRE := 0.02 ## each enchantment on a machine adds this misfire chance
const NUMERIC_EFFECTS := ["to_hit", "damage_flat", "ac_bonus", "spell_power", "misfire_add"]


static func base(e: Dictionary) -> Dictionary:
	return DB.get_item(str(e.get("id", "")))


static func quality_id(e: Dictionary) -> String:
	return str(e.get("quality", base(e).get("quality", "standard")))


static func is_identified(e: Dictionary) -> bool:
	return bool(e.get("identified", true))


## Every enchantment on the entry, known or not.
static func enchant_ids(e: Dictionary) -> Array:
	var out: Array = []
	var magic: Dictionary = base(e).get("magic", {})
	out.append_array(magic.get("enchants", []))
	out.append_array(e.get("enchants", []))
	return out


static func curse_id(e: Dictionary) -> String:
	if e.has("curse"):
		return str(e["curse"])
	return str(base(e).get("magic", {}).get("curse", ""))


static func is_cursed(e: Dictionary) -> bool:
	return curse_id(e) != ""


static func curse_known(e: Dictionary) -> bool:
	return bool(e.get("curse_known", false))


## Cursed items with a sticky curse can't be taken off once the curse wakes.
static func is_stuck(e: Dictionary) -> bool:
	if not e.get("equipped", false) or not is_cursed(e) or not curse_known(e):
		return false
	return bool(DB.get_enchantment(curse_id(e)).get("sticky", false))


static func enchant_slots(e: Dictionary) -> int:
	var it := base(e)
	if not it.get("enchantable", it.get("type") in ["weapon", "armor", "trinket"]):
		return 0
	var q := DB.get_quality(quality_id(e))
	return maxi(0, int(q.get("enchant_slots", 1)) + int(it.get("enchant_slots_bonus", 0)))


static func free_slots(e: Dictionary) -> int:
	return enchant_slots(e) - enchant_ids(e).size()


## How much machinery is in the item, 0..1. Enchanting it is risky in proportion.
static func gear_content(item: Dictionary) -> float:
	if item.has("gear_content"):
		return float(item["gear_content"])
	return 0.7 if item.get("pool", "neutral") == "gear" else 0.0


## The effective stats of an entry. Use this instead of DB.get_item() for
## anything that equips, fights or sells.
static func resolve(e: Dictionary) -> Dictionary:
	var it := base(e)
	var d: Dictionary = it.duplicate(true)
	var magic: Dictionary = d.get("magic", {})
	d.erase("magic")
	var ident := is_identified(e)
	if not ident:
		d["name"] = it.get("unidentified_name", it.get("name", "?"))
	var q := DB.get_quality(quality_id(e))
	d["quality"] = quality_id(e)
	var acc := {"to_hit": 0, "damage_flat": 0, "ac_bonus": int(d.get("ac_bonus", 0)),
		"spell_power": int(d.get("spell_power", 0)), "misfire_add": 0.0}
	var special: Array = d.get("special", []).duplicate()
	var extra: Array = d.get("extra_damage", []).duplicate(true)
	if d.has("bonus_damage"):
		extra.append({"dice": d["bonus_damage"], "type": d.get("bonus_type", "arcane"), "school": "arcane"})
		d.erase("bonus_damage")
		d.erase("bonus_type")
	if d.get("type") in ["weapon", "armor", "trinket"]:
		acc["to_hit"] += int(q.get("to_hit", 0)) if d.get("type") == "weapon" else 0
		acc["damage_flat"] += int(q.get("damage_flat", 0)) if d.get("type") == "weapon" else 0
		acc["ac_bonus"] += int(q.get("ac_bonus", 0)) if d.get("type") == "armor" else 0
	var effects: Array = []
	var names: Array = []
	if ident:
		# Raw hidden fields in the magic block (besides enchants/curse) also wake up.
		for k in magic:
			if k != "enchants" and k != "curse":
				effects.append({k: magic[k]})
		for id in enchant_ids(e):
			var en := DB.get_enchantment(str(id))
			effects.append(en.get("effects", {}))
			names.append(en.get("name", id))
	var cid := curse_id(e)
	if cid != "":
		effects.append(DB.get_enchantment(cid).get("effects", {}))
	effects.append(e.get("quirks", {}))
	for fx in effects:
		_apply_effects(fx, acc, special, extra)
	if d.get("pool", "neutral") == "gear":
		var mf := float(d.get("misfire", 0.02)) * float(q.get("misfire_mult", 1.0))
		mf += acc["misfire_add"] + GEAR_ENCHANT_MISFIRE * enchant_ids(e).size()
		d["misfire"] = clampf(mf, 0.0, 0.9)
		if d.has("alt"):
			var amf := float(d["alt"].get("misfire", d["misfire"])) * float(q.get("misfire_mult", 1.0))
			d["alt"]["misfire"] = clampf(amf + acc["misfire_add"] + GEAR_ENCHANT_MISFIRE * enchant_ids(e).size(), 0.0, 0.9)
	for k in ["to_hit", "damage_flat", "ac_bonus", "spell_power"]:
		if acc[k] != 0:
			d[k] = acc[k]
		else:
			d.erase(k)
	if special.is_empty():
		d.erase("special")
	else:
		d["special"] = special
	if extra.is_empty():
		d.erase("extra_damage")
	else:
		d["extra_damage"] = extra
	d["enchant_names"] = names
	d["value"] = value(e)
	return d


static func _apply_effects(fx: Dictionary, acc: Dictionary, special: Array, extra: Array) -> void:
	for k in fx:
		if k in NUMERIC_EFFECTS:
			acc[k] += fx[k]
		elif k == "special":
			for s in fx[k]:
				if not special.has(s):
					special.append(s)
		elif k == "extra_damage":
			extra.append_array(fx[k].duplicate(true))
		elif k == "bonus_damage":
			extra.append({"dice": fx[k], "type": fx.get("bonus_type", "arcane"), "school": "arcane"})


static func value(e: Dictionary) -> int:
	var it := base(e)
	var v := float(it.get("value", 0)) * float(DB.get_quality(quality_id(e)).get("value_mult", 1.0))
	for id in enchant_ids(e):
		v += float(DB.get_enchantment(str(id)).get("value", 50))
	if is_cursed(e) and curse_known(e):
		v *= 0.3
	return maxi(0, roundi(v))


static func display_name(e: Dictionary) -> String:
	var it := base(e)
	if not is_identified(e):
		return str(it.get("unidentified_name", "Unknown " + str(it.get("type", "item"))))
	var n := str(it.get("name", e.get("id", "?")))
	var q := quality_id(e)
	if q != "standard" and it.get("type") in ["weapon", "armor", "trinket", "tool"]:
		n = "%s %s" % [DB.get_quality(q).get("name", q.capitalize()), n]
	var added: Array = e.get("enchants", [])
	if not added.is_empty():
		var tags: PackedStringArray = []
		for id in added:
			tags.append(str(DB.get_enchantment(str(id)).get("short", DB.get_enchantment(str(id)).get("name", id))))
		n += " (%s)" % ", ".join(tags)
	if is_cursed(e) and curse_known(e):
		n += " [cursed]"
	return n


static func describe(e: Dictionary) -> String:
	var it := base(e)
	var parts: PackedStringArray = []
	if not is_identified(e):
		parts.append(str(it.get("unidentified_name", "Unknown item")))
		if it.has("hint"):
			parts.append(str(it["hint"]))
		parts.append("Unidentified. Its powers stay dormant until you learn what it is: an identify spell or prayer, an Assayer's Lens, a paid appraiser, or equip it and find out.")
		if is_cursed(e) and curse_known(e):
			parts.append(_curse_line(e))
		return "\n".join(parts)
	var d := resolve(e)
	parts.append(display_name(e))
	if d.get("type") == "weapon":
		var line := "%s pool. Damage %s, %d AP, range %d ft." % [str(d.get("pool", "neutral")).capitalize(), d.get("damage", "?"), int(d.get("ap", 0)), int(d.get("range", 5))]
		if d.has("to_hit") or d.has("damage_flat"):
			line += " %+d to hit, %+d damage." % [int(d.get("to_hit", 0)), int(d.get("damage_flat", 0))]
		if d.get("pool") == "gear":
			line += " Base misfire %d%%." % roundi(float(d.get("misfire", 0)) * 100)
		parts.append(line)
		for x in d.get("extra_damage", []):
			parts.append("+%s %s (%s)" % [x.get("dice", "?"), x.get("type", ""), x.get("school", "arcane")])
		if d.has("alt"):
			parts.append("Alt: %s, %s damage, %d AP." % [d["alt"].get("label", "alt"), d["alt"].get("damage", "?"), int(d["alt"].get("ap", 0))])
	if d.has("ac_bonus"):
		parts.append("%+d AC while equipped." % int(d["ac_bonus"]))
	if d.has("spell_power"):
		parts.append("%+d spell power." % int(d["spell_power"]))
	for id in enchant_ids(e):
		var en := DB.get_enchantment(str(id))
		parts.append("Enchanted: %s. %s" % [en.get("name", id), en.get("desc", "")])
	if is_cursed(e) and curse_known(e):
		parts.append(_curse_line(e))
	var slots := enchant_slots(e)
	if slots > 0:
		parts.append("Enchant slots: %d of %d free." % [maxi(0, free_slots(e)), slots])
	for k in e.get("quirks", {}):
		parts.append("Quirk: %s %+.0f%%" % [k.replace("_", " "), float(e["quirks"][k]) * 100] if k == "misfire_add" else "Quirk: " + k)
	if it.get("type") == "schematic":
		var s := DB.get_schematic(str(it.get("teaches", "")))
		parts.append("Teaches: %s (%s, tier %d)." % [s.get("name", "?"), DB.get_discipline(str(s.get("discipline", ""))).get("name", "?"), int(s.get("tier", 0))])
	if it.has("desc"):
		parts.append(str(it["desc"]))
	parts.append("Value %d." % value(e))
	return "\n".join(parts)


static func _curse_line(e: Dictionary) -> String:
	var c := DB.get_enchantment(curse_id(e))
	return "[Cursed: %s] %s%s" % [c.get("name", "?"), c.get("desc", ""), " It will not come off." if c.get("sticky", false) else ""]
