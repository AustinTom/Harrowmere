class_name Crafting
extends RefCounted
## Crafting rules. Pure functions over actors, inventories and data, like
## Rules, so the UI, NPCs and tests all craft the same way.
##
## How a character comes to hold a schematic (data/crafting/schematics.json):
##   * Tier picks. Each trade (data/crafting/disciplines.json) has 5 tiers of
##     4 schematics. Buying a tier costs a trade point and lets you choose 2
##     of its 4, so two engineers in the same trade know different things.
##   * Patents. Reaching tier 5 in two named trades unlocks hybrid schematics.
##   * Found and bought. Schematic items (type "schematic", "teaches": id)
##     dropped in ruins, sold by tinkers, given by quests. Reading one
##     teaches it outright, whatever your tier, but you still need the tier
##     to build it.
##
## Making the thing: d20 + skill + Resonance + aptitude + tier surplus vs DC.
## The margin sets quality:
##   +10 or natural 20  masterwork     0..4    standard    -6..-9  failed, about half the parts lost
##   +5..+9             fine           -1..-5  crude       -10 or natural 1  botched, all parts lost
## Machines come out better where Resonance is low; arcane and divine work
## better where it is high. Tech and magic never share inputs or fuel:
## Gear runs on coal, iron and steam, magic on essences.

const RESULT_COLORS := {"masterwork": "#ffd84d", "fine": "#9fe07f", "standard": "#dddddd",
	"crude": "#c9a27a", "failed": "#ff8a65", "botched": "#ff5252"}


# ---------------------------------------------------------------- learning

## Buys the next tier of a trade. Spends a trade point. Returns {ok, msg}.
static func buy_tier(actor, discipline: String) -> Dictionary:
	var disc := DB.get_discipline(discipline)
	if disc.is_empty() or not disc.get("tiered", true):
		return {"ok": false, "msg": "%s has no tiers to buy." % disc.get("name", discipline)}
	var res := SkillHooks.buy_tier(actor, discipline)
	if not res["ok"]:
		return res
	var t := SkillHooks.tier(actor, discipline)
	var lines: PackedStringArray = ["%s reaches %s tier %d. Choose %d schematics." % [actor.display_name, disc["name"], t, SkillHooks.picks_left(actor, discipline, t)]]
	for sid in unlock_patents(actor):
		lines.append("Patent unlocked: %s." % DB.get_schematic(sid).get("name", sid))
	return {"ok": true, "msg": " ".join(lines)}


## Chooses one schematic from a tier you've reached.
static func pick(actor, discipline: String, t: int, schematic_id: String) -> Dictionary:
	var k: CraftingKnowledge = actor.crafting
	var offered: Array = DB.get_discipline(discipline).get("tiers", {}).get(str(t), [])
	if not offered.has(schematic_id):
		return {"ok": false, "msg": "That isn't one of the tier %d choices." % t}
	if k.knows(schematic_id):
		return {"ok": false, "msg": "Already known."}
	if SkillHooks.picks_left(actor, discipline, t) <= 0:
		return {"ok": false, "msg": "No picks left at tier %d." % t}
	k.learn(schematic_id, "pick")
	var key := "%s:%d" % [discipline, t]
	var made: Array = k.picks.get(key, [])
	made.append(schematic_id)
	k.picks[key] = made
	SkillHooks.record_pick(actor, schematic_id)
	return {"ok": true, "msg": "%s learns %s." % [actor.display_name, DB.get_schematic(schematic_id).get("name", schematic_id)]}


## Learns every patent whose trade requirements are met. Returns new ids.
static func unlock_patents(actor) -> Array:
	var k: CraftingKnowledge = actor.crafting
	var out: Array = []
	for sid in DB.schematics:
		var s: Dictionary = DB.schematics[sid]
		if not s.get("patent", false) or k.knows(sid):
			continue
		var ok := true
		var req: Dictionary = s.get("requires_tiers", {})
		for d in req:
			if SkillHooks.tier(actor, d) < int(req[d]):
				ok = false
		if ok and not req.is_empty():
			k.learn(sid, "patent")
			out.append(sid)
	return out


## Reads a found or bought schematic item. Consumes it.
static func learn_from_item(actor, entry: Dictionary) -> Dictionary:
	var it := DB.get_item(str(entry["id"]))
	var sid := str(it.get("teaches", ""))
	var s := DB.get_schematic(sid)
	if s.is_empty():
		return {"ok": false, "msg": "There's nothing to learn from this."}
	if not entry.get("identified", true):
		return {"ok": false, "msg": "Identify it first."}
	var k: CraftingKnowledge = actor.crafting
	if k.knows(sid):
		return {"ok": false, "msg": "%s already knows %s." % [actor.display_name, s["name"]]}
	k.learn(sid, "book")
	actor.inventory.remove_one(entry)
	var need := int(s.get("tier", 1))
	var disc := DB.get_discipline(str(s.get("discipline", "")))
	var note := ""
	if disc.get("tiered", true) and SkillHooks.tier(actor, str(s["discipline"])) < need:
		note = " Building it needs %s tier %d." % [disc.get("name", "?"), need]
	return {"ok": true, "msg": "%s studies the %s and learns %s.%s" % [actor.display_name, it.get("name", "?"), s["name"], note]}


## Teaches a schematic for coin (trainers, guild clerks). Coin comes from `payer`.
static func buy_schematic(actor, payer, schematic_id: String, cost: int) -> Dictionary:
	var s := DB.get_schematic(schematic_id)
	if s.is_empty():
		return {"ok": false, "msg": "Unknown schematic."}
	if actor.crafting.knows(schematic_id):
		return {"ok": false, "msg": "%s already knows %s." % [actor.display_name, s["name"]]}
	if payer.inventory.count("coin") < cost:
		return {"ok": false, "msg": "Not enough coin (%d needed)." % cost}
	payer.inventory.remove_id("coin", cost)
	actor.crafting.learn(schematic_id, "trainer")
	return {"ok": true, "msg": "%s pays %d coin and learns %s." % [actor.display_name, cost, s["name"]]}


# ---------------------------------------------------------------- checks

static func resonance_mod(pool: String, resonance: int) -> int:
	match pool:
		"gear":
			return roundi((50 - resonance) / 10.0)
		"arcane":
			return roundi((resonance - 50) / 10.0)
		"divine":
			return roundi((resonance - 50) / 20.0)
	return 0


static func aptitude_mod(pool: String, aptitude: int) -> int:
	match pool:
		"gear":
			return int(-aptitude / 40.0)
		"arcane", "divine":
			return int(aptitude / 40.0)
	return 0


static func pool_of(s: Dictionary) -> String:
	return str(s.get("pool", DB.get_discipline(str(s.get("discipline", ""))).get("pool", "neutral")))


static func skill_of(s: Dictionary) -> String:
	return str(s.get("skill", DB.get_discipline(str(s.get("discipline", ""))).get("skill", "")))


## The full bonus for a check, with a breakdown for the UI.
static func check_bonus(actor, s: Dictionary, resonance: int) -> Dictionary:
	var pool := pool_of(s)
	var parts: Array = []
	var skill := skill_of(s)
	parts.append([skill.capitalize(), SkillHooks.skill_bonus(actor, skill)])
	var rm := resonance_mod(pool, resonance)
	if rm != 0:
		parts.append(["Resonance %d" % resonance, rm])
	var am := aptitude_mod(pool, int(actor.aptitude))
	if am != 0:
		parts.append(["Aptitude", am])
	var disc := str(s.get("discipline", ""))
	if DB.get_discipline(disc).get("tiered", true) and actor.crafting != null:
		var surplus: int = SkillHooks.tier(actor, disc) - int(s.get("tier", 1))
		if surplus > 0:
			parts.append(["Tier surplus", surplus])
	var total := 0
	for p in parts:
		total += int(p[1])
	return {"total": total, "parts": parts}


static func bonus_text(b: Dictionary) -> String:
	var bits: PackedStringArray = []
	for p in b["parts"]:
		bits.append("%s %+d" % [p[0], int(p[1])])
	return ", ".join(bits)


## Chance (0..1) that a d20 + bonus check lands at margin >= `min_margin`.
## Natural 1 always fails, natural 20 always succeeds.
static func chance(bonus: int, dc: int, min_margin := 0) -> float:
	var ok := 0
	for d in range(1, 21):
		if d == 20 or (d != 1 and d + bonus - dc >= min_margin):
			ok += 1
	return ok / 20.0


static func outcome_for(d: int, margin: int) -> String:
	if d == 1 or margin <= -10:
		return "botched"
	if d == 20 or margin >= 10:
		return "masterwork"
	if margin >= 5:
		return "fine"
	if margin >= 0:
		return "standard"
	if margin >= -5:
		return "crude"
	return "failed"


# ---------------------------------------------------------------- packs

## Counts an input across the packs. Keys are item ids, or "tag:<tag>".
static func have(packs: Array, key: String) -> int:
	var n := 0
	for inv in packs:
		n += inv.count_tag(key.substr(4)) if key.begins_with("tag:") else inv.count(key)
	return n


static func has_tool(packs: Array, tag: String) -> bool:
	for inv in packs:
		if inv.has_tool(tag):
			return true
	return false


## Takes `qty` of an input from the packs, first pack first. Returns ids taken.
static func take(packs: Array, key: String, qty: int) -> Array:
	var taken: Array = []
	var left := qty
	for inv in packs:
		if left <= 0:
			break
		if key.begins_with("tag:"):
			var tag := key.substr(4)
			for e in inv.entries.duplicate():
				if left <= 0:
					break
				if DB.get_item(e["id"]).get("tags", []).has(tag):
					var got: int = inv.remove_id(e["id"], left)
					for i in got:
						taken.append(e["id"])
					left -= got
		else:
			var got: int = inv.remove_id(key, left)
			for i in got:
				taken.append(key)
			left -= got
	return taken


static func input_label(key: String) -> String:
	if key.begins_with("tag:"):
		return "any " + key.substr(4).replace("_", " ")
	return str(DB.get_item(key).get("name", key))


# ---------------------------------------------------------------- crafting

## What stops `actor` from making schematic `sid` right now.
static func requirements(actor, sid: String, packs: Array) -> Dictionary:
	var s := DB.get_schematic(sid)
	var problems: PackedStringArray = []
	var inputs: Array = []
	if s.is_empty():
		return {"ok": false, "problems": ["Unknown schematic."], "inputs": [], "tools": []}
	var k: CraftingKnowledge = actor.crafting
	if not k.knows(sid):
		problems.append("You don't know this %s." % s.get("kind", "schematic"))
	var disc := str(s.get("discipline", ""))
	if s.get("patent", false):
		var req: Dictionary = s.get("requires_tiers", {})
		for d in req:
			if SkillHooks.tier(actor, d) < int(req[d]):
				problems.append("Needs %s tier %d." % [DB.get_discipline(d).get("name", d), int(req[d])])
	elif DB.get_discipline(disc).get("tiered", true) and SkillHooks.tier(actor, disc) < int(s.get("tier", 1)):
		problems.append("Needs %s tier %d (you have %d)." % [DB.get_discipline(disc).get("name", disc), int(s.get("tier", 1)), SkillHooks.tier(actor, disc)])
	var ins: Dictionary = s.get("inputs", {})
	for key in ins:
		var h := have(packs, key)
		inputs.append({"key": key, "need": int(ins[key]), "have": h})
		if h < int(ins[key]):
			problems.append("Need %d %s (have %d)." % [int(ins[key]), input_label(key), h])
	var tools: Array = []
	for tag in s.get("tools", []):
		var ok := has_tool(packs, tag)
		tools.append({"tag": tag, "have": ok})
		if not ok:
			problems.append("Need a tool: %s." % str(tag).replace("_", " "))
	if s.has("enchantment"):
		problems.append("Enchantment formulae are used from the Enchant tab.")
	return {"ok": problems.is_empty(), "problems": problems, "inputs": inputs, "tools": tools}


## Makes one batch of a schematic. Inputs come from `packs` (the crafter's
## pack first, then followers'); the result goes into the crafter's pack.
static func craft(actor, sid: String, packs: Array, resonance: int) -> Dictionary:
	var s := DB.get_schematic(sid)
	var req := requirements(actor, sid, packs)
	var r := {"ok": false, "outcome": "", "lines": [], "entry": null, "self_damage": 0, "lost": []}
	if not req["ok"]:
		r["lines"] = req["problems"]
		return r
	var b := check_bonus(actor, s, resonance)
	var dc := int(s.get("dc", 10))
	var d := Rules.d20()
	var margin: int = d + int(b["total"]) - dc
	var outcome := outcome_for(d, margin)
	r["ok"] = true
	r["outcome"] = outcome
	r["roll"] = d
	r["margin"] = margin
	var out: Dictionary = s.get("output", {})
	var out_name := str(DB.get_item(str(out.get("item", ""))).get("name", "?"))
	var ins: Dictionary = s.get("inputs", {})
	var head := "%s works the %s: %d%+d=%d vs DC %d (%s)" % [actor.display_name, s.get("name", sid), d, b["total"], d + int(b["total"]), dc, bonus_text(b)]
	if outcome in ["masterwork", "fine", "standard", "crude"]:
		for key in ins:
			take(packs, key, int(ins[key]))
		var made = actor.inventory.add(str(out["item"]), int(out.get("qty", 1)), true, {"quality": outcome, "crafted_by": actor.display_name})
		r["entry"] = made
		var q := "" if DB.get_item(str(out["item"])).get("stack", false) else " %s" % str(DB.get_quality(outcome).get("name", outcome)).to_lower()
		r["lines"].append("%s. [color=%s]Made%s %s%s.[/color]" % [head, RESULT_COLORS[outcome], q, out_name, " x%d" % int(out.get("qty", 1)) if int(out.get("qty", 1)) > 1 else ""])
	else:
		for key in ins:
			var n := int(ins[key])
			var lose := n if outcome == "botched" else n / 2 + (1 if n % 2 == 1 and Rules.rng.randf() < 0.5 else 0)
			r["lost"].append_array(take(packs, key, lose))
		var lost_txt := "nothing lost" if r["lost"].is_empty() else "lost %d parts" % r["lost"].size()
		r["lines"].append("%s. [color=%s]%s, %s.[/color]" % [head, RESULT_COLORS[outcome], outcome.capitalize(), lost_txt])
		if outcome == "botched" and s.has("botch_damage"):
			r["self_damage"] = maxi(1, Rules.roll_dice(str(s["botch_damage"])))
			r["lines"].append("[color=#ff5252]It goes off in %s's hands for %d damage.[/color]" % [actor.display_name, r["self_damage"]])
	GameState.minutes += float(s.get("minutes", 30))
	return r


## Everything a character could look at in the Craft tab: known schematics
## (non-enchantment), sorted by discipline then tier.
static func known_craftables(actor) -> Array:
	var out: Array = []
	for sid in actor.crafting.known:
		var s := DB.get_schematic(sid)
		if not s.is_empty() and not s.has("enchantment"):
			out.append(sid)
	out.sort_custom(func(a, b):
		var sa := DB.get_schematic(a)
		var sb := DB.get_schematic(b)
		if sa.get("discipline") != sb.get("discipline"):
			return str(sa.get("discipline")) < str(sb.get("discipline"))
		if int(sa.get("tier", 0)) != int(sb.get("tier", 0)):
			return int(sa.get("tier", 0)) < int(sb.get("tier", 0))
		return str(sa.get("name")) < str(sb.get("name")))
	return out
