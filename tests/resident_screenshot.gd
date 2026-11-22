extends Node
## Screenshots of generated residents in Fennick's Landing for the docs.
## xvfb-run godot --rendering-driver opengl3 res://tests/resident_screenshot.tscn -- --out=/path/dir

var out_dir := "user://"


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out_dir = arg.substr(6)
	Rules.rng.seed = 7
	var main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	var world = main.world
	GameState.minutes = 11 * 60.0
	await _wait(6.0)
	main.rig.snap()
	await _wait(0.5)
	_save("06_residents_midday.png")
	var pres = world.presence
	var pick = null
	for id in pres.spawned:
		var r: Dictionary = Residents.resident(id)
		if r["job"] != "" and Rules.tile_distance(pres.spawned[id].tile, world.player.tile) < 8:
			pick = pres.spawned[id]
			break
	if pick == null and not pres.spawned.is_empty():
		pick = pres.spawned.values()[0]
	if pick != null:
		main.hud.open_dialogue(pick)
		await _wait(0.4)
		_save("07_resident_dialogue.png")
		main.hud._show_node("job")
		await _wait(0.4)
		_save("08_resident_job.png")
		main.hud.close_dialogue()
	GameState.minutes = 19 * 60.0 + 30
	await _wait(7.0)
	_save("09_residents_evening.png")
	print("visible residents: ", pres.spawned.size())
	get_tree().quit()


func _wait(s: float) -> void:
	await get_tree().create_timer(s).timeout
	await RenderingServer.frame_post_draw


func _save(name: String) -> void:
	var img := get_viewport().get_texture().get_image()
	img.save_png(out_dir.path_join(name))
	print("saved ", name)
