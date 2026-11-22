class_name SkillHooks
extends RefCounted
## The one place crafting, identification and enchanting read the character
## system. The character system owns skills, ranks and points; until its
## schema lands these fall back to ability modifiers, so nothing here needs
## to change when it does: implement the methods named below on Actor.
##
##   actor.skill_bonus(skill_id) -> int        total check bonus for a skill
##   actor.spend_points(kind, amount) -> bool  spend character points ("trade")
##
##   actor.pick_schematic(discipline, id)      records a tier pick on the sheet
##
## Skill ids used by crafting: mechanics, chemistry, smithing, alchemy,
## enchanting, faith, appraisal.

## Which ability a skill leans on when the character system isn't there yet.
const FALLBACK_STAT := {
	"mechanics": "int", "chemistry": "int", "smithing": "str", "alchemy": "int",
	"enchanting": "int", "faith": "wis", "appraisal": "int",
}


static func skill_bonus(actor, skill_id: String) -> int:
	if actor == null:
		return 0
	if actor.has_method("skill_bonus"):
		return int(actor.skill_bonus(skill_id))
	var stat: String = FALLBACK_STAT.get(skill_id, "int")
	var b := Rules.mod(int(actor.stats.get(stat, 10)))
	# Trained in any discipline that uses this skill: add proficiency.
	var k = actor.get("crafting")
	if k != null and k.is_trained(skill_id):
		b += Rules.PROFICIENCY
	return b


## Spends one character point on a trade tier. Uses the character system's
## points if it has them, otherwise the crafting component's own pool.
static func spend_trade_point(actor) -> bool:
	if actor.has_method("spend_points"):
		return bool(actor.spend_points("trade", 1))
	var k = actor.get("crafting")
	if k == null or k.points <= 0:
		return false
	k.points -= 1
	return true


static func trade_points(actor) -> int:
	if actor.has_method("points_available"):
		return int(actor.points_available("trade"))
	var k = actor.get("crafting")
	return 0 if k == null else int(k.points)


# ---------------------------------------------------------------- trade tiers
# Trade tiers cost character points and push aptitude, so the character
# sheet owns them when it exists (Actor.tier / can_buy / buy /
# schematic_picks_left / sheet.schematics). Without it, the crafting
# component keeps its own tiers so crafting still works on its own.

static func tier(actor, discipline: String) -> int:
	if actor.has_method("tier"):
		return int(actor.tier(discipline))
	var k = actor.get("crafting")
	return 0 if k == null else k.tier(discipline)


static func buy_tier(actor, discipline: String) -> Dictionary:
	if actor.has_method("buy"):
		if actor.has_method("can_buy"):
			var chk: Dictionary = actor.can_buy("tier", discipline)
			if not chk.get("ok", false):
				return {"ok": false, "msg": str(chk.get("reason", "Can't buy that tier yet."))}
		return {"ok": bool(actor.buy("tier", discipline)), "msg": ""}
	if tier(actor, discipline) >= CraftingKnowledge.MAX_TIER:
		return {"ok": false, "msg": "Already at tier 5."}
	if not spend_trade_point(actor):
		return {"ok": false, "msg": "No trade points to spend."}
	actor.crafting.tiers[discipline] = tier(actor, discipline) + 1
	return {"ok": true, "msg": ""}


## Tier picks still owed at tier t of a discipline.
static func picks_left(actor, discipline: String, t: int) -> int:
	if tier(actor, discipline) < t:
		return 0
	var k: CraftingKnowledge = actor.crafting
	var offered: Array = DB.get_discipline(discipline).get("tiers", {}).get(str(t), [])
	var unknown := 0
	for s in offered:
		if not k.knows(str(s)):
			unknown += 1
	var left := CraftingKnowledge.PICKS_PER_TIER - k.picks_made(discipline, t).size()
	if actor.has_method("schematic_picks_left"):
		left = mini(left, int(actor.schematic_picks_left(discipline)))
	return maxi(0, mini(left, unknown))


## Tells the character sheet about a tier pick so it's saved and counted there.
static func record_pick(actor, schematic_id: String) -> void:
	var disc := str(DB.get_schematic(schematic_id).get("discipline", ""))
	if actor.has_method("pick_schematic"):
		actor.pick_schematic(disc, schematic_id)
		return
	var sheet = actor.get("sheet")
	if sheet != null and sheet.get("schematics") is Array and not sheet.schematics.has(schematic_id):
		sheet.schematics.append(schematic_id)
