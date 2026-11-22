extends Node
## Captures screenshots for docs. Needs a real display (or xvfb-run):
## godot res://tests/screenshot.tscn -- --out=/path/dir

var out_dir := "user://"


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out_dir = arg.substr(6)
	Rules.rng.seed = 7
	var main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await _wait(1.5)
	_save("01_town.png")
	main.hud.open_dialogue(_find(main.world, "osk_brannel"))
	await _wait(0.5)
	_save("02_dialogue.png")
	main.hud.close_panels()
	main.hud.toggle_inventory()
	await _wait(0.5)
	_save("03_inventory.png")
	main.hud.toggle_inventory()
	var p = main.world.player
	p.set_tile_immediate(Vector2i(22, 12))
	_find(main.world, "iska").set_tile_immediate(Vector2i(21, 13))
	main.rig.snap()
	await _wait(2.5)
	_save("04_combat_turn_based.png")
	main.combat.toggle_mode()
	p.ai_controlled = true
	await _wait(2.0)
	_save("05_combat_real_time.png")
	get_tree().quit()


func _find(world, id: String):
	for a in world.actors:
		if a.template_id == id:
			return a
	return null


func _wait(s: float) -> void:
	await get_tree().create_timer(s).timeout
	await RenderingServer.frame_post_draw


func _save(name: String) -> void:
	var img := get_viewport().get_texture().get_image()
	img.save_png(out_dir.path_join(name))
	print("saved ", name)
