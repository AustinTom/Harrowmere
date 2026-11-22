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

	var ct = preload("res://tests/crafting_tests.gd").new()
	ct.t = self
	ct.run()

	print("\n%d checks, %d failures" % [checks, failures])
	get_tree().quit(1 if failures > 0 else 0)
