extends Node
## Unit tests for the rules, inventory and dialogue layers.
## Run: godot --headless res://tests/test_runner.tscn

var checks := 0
var failures := 0


func check(cond: bool, msg: String) -> void:
	checks += 1
	if cond:
		print("  ok   ", msg)
	else:
		failures += 1
		printerr("  FAIL ", msg)


class FakeActor:
	var display_name := "Tester"
	var stats := {"str": 14, "dex": 14, "con": 10, "int": 16, "wis": 12, "cha": 10}
	var aptitude := 0
	var ac := 12


func _ready() -> void:
	Rules.rng.seed = 12345
	print("Rules")
	for i in 200:
		var r := Rules.roll_dice("2d6+1")
		if r < 3 or r > 13:
			check(false, "2d6+1 out of range: %d" % r)
			break
	check(true, "2d6+1 stays in 3..13")
	check(Rules.dice_average("3d8") == 13.5, "3d8 averages 13.5")
	check(Rules.parse_dice("1d4-1") == Vector3i(1, 4, -1), "parses negative bonus")
	check(Rules.mod(14) == 2 and Rules.mod(9) == -1, "ability modifiers")
	check(Rules.ft_to_tiles(90) == 18 and Rules.ft_to_tiles(5) == 1, "feet to tiles")
	check(Rules.misfire_chance(0.03, 72, 0) > Rules.misfire_chance(0.03, 18, 0), "guns jam more at high Resonance")
	check(Rules.misfire_chance(0.03, 50, 60) > Rules.misfire_chance(0.03, 50, -60), "arcane-leaning users jam guns more")
	check(Rules.magic_multiplier("arcane", 80, 0) > 1.2 and Rules.magic_multiplier("arcane", 10, 0) < 0.6, "arcane follows Resonance")
	var swing_arcane := Rules.magic_multiplier("arcane", 100, 0) - Rules.magic_multiplier("arcane", 0, 0)
	var swing_divine := Rules.magic_multiplier("divine", 100, 0) - Rules.magic_multiplier("divine", 0, 0)
	check(swing_divine < swing_arcane, "divine swings less with Resonance than arcane")
	var alt := Rules.attack_profile(DB.get_item("boiler_lance"), true)
	check(alt["damage"] == "3d8" and int(alt["ap"]) == 6 and alt.has("burst_damage"), "boiler lance alt profile merges")

	var a := FakeActor.new()
	var t := FakeActor.new()
	var hits := 0
	var misfires := 0
	var carbine := Rules.attack_profile(DB.get_item("repeating_carbine"), false)
	for i in 400:
		var r := Rules.resolve_attack(a, t, carbine, 100)
		if r["misfire"]:
			misfires += 1
		elif r["hit"]:
			hits += 1
			if r["damage"] < 1:
				check(false, "damage must be >= 1")
	check(misfires > 80, "carbine misfires often at Resonance 100 (%d/400)" % misfires)
	misfires = 0
	for i in 400:
		if Rules.resolve_attack(a, t, carbine, 0)["misfire"]:
			misfires += 1
	check(misfires < 30, "carbine rarely misfires at Resonance 0 (%d/400)" % misfires)
	var bolt: Dictionary = DB.get_skill("arcane_bolt")
	var hi := 0
	var lo := 0
	for i in 300:
		hi += Rules.resolve_spell(a, t, bolt, 90, 0)["damage"]
		lo += Rules.resolve_spell(a, t, bolt, 10, 0)["damage"]
	check(hi > lo * 1.8, "arcane bolt much stronger at high Resonance (%d vs %d)" % [hi, lo])

	print("Inventory")
	var inv := Inventory.new()
	inv.add("healing_draught", 2)
	inv.add("healing_draught", 1)
	check(inv.count("healing_draught") == 3 and inv.entries.size() == 1, "stackables stack")
	inv.add("frostvein_dagger")
	var dag = inv.find_first("frostvein_dagger")
	check(dag != null and dag["identified"] == false, "magic dagger starts unidentified")
	check(DB.entry_name(dag) == "A dagger, cold to the touch", "unidentified name shown")
	var other := Inventory.new()
	inv.transfer(dag, other)
	check(other.count("frostvein_dagger") == 1 and inv.count("frostvein_dagger") == 0, "transfer between packs")
	check(other.find_first("frostvein_dagger")["identified"] == false, "transfer keeps identified state")
	inv.remove_one(inv.find_first("healing_draught"))
	check(inv.count("healing_draught") == 2, "remove one from stack")

	print("Dialogue")
	GameState.reset()
	GameState.set_locations([{"id": "pumphouse_yard", "name": "Yard", "rect": [0, 0, 5, 5], "resonance": 18}])
	var warden: Dictionary = DB.get_dialogue("warden")
	check(DialogueRunner.entry_node(warden) == "intro", "warden opens with intro")
	GameState.set_flag("quest_pump", "active")
	check(DialogueRunner.entry_node(warden) == "waiting", "warden waits while quest active")
	GameState.set_flag("quest_pump", "cleared")
	check(DialogueRunner.entry_node(warden) == "report", "warden reports when cleared")
	var opt: Dictionary = warden["nodes"]["report"]["options"][1]
	var receiver := {"inventory": Inventory.new()}
	DialogueRunner.apply_effects(opt["effects"], receiver)
	check(GameState.resonance_at(Vector2i(1, 1)) == 38, "leaving the boiler cold raises yard Resonance 18 -> 38")
	check(receiver["inventory"].count("healing_draught") == 2, "quest reward given")
	check(DialogueRunner.entry_node(warden) == "after_cold", "warden remembers the choice")

	_character_tests()

	print("\n%d checks, %d failures" % [checks, failures])
	get_tree().quit(1 if failures > 0 else 0)


func _character_tests() -> void:
	print("Character data")
	check(DB.abilities.size() >= 250, "hundreds of abilities generated (%d)" % DB.abilities.size())
	check(DB.char_skills.size() >= 40, "core skills (%d)" % DB.char_skills.size())
	var bad: PackedStringArray = []
	for id in DB.abilities:
		var ab: Dictionary = DB.abilities[id]
		if not DB.disciplines.has(str(ab.get("discipline", ""))):
			bad.append(id + ": discipline")
		for e in ab.get("effects", []):
			if e.get("type") == "status" and not DB.statuses.has(str(e.get("status", ""))):
				bad.append(id + ": status " + str(e.get("status")))
		if ab.has("summon") and DB.get_actor_template(str(ab["summon"])).is_empty():
			bad.append(id + ": summon")
		for k in ["damage", "heal", "extra_damage"]:
			if ab.has(k) and Rules.parse_dice(str(ab[k])).y <= 0:
				bad.append(id + ": dice " + k)
	for r in DB.races:
		for t in DB.races[r].get("traits", []):
			if not DB.traits.has(t):
				bad.append("race %s: trait %s" % [r, t])
		for h in DB.races[r].get("heritages", {}):
			for t in DB.races[r]["heritages"][h].get("traits", []):
				if not DB.traits.has(t):
					bad.append("heritage %s: trait %s" % [h, t])
	for b in DB.backgrounds:
		for t in DB.backgrounds[b].get("traits", []):
			if not DB.traits.has(t):
				bad.append("background %s: trait %s" % [b, t])
		for sk in DB.backgrounds[b].get("start_skill_ranks", {}):
			if not DB.char_skills.has(sk):
				bad.append("background %s: skill %s" % [b, sk])
	for arch in DB.archetypes:
		for sk in DB.archetypes[arch].get("skills", []):
			if not DB.char_skills.has(sk):
				bad.append("archetype %s: skill %s" % [arch, sk])
		for d in DB.archetypes[arch].get("disciplines", []):
			if not DB.disciplines.has(d):
				bad.append("archetype %s: discipline %s" % [arch, d])
	for d in DB.disciplines:
		for sk in CharacterSheet.governing_skills(DB.disciplines[d]):
			if not DB.char_skills.has(sk):
				bad.append("discipline %s: skill %s" % [d, sk])
	for it in DB.items:
		if DB.items[it].get("type") == "weapon" and not DB.char_skills.has(DB.weapon_skill(DB.items[it])):
			bad.append("item %s: weapon skill" % it)
	check(bad.is_empty(), "all character data cross-references resolve %s" % (str(bad) if not bad.is_empty() else ""))
	check(DB.get_skill("arcane_bolt").get("damage") == "2d6", "prototype spell ids kept (arcane_bolt)")

	print("Character sheet")
	var s := CharacterSheet.new()
	s.race = "dwarf"
	s.base_stats = {"str": 14, "dex": 10, "con": 14, "int": 10, "wis": 12, "cha": 8}
	check(s.stat("str") == 16 and s.stat("dex") == 9, "race modifiers apply (dwarf STR 14+2, DEX 10-1)")
	check(s.max_hp() == 12 + 16, "level 1 HP = race base + CON (12 + 16)")
	check(s.proficiency() == 2, "proficiency +2 at level 1")
	check(s.skill_bonus("blades") == 3, "untrained skill = stat mod only")
	s.cp = 10
	check(s.buy("skill", "blades") and s.skill_rank("blades") == 1, "buy a skill rank")
	check(s.skill_bonus("blades") == 3 + 2, "trained skill adds proficiency")
	check(not s.can_buy("skill", "blades")["ok"], "rank 2 gated by level")
	check(s.can_buy("skill", "blades")["reason"].contains("level"), "gate explains itself")
	check(not s.can_buy("tier", "evocation")["ok"], "tier needs its governing skill")
	s.buy("skill", "arcana")
	check(not s.can_buy("tier", "evocation")["ok"] and s.can_buy("tier", "evocation")["reason"].contains("INT"), "tier needs the key stat")
	check(s.buy("tier", "heavy_arms") == false, "heavy arms needs blunt or polearms")
	s.buy("skill", "blunt")
	check(s.buy("tier", "heavy_arms") and s.has_ability("crushing_blow") and s.has_ability("brace"), "a tier grants both its abilities")
	check(s.cp == 10 - 4, "CP spent correctly")
	var hp_before := s.max_hp()
	var lv := s.add_xp(CharacterSheet.xp_to_reach(5))
	check(lv == 4 and s.level == 5, "XP levels up (to 5)")
	check(s.cp == 6 + 4 + 1, "1 CP per level, +1 bonus at level 5")
	check(s.max_hp() > hp_before, "HP grows with level")
	check(s.proficiency() == 2 and CharacterSheet.xp_to_reach(9) == 18000, "proficiency and XP table")

	print("Aptitude")
	var mage := CharacterSheet.new()
	mage.race = "human"
	mage.heritage = "lowlander"
	mage.base_stats["int"] = 16
	mage.cp = 20
	mage.buy("skill", "arcana")
	mage.buy("tier", "evocation")
	var gun := CharacterSheet.new()
	gun.race = "human"
	gun.heritage = "lowlander"
	gun.base_stats["dex"] = 16
	gun.cp = 20
	gun.buy("skill", "firearms")
	gun.buy("skill", "gunsmithing")
	gun.buy("tier", "ballistics")
	check(mage.aptitude() > 20, "arcane spending leans Arcane (%+d)" % mage.aptitude())
	check(gun.aptitude() < -20, "gear spending leans Gear (%+d)" % gun.aptitude())
	var w := CharacterSheet.new()
	w.race = "wrought"
	w.cp = 5
	check(w.aptitude() == -100, "Wrought are pure Gear")
	check(not w.can_buy("skill", "arcana")["ok"] and not w.can_buy("tier", "lantern")["ok"], "Wrought can't learn magic")
	check(w.has_flag("heal_immune"), "Wrought only take repairs")
	mage.level = 15
	mage.base_stats["int"] = 18
	mage.skill_ranks["arcana"] = 3
	mage.tiers["evocation"] = 3
	mage.skill_ranks["blades"] = 5
	mage.skill_ranks["athletics"] = 5
	mage.skill_ranks["firearms"] = 5
	mage.cp = 5
	mage.invalidate()
	check(not mage.can_buy("tier", "evocation")["ok"] and mage.can_buy("tier", "evocation")["reason"].contains("aptitude"), "tier 4 magic needs a strong Arcane lean (%+d)" % mage.aptitude())

	print("Save and load")
	var d := s.to_dict()
	var s2 := CharacterSheet.from_dict(JSON.parse_string(JSON.stringify(d)))
	check(JSON.stringify(s2.to_dict()) == JSON.stringify(s.to_dict()), "sheet survives a JSON round trip")
	check(s2.max_hp() == s.max_hp() and s2.ac() == s.ac(), "derived numbers match after load")
	var g := CharacterSheet.new()
	g.race = "gnome"
	g.base_stats["int"] = 14
	g.cp = 5
	g.skill_ranks["mechanics"] = 1
	check(g.buy("tier", "automata") and g.schematic_picks_left("automata") == 3, "gnomes get an extra schematic pick per tier (3)")
	check(g.pick_schematic("automata", "spring_turret_mk1") and g.schematic_picks_left("automata") == 2, "picking a schematic uses a pick")

	print("Generator")
	var a1 := CharacterGen.generate({"archetype": "mage", "level": 8, "race": "elf", "seed": 42})
	var a2 := CharacterGen.generate({"archetype": "mage", "level": 8, "race": "elf", "seed": 42})
	check(a1.to_dict() == a2.to_dict(), "same seed, same character")
	check(a1.cp == 0 and a1.level == 8, "generator spends every CP it can")
	check(a1.tier("evocation") > 0 and a1.aptitude() > 30, "mage archetype learns spells and leans Arcane (%+d)" % a1.aptitude())
	var e1 := CharacterGen.generate({"archetype": "engineer", "level": 8, "race": "gnome", "seed": 7})
	check(e1.aptitude() < -40, "gnome engineer leans Gear (%+d)" % e1.aptitude())
	var fresh := CharacterGen.generate({"archetype": "soldier", "level": 1, "race": "orc", "seed": 9})
	check(CharacterSheet.creation_cost(fresh.base_stats) <= 20, "generated stats respect the point-buy")
	var t0 := Time.get_ticks_msec()
	var n := 0
	var rng := RandomNumberGenerator.new()
	var arches := DB.archetypes.keys()
	var races := DB.races.keys()
	for i in 500:
		rng.seed = i
		var c := CharacterGen.generate({"archetype": arches[i % arches.size()], "level": 1 + i % 12, "race": races[i % races.size()], "seed": i})
		if c.max_hp() > 0 and c.level == 1 + i % 12 and c.cp <= 2:
			n += 1
	var ms := Time.get_ticks_msec() - t0
	check(n == 500, "500 mixed residents generated cleanly")
	print("       (500 characters in %d ms, about %.1f s for 25,000)" % [ms, ms * 50 / 1000.0])
	rng.seed = 3
	var nm := NameGen.make("dwarf", "f", rng)
	check(nm.split(" ").size() == 2, "names have a given and family name (%s)" % nm)

	print("Abilities in combat rules")
	var caster := FakeActor.new()
	var foe := FakeActor.new()
	var fireball: Dictionary = DB.get_ability("fireball")
	var total := 0
	for i in 100:
		var r := AbilityRules.resolve(caster, foe, fireball, 50, 0)
		total += r["damage"]
	check(total > 0 and fireball.has("area"), "area spells use a DEX save for half")
	var daze: Dictionary = DB.get_ability("daze")
	var stunned := 0
	for i in 200:
		if not AbilityRules.resolve(caster, foe, daze, 50, 0)["statuses"].is_empty():
			stunned += 1
	check(stunned > 40 and stunned < 190, "control spells allow a save (%d/200 stunned)" % stunned)
	var aimed := AbilityRules.technique_profile(DB.get_item("repeating_carbine"), DB.get_ability("aimed_shot"))
	check(int(aimed["ap"]) == 5 and int(aimed["to_hit"]) == 3, "weapon technique modifies the equipped weapon")
	check(AbilityRules.technique_blocker(DB.get_item("fen_hookblade"), DB.get_ability("aimed_shot")) != "", "gun techniques need a gun")
	var heal_ab: Dictionary = DB.get_ability("mend_wounds")
	check(AbilityRules.resolve(caster, foe, heal_ab, 50, 0)["heal"] > 0, "healing prayer heals")
