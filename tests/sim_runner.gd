extends Node
## Plays the pumphouse fight with the AI driving the whole party.
## Run: godot --headless res://tests/sim_runner.tscn -- --mode=tb|rt|toggle --seed=N
## Exits 0 if the fight resolved (win or loss) without hanging.
## --arena adds generated level-8 casters, engineers and summoners to both
## sides, to exercise every kind of ability in a real fight.

var mode := "tb"
var seed_value := 1
var scale := 8.0
var arena := false


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--mode="):
			mode = arg.substr(7)
		elif arg.begins_with("--scale="):
			scale = float(arg.substr(8))
		elif arg.begins_with("--seed="):
			seed_value = int(arg.substr(7))
		elif arg == "--arena":
			arena = true
	Rules.rng.seed = seed_value
	GameState.preferred_mode = GameState.REAL_TIME if mode == "rt" else GameState.TURN_BASED
	var main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	var world = main.world
	var combat = main.combat
	combat.mode = GameState.preferred_mode
	var player = world.player
	player.ai_controlled = true
	var iska = null
	for a in world.actors:
		if a.template_id == "iska":
			iska = a
	player.set_tile_immediate(Vector2i(22, 11))
	iska.set_tile_immediate(Vector2i(21, 11))
	if arena:
		_build_arena(world, player, iska)
	Engine.time_scale = scale
	var t := 0.0
	var started := false
	var toggles := 0
	while t < 900.0:
		await get_tree().create_timer(0.5).timeout
		t += 0.5
		if combat.active:
			started = true
			if mode == "toggle" and fmod(t, 4.0) < 0.01:
				combat.toggle_mode()
				toggles += 1
		elif started:
			break
	Engine.time_scale = 1.0
	var victory: bool = started and not combat.active and not player.is_dead
	print("SIM mode=%s seed=%d started=%s finished=%s victory=%s game_time=%.0fs toggles=%d player_hp=%d iska_hp=%d quest=%s" % [
		mode, seed_value, started, started and not combat.active, victory, t, toggles, player.hp, iska.hp,
		GameState.get_flag("quest_pump", "")])
	if victory:
		var lens = player.inventory.find_first("assayer_lens")
		await combat.do_use_item(player, lens)
		var dag = player.inventory.find_first("frostvein_dagger")
		print("SIM dagger identified=%s" % (dag != null and dag["identified"]))
	get_tree().quit(0 if started and not combat.active else 1)


func _build_arena(world, player, iska) -> void:
	player.add_xp(CharacterSheet.xp_to_reach(8))
	iska.add_xp(CharacterSheet.xp_to_reach(8))
	var allies := [["priest", "dwarf"], ["engineer", "gnome"], ["necromancer", "elf"]]
	var foes := [["mage", "elf"], ["sapper", "orc"], ["storm_priest", "human"], ["soldier", "orc"], ["necromancer", "human"]]
	var i := 0
	for spec in allies + foes:
		var hostile: bool = foes.has(spec)
		var id := "arena_%d" % i
		DB.actor_templates[id] = {"id": id, "faction": "hostile" if hostile else "ally", "group": "pump_scavs" if hostile else "",
			"aggro": 7 if hostile else 0, "color": "#c05050" if hostile else "#50c080",
			"gen": {"archetype": spec[0], "level": 8, "race": spec[1], "seed": seed_value * 100 + i}}
		var tile := Vector2i(30 + i % 3, 8 + i) if hostile else Vector2i(20, 9 + i)
		var a = world.spawn(id, tile)
		print("ARENA %s: %s L%d %s, abilities %s" % ["foe" if hostile else "ally", a.display_name, a.sheet.level, spec[0], a.known_skills])
		i += 1
