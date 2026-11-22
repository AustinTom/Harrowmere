class_name CraftingKnowledge
extends RefCounted
## What one character knows about making things: trade tiers, the schematics,
## formulae and recipes they hold, and which tier picks they've made.
## Plain data with to_dict()/from_dict() so a save system can store it.

const PICKS_PER_TIER := 2
const MAX_TIER := 5

var tiers: Dictionary = {}   ## fallback tiers, only used when the character sheet has no tier() (see SkillHooks)
var known: Dictionary = {}   ## schematic id -> how it was learned ("pick", "book", "trainer", "patent", "start")
var picks: Dictionary = {}   ## "discipline:tier" -> [schematic ids chosen from that tier]
var points := 0              ## fallback trade points until the character system owns them


func tier(discipline: String) -> int:
	return int(tiers.get(discipline, 0))


func knows(schematic_id: String) -> bool:
	return known.has(schematic_id)


func learn(schematic_id: String, how: String) -> bool:
	if known.has(schematic_id) or DB.get_schematic(schematic_id).is_empty():
		return false
	known[schematic_id] = how
	return true


func picks_made(discipline: String, t: int) -> Array:
	return picks.get("%s:%d" % [discipline, t], [])


func is_trained(skill_id: String) -> bool:
	for d in tiers:
		if tier(d) > 0 and DB.get_discipline(d).get("skill", "") == skill_id:
			return true
	return false


func to_dict() -> Dictionary:
	return {"tiers": tiers.duplicate(), "known": known.duplicate(), "picks": picks.duplicate(true), "points": points}


static func from_dict(d: Dictionary) -> CraftingKnowledge:
	var k := CraftingKnowledge.new()
	k.tiers = d.get("tiers", {}).duplicate()
	for t in k.tiers:
		k.tiers[t] = int(k.tiers[t])
	var kn = d.get("known", {})
	if kn is Array:
		for s in kn:
			k.known[str(s)] = "start"
	else:
		k.known = kn.duplicate()
	k.picks = d.get("picks", {}).duplicate(true)
	k.points = int(d.get("points", 0))
	return k
