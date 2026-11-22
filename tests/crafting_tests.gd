extends RefCounted
## Checks for crafting, identification and enchanting, plus a data linter
## that keeps the schematic catalogue consistent as it grows toward ~1,500
## items. Called from tests/test_runner.gd.

var t = null ## the test runner (has check())


class FakeCrafter:
	var display_name := "Crafter"
	var template_id := ""
	var stats := {"str": 12, "dex": 12, "con": 10, "int": 14, "wis": 14, "cha": 10}
	var aptitude := 0
	var ac := 12
	var known_skills: Array = ["identify"]
	var inventory := Inventory.new()
	var crafting := CraftingKnowledge.new()


## Stands in for the character system's sheet API (tier/can_buy/buy/...).
class FakeSheetActor:
	extends FakeCrafter
	var sheet_tiers := {"ballistics": 2}
	var cp := 1
	var sheet := {"schematics": []}
	func tier(id: String) -> int:
		return int(sheet_tiers.get(id, 0))
	func can_buy(_kind: String, _id: String) -> Dictionary:
		return {"ok": cp > 0, "reason": "No character points."}
	func buy(_kind: String, id: String) -> bool:
		if cp <= 0:
			return false
		cp -= 1
		sheet_tiers[id] = tier(id) + 1
		return true
	func schematic_picks_left(_id: String) -> int:
		return 3 - sheet["schematics"].size()
	func pick_schematic(_discipline: String, id: String) -> void:
		sheet["schematics"].append(id)
	func skill_bonus(_id: String) -> int:
		return 7


func check(cond: bool, msg: String) -> void:
	t.check(cond, msg)


func run() -> void:
	print("Crafting data")
	_lint()
	print("Crafting")
	_crafting()
	print("Identification")
	_identification()
	print("Enchanting")
	_enchanting()


# ---------------------------------------------------------------- data lint

func _lint() -> void:
	var problems: PackedStringArray = []
	var tool_tags := {}
	var item_tags := {}
	for id in DB.items:
		var it: Dictionary = DB.items[id]
		if not it.has("name") or not it.has("type"):
			problems.append("item %s lacks name/type" % id)
		for tg in it.get("tool_tags", []):
			tool_tags[tg] = true
		for tg in it.get("tags", []):
			item_tags[tg] = true
		var magic: Dictionary = it.get("magic", {})
		for en in magic.get("enchants", []):
			if DB.get_enchantment(en).is_empty():
				problems.append("item %s: unknown enchant %s" % [id, en])
		if magic.has("curse") and not DB.get_enchantment(str(magic["curse"])).get("curse", false):
			problems.append("item %s: unknown curse %s" % [id, magic["curse"]])
		if it.get("type") == "schematic" and DB.get_schematic(str(it.get("teaches", ""))).is_empty():
			problems.append("schematic item %s teaches unknown %s" % [id, it.get("teaches")])
	for sid in DB.schematics:
		var s: Dictionary = DB.schematics[sid]
		if DB.get_discipline(str(s.get("discipline", ""))).is_empty():
			problems.append("schematic %s: unknown discipline" % sid)
		if s.has("enchantment"):
			if DB.get_enchantment(str(s["enchantment"])).is_empty():
				problems.append("formula %s: unknown enchantment" % sid)
			continue
		if DB.get_item(str(s.get("output", {}).get("item", ""))).is_empty():
			problems.append("schematic %s: unknown output" % sid)
		for key in s.get("inputs", {}):
			if key.begins_with("tag:"):
				if not item_tags.has(key.substr(4)):
					problems.append("schematic %s: no item has tag %s" % [sid, key])
			elif DB.get_item(key).is_empty():
				problems.append("schematic %s: unknown input %s" % [sid, key])
		for tg in s.get("tools", []):
			if not tool_tags.has(tg):
				problems.append("schematic %s: no tool provides %s" % [sid, tg])
	for did in DB.disciplines:
		var tiers: Dictionary = DB.disciplines[did].get("tiers", {})
		for tk in tiers:
			if tiers[tk].size() > 4:
				problems.append("%s tier %s offers more than 4" % [did, tk])
			for sid in tiers[tk]:
				var s := DB.get_schematic(sid)
				if s.is_empty():
					problems.append("%s tier %s lists unknown %s" % [did, tk, sid])
				elif str(s.get("discipline")) != did or int(s.get("tier", 0)) != int(tk):
					problems.append("%s tier %s lists %s, which says %s tier %s" % [did, tk, sid, s.get("discipline"), s.get("tier")])
	for eid in DB.enchantments:
		var en: Dictionary = DB.enchantments[eid]
		for key in en.get("essences", {}):
			if not key.begins_with("tag:") and DB.get_item(key).is_empty():
				problems.append("enchant %s: unknown essence %s" % [eid, key])
		var tool := str(en.get("tool", "etching_tools"))
		if not en.get("curse", false) and tool != "" and not tool_tags.has(tool):
			problems.append("enchant %s: no tool provides %s" % [eid, tool])
	for p in problems:
		printerr("    ", p)
	check(problems.is_empty(), "data references resolve (%d items, %d schematics, %d enchantments)" % [DB.items.size(), DB.schematics.size(), DB.enchantments.size()])
	check(DB.get_item("blackwater_hatchet").get("damage") == "1d6" and DB.get_item("blackwater_hatchet").get("name") == "Blackwater Hatchet", "items can extend a base item")


# ---------------------------------------------------------------- crafting

func _crafting() -> void:
	Rules.rng.seed = 99
	GameState.reset()
	var c := FakeCrafter.new()
	c.crafting.points = 2
	check(not Crafting.pick(c, "ballistics", 1, "brass_spring")["ok"], "can't pick before buying the tier")
	check(Crafting.buy_tier(c, "ballistics")["ok"] and SkillHooks.tier(c, "ballistics") == 1, "buy ballistics tier 1 with a trade point")
	check(SkillHooks.picks_left(c, "ballistics", 1) == 2, "a tier gives 2 picks")
	check(Crafting.pick(c, "ballistics", 1, "brass_spring")["ok"], "pick brass spring")
	check(Crafting.pick(c, "ballistics", 1, "ratchet_housing")["ok"], "pick ratchet housing")
	check(not Crafting.pick(c, "ballistics", 1, "rifled_barrel")["ok"], "third pick at a tier is refused")
	check(not Crafting.pick(c, "ballistics", 1, "pressure_valve")["ok"], "can't pick another trade's schematic")
	var packs := [c.inventory]
	check(not Crafting.requirements(c, "brass_spring", packs)["ok"], "no tinker's kit, no brass: can't craft")
	c.inventory.add("tinker_kit")
	c.inventory.add("brass_ingot", 10)
	c.inventory.add("iron_ingot", 5)
	check(Crafting.requirements(c, "brass_spring", packs)["ok"], "kit and brass: can craft")
	var made := 0
	var tries := 0
	while c.inventory.count("brass_spring") < 2 and tries < 20:
		var r := Crafting.craft(c, "brass_spring", packs, 10)
		tries += 1
		check(r["ok"], "craft call resolves")
		if r["entry"] != null:
			made += 1
	check(c.inventory.count("brass_spring") >= 2, "made brass springs (%d tries)" % tries)
	check(GameState.minutes > 8 * 60, "crafting takes time")
	# chain: spring + housing -> trigger needs tier 2
	while c.inventory.count("ratchet_housing") < 1 and c.inventory.count("brass_ingot") > 0:
		Crafting.craft(c, "ratchet_housing", packs, 10)
	c.crafting.learn("clockwork_trigger", "test")
	var req := Crafting.requirements(c, "clockwork_trigger", packs)
	check(not req["ok"] and str(req["problems"]).contains("tier 2"), "known but tier too low: blocked")
	c.crafting.points = 1
	Crafting.buy_tier(c, "ballistics")
	check(Crafting.requirements(c, "clockwork_trigger", packs)["ok"], "tier 2 + parts: trigger craftable")
	# quality bands
	check(Crafting.outcome_for(20, -3) == "masterwork" and Crafting.outcome_for(1, 15) == "botched", "natural 20 / natural 1")
	check(Crafting.outcome_for(10, 12) == "masterwork" and Crafting.outcome_for(10, 6) == "fine" and Crafting.outcome_for(10, 0) == "standard", "margin sets quality")
	check(Crafting.outcome_for(10, -3) == "crude" and Crafting.outcome_for(10, -7) == "failed" and Crafting.outcome_for(10, -10) == "botched", "near misses are crude, bad misses lose parts")
	var s := DB.get_schematic("rifled_barrel")
	check(Crafting.check_bonus(c, s, 0)["total"] > Crafting.check_bonus(c, s, 100)["total"], "Gear crafting is easier at low Resonance")
	var hd := DB.get_schematic("healing_draught")
	check(Crafting.check_bonus(c, hd, 100)["total"] > Crafting.check_bonus(c, hd, 0)["total"], "arcane formulae are easier at high Resonance")
	check(Crafting.chance(5, 10) > Crafting.chance(0, 10) and Crafting.chance(100, 10) == 0.95 and Crafting.chance(-100, 10) == 0.05, "chance respects natural 1 and 20")
	# failures cost parts
	c.inventory.add("brass_ingot", 100)
	var before := c.inventory.count("brass_ingot")
	var lost_any := false
	for i in 80:
		var r := Crafting.craft(c, "brass_spring", packs, 100) # bad Resonance for machines
		if r["outcome"] in ["failed", "botched"] and not r["lost"].is_empty():
			lost_any = true
	check(c.inventory.count("brass_ingot") < before, "crafting consumes inputs")
	check(lost_any, "failed crafts lose parts")
	# party packs
	var c2 := FakeCrafter.new()
	c2.crafting.learn("smelt_iron", "start")
	var follower := Inventory.new()
	follower.add("iron_ore", 2)
	follower.add("coal_lump", 1)
	c2.inventory.add("smith_hammer")
	check(Crafting.requirements(c2, "smelt_iron", [c2.inventory, follower])["ok"], "parts can come from a follower's pack")
	check(DB.get_discipline("smithing").get("tiered") == false and Crafting.requirements(c2, "smelt_iron", [c2.inventory, follower])["ok"], "untiered recipes need no tier")
	# found schematic
	c2.inventory.add("schematic_clockwork_trigger")
	var sheet = c2.inventory.find_first("schematic_clockwork_trigger")
	var lr := Crafting.learn_from_item(c2, sheet)
	check(lr["ok"] and c2.crafting.knows("clockwork_trigger") and c2.inventory.count("schematic_clockwork_trigger") == 0, "reading a found schematic teaches it and uses it up")
	check(lr["msg"].contains("tier 2"), "found schematic warns about the tier needed to build it")
	# patents
	var c3 := FakeCrafter.new()
	c3.crafting.tiers = {"ballistics": 5, "galvanics": 4}
	check(Crafting.unlock_patents(c3).is_empty(), "patent stays locked below 5/5")
	c3.crafting.tiers["galvanics"] = 4
	c3.crafting.points = 1
	var br := Crafting.buy_tier(c3, "galvanics")
	check(br["ok"] and c3.crafting.knows("galvanic_rifle"), "reaching tier 5 in two trades unlocks the patent")
	# character-system adapter
	var sa := FakeSheetActor.new()
	check(SkillHooks.tier(sa, "ballistics") == 2 and SkillHooks.skill_bonus(sa, "mechanics") == 7, "reads tiers and skills from the character sheet")
	check(Crafting.pick(sa, "ballistics", 2, "cap_pistol")["ok"] and sa.sheet["schematics"].has("cap_pistol"), "picks are recorded on the sheet")
	check(Crafting.buy_tier(sa, "ballistics")["ok"] and sa.tier("ballistics") == 3 and sa.cp == 0, "buying a tier spends the sheet's points")
	check(not Crafting.buy_tier(sa, "ballistics")["ok"], "sheet refusal is respected")


# ---------------------------------------------------------------- identification

func _identification() -> void:
	Rules.rng.seed = 4242
	GameState.reset()
	var c := FakeCrafter.new()
	c.inventory.add("frostvein_dagger")
	var dag = c.inventory.find_first("frostvein_dagger")
	var dormant := ItemStats.resolve(dag)
	check(not dormant.has("extra_damage") and not dormant.has("special"), "unidentified powers stay dormant")
	check(DB.entry_name(dag) == "A dagger, cold to the touch", "unidentified name shown")
	dag["identified"] = true
	var awake := ItemStats.resolve(dag)
	check(awake.get("extra_damage", []).size() == 1 and awake.get("special", []).has("slow_on_crit"), "identified: frost damage and slow on crit")
	# spell, with same-day retry lock
	var tried_blocked := false
	var revealed := false
	for i in 30:
		var e = c.inventory.add("blackwater_hatchet")
		var r := Identification.by_spell(c, e, "identify", 90)
		if r["ok"]:
			revealed = e["identified"] and e.get("curse_known", false)
		else:
			var again := Identification.by_spell(c, e, "identify", 90)
			tried_blocked = again["lines"][0].contains("tomorrow")
		if revealed and tried_blocked:
			break
	check(revealed, "identify spell reveals the curse too")
	check(tried_blocked, "a failed spell can't be retried the same day")
	# lens: consumed, can miss curses
	var seen := 0
	var named := 0
	c.inventory.add("assayer_lens", 60)
	for i in 60:
		var e = c.inventory.add("blackwater_hatchet")
		Identification.by_lens(c, e, c.inventory.find_first("assayer_lens"), c.inventory, 10)
		if e["identified"]:
			named += 1
			if e.get("curse_known", false):
				seen += 1
	check(c.inventory.count("assayer_lens") == 0, "lenses are used up")
	check(named > 20 and seen < named, "lens names items but misses some curses (%d named, %d curses seen)" % [named, seen])
	var lb_hi := Identification.lens_bonus(c, DB.get_item("assayer_lens"), 90)
	var lb_lo := Identification.lens_bonus(c, DB.get_item("assayer_lens"), 10)
	check(lb_lo > lb_hi, "lenses read better at low Resonance")
	# appraisers
	var payer := FakeCrafter.new()
	payer.inventory.add("coin", 1000)
	var hesta := FakeCrafter.new()
	hesta.display_name = "Hesta"
	hesta.template_id = "hesta_lowe"
	var wendle := FakeCrafter.new()
	wendle.display_name = "Wendle"
	wendle.template_id = "wendle_cobb"
	var e1 = payer.inventory.add("blackwater_hatchet")
	var r1 := Identification.by_appraiser(hesta, payer, e1)
	check(r1["ok"] and e1["identified"] and e1.get("curse_known", false) and payer.inventory.count("coin") < 1000, "honest priest-appraiser names it and the curse, for a fee")
	var wendle_told := 0
	for i in 20:
		var e2 = payer.inventory.add("blackwater_hatchet")
		Identification.by_appraiser(wendle, payer, e2)
		if e2.get("curse_known", false):
			wendle_told += 1
	check(wendle_told == 0, "a gauge-and-lens appraiser never spots curses")
	# equip and find out
	var actor := Actor.new()
	actor.apply_template(DB.get_actor_template("player"))
	var hatchet = actor.inventory.add("blackwater_hatchet")
	actor.equip_entry(hatchet)
	check(hatchet.get("curse_known", false), "equipping wakes the curse")
	check(int(actor.weapon_data().get("to_hit", 0)) == -2, "curse applies even while unidentified")
	check(not actor.equip_entry(actor.inventory.find_first("fen_hookblade")) and hatchet["equipped"], "sticky curse won't let go")
	var learned := false
	for i in 4:
		learned = not Identification.on_hit(actor, hatchet).is_empty()
	check(learned and hatchet["identified"], "fighting with it identifies it after a few hits")
	Identification.lift_curse(hatchet)
	actor.refresh_stats()
	check(actor.equip_entry(actor.inventory.find_first("fen_hookblade")), "lifting the curse frees the hand")
	check(not ItemStats.resolve(hatchet).has("to_hit") and ItemStats.resolve(hatchet).get("extra_damage", []).size() == 1, "lifted curse is gone, the enchantment stays")
	# loot keeps instance data
	var loot := Inventory.new()
	loot.add_entry(hatchet)
	check(loot.entries[0].get("curse") == "" and loot.entries[0]["identified"], "moving an item keeps its state")
	actor.free()


# ---------------------------------------------------------------- enchanting

func _enchanting() -> void:
	Rules.rng.seed = 777
	GameState.reset()
	var c := FakeCrafter.new()
	c.stats["int"] = 18
	c.crafting.tiers = {"enchanting": 1}
	c.crafting.learn("ench_frost_edge", "pick")
	c.crafting.learn("ench_warding", "pick")
	c.inventory.add("etching_stylus")
	c.inventory.add("frost_essence", 60)
	c.inventory.add("ward_essence", 20)
	var packs := [c.inventory]
	var dag = c.inventory.add("iron_dagger", 1, true, {"quality": "standard"})
	check(ItemStats.enchant_slots(dag) == 1, "standard quality: 1 slot")
	var crude = c.inventory.add("iron_dagger", 1, true, {"quality": "crude"})
	check(not Enchanting.requirements(c, crude, "frost_edge", packs)["ok"], "crude items take no enchantments")
	var mw = c.inventory.add("iron_dagger", 1, true, {"quality": "masterwork"})
	check(ItemStats.enchant_slots(mw) == 3, "masterwork: 3 slots")
	check(ItemStats.enchant_slots({"id": "starglass_staff"}) == 2, "starglass adds a slot")
	var unknown = c.inventory.add("emberglass_knife")
	check(not Enchanting.requirements(c, unknown, "frost_edge", packs)["ok"], "can't enchant an unidentified item")
	var ok := false
	for i in 20:
		var r := Enchanting.enchant(c, dag, "frost_edge", packs, 90)
		if r["outcome"] == "success":
			ok = true
			break
		if r["outcome"] == "botched":
			dag = c.inventory.add("iron_dagger", 1, true, {"quality": "standard"})
	check(ok and dag.get("enchants", []).has("frost_edge"), "frost edge binds onto a dagger")
	check(ItemStats.resolve(dag).get("extra_damage", []).size() == 1 and DB.entry_name(dag).contains("frost"), "enchanted dagger deals frost damage and says so")
	check(not Enchanting.requirements(c, dag, "warding", packs)["ok"], "a full item takes no more")
	check(Enchanting.dc(mw, DB.get_enchantment("frost_edge")) == 12, "base DC")
	mw["enchants"] = ["warding"]
	check(Enchanting.dc(mw, DB.get_enchantment("frost_edge")) == 14, "each existing enchantment raises the DC")
	var bh: int = Enchanting.check_bonus(c, DB.get_enchantment("frost_edge"), 90)["total"]
	var bl: int = Enchanting.check_bonus(c, DB.get_enchantment("frost_edge"), 10)["total"]
	check(bh > bl, "enchanting is easier at high Resonance")
	# machines resist
	var gun = c.inventory.add("repeating_carbine", 1, true, {"quality": "fine"})
	var base_mf := float(ItemStats.resolve(gun)["misfire"])
	gun["enchants"] = ["frost_edge"]
	check(float(ItemStats.resolve(gun)["misfire"]) > base_mf, "an enchanted machine misfires more")
	check(Enchanting.quirk_chance(gun) > 0.0 and Enchanting.quirk_chance(dag) == 0.0, "only machines risk quirks")
	var fine_mf := float(ItemStats.resolve({"id": "repeating_carbine", "quality": "fine"})["misfire"])
	var crude_mf := float(ItemStats.resolve({"id": "repeating_carbine", "quality": "crude"})["misfire"])
	check(fine_mf < crude_mf, "fine guns misfire less than crude ones")
	# combat reads it
	var ex := Rules.extra_multiplier("gear", 0, 0) > Rules.extra_multiplier("gear", 100, 0)
	check(ex, "galvanic shocks hit harder where Resonance is low")
	var a := FakeCrafter.new()
	var tgt := FakeCrafter.new()
	tgt.ac = 1
	var total_plain := 0
	var total_frost := 0
	var plain := ItemStats.resolve({"id": "iron_dagger"})
	var frosty := ItemStats.resolve(dag)
	for i in 300:
		total_plain += Rules.resolve_attack(a, tgt, Rules.attack_profile(plain, false), 80)["damage"]
		total_frost += Rules.resolve_attack(a, tgt, Rules.attack_profile(frosty, false), 80)["damage"]
	check(total_frost > total_plain * 1.5, "combat uses enchantment damage (%d vs %d)" % [total_frost, total_plain])
