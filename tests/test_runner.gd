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

	await _test_art_pipeline()

	print("\n%d checks, %d failures" % [checks, failures])
	get_tree().quit(1 if failures > 0 else 0)


## Uses the reference models in tests/fixtures/assets, which
## tools/blender/make_test_fixtures.py builds through the Blender add-on.
func _test_art_pipeline() -> void:
	print("Art pipeline")
	Models.root = "res://tests/fixtures/assets"
	Models.reload()
	var spec := Models.character_spec({"id": "mannequin", "race": "human"})
	check(spec.get("path", "") == "res://tests/fixtures/assets/characters/mannequin/mannequin.glb", "finds a character by folder convention")
	check(Models.character_spec({"id": "osk_brannel", "race": "dwarf"}).is_empty(), "no model means placeholder")
	check(Models.character_spec({"id": "someone", "model": "mannequin"}).has("path"), "template 'model' key picks another model")
	Models.registry["race_defaults"] = {"elf": ["mannequin"]}
	check(Models.character_spec({"id": "random_elf", "race": "elf"}).has("path"), "race default covers generated residents")
	check(Models.structure_spec({"kind": "house", "rect": [0, 0, 4, 3]}).has("path"), "structure found by kind and size")
	check(Models.structure_spec({"kind": "house", "rect": [0, 0, 4, 4]}).is_empty(), "other house size falls back to placeholder")
	Models.registry["structures"] = {"house": {"path": "res://tests/fixtures/assets/structures/house_4x3/house_4x3.glb"}}
	check(Models.structure_spec({"kind": "house", "rect": [0, 0, 4, 4]}).has("path"), "models.json entry covers a whole kind")
	Models.registry["characters"] = {"broken": {"path": "res://assets/characters/nope.glb"}}
	check(Models.character_spec({"id": "broken"}).is_empty(), "missing file in models.json falls back, no crash")

	var a := Actor.new()
	add_child(a)
	a.apply_template({"id": "mannequin", "name": "Mannequin", "race": "human",
		"inventory": [{"id": "fen_hookblade"}, {"id": "repeating_carbine"}], "equip": "fen_hookblade"})
	await get_tree().process_frame
	await get_tree().process_frame
	check(a.has_model(), "actor uses the custom model")
	check(absf(a._height - 1.73) < 0.05, "model height measured (%.2f m)" % a._height)
	var box := Models.bounds(a._model, a)
	check(absf(box.position.y) < 0.02, "feet on the ground (%.3f)" % box.position.y)
	check(a._anim.clip_for("idle") != "" and a._anim.clip_for("walk") != "", "idle and walk clips found")
	check(a._anim.clip_for("death") != "", "'Armature|death' clip matched to death")
	check(a._anim.clip_for("cast") == a._anim.clip_for("attack_melee"), "missing cast falls back to attack")
	check(a._anim.player.get_animation(a._anim.clip_for("walk")).loop_mode == Animation.LOOP_LINEAR, "walk loops")
	check(a._hand != null and a._hand.name == "socket_hand_r", "weapon socket found")
	var hand_local: Vector3 = a.global_transform.affine_inverse() * a._hand.global_position
	check(hand_local.x > 0.2, "model turned to face -Z: right hand on the +X side (%.2f)" % hand_local.x)
	check(a._weapon_model != null and a._weapon_model.get_parent() == a._hand, "weapon model in the hand")
	check(not a._weapon_mesh.visible, "placeholder weapon hidden")
	a.equip_entry(a.inventory.find_first("repeating_carbine"))
	check(a._weapon_model == null and a._weapon_mesh.visible, "item without a model uses the placeholder stick")
	a.queue_free()

	var p := Actor.new()
	add_child(p)
	p.apply_template({"id": "osk_brannel", "name": "Osk", "race": "dwarf"})
	check(not p.has_model() and p._visual.get_child_count() >= 3, "no model: placeholder body built")
	p.queue_free()

	var v = preload("res://tools/art/art_validator.gd").new()
	var res: Dictionary = v.validate_all("res://tests/fixtures/assets")
	check(res["models"] == 3 and res["errors"] == 0 and res["warnings"] == 0, "fixtures pass the validator (%d errors, %d warnings)" % [res["errors"], res["warnings"]])
	if res["warnings"] > 0:
		print("\n".join(res["lines"]))

	Models.root = "res://assets"
	Models.reload()
