extends Node3D
## Look at your models exactly as the game shows them: same isometric camera,
## same sun and ambient light, on a tile grid, next to the placeholder body
## for scale. Open res://tools/art/model_viewer.tscn and press F6.
##
##   Left / Right   previous / next model
##   Up / Down      previous / next animation
##   Q / E          turn the model 45 degrees (the red arrow is "forward")
##   Mouse wheel    zoom
##   G              toggle the placeholder body beside it
##
## Command line: godot res://tools/art/model_viewer.tscn -- --root=res://tests/fixtures/assets --model=mannequin
## Add --shot=/path/out.png to save a screenshot and quit.

const Registry := preload("res://scripts/core/models.gd")
const Validator := preload("res://tools/art/art_validator.gd")

var root := "res://assets"
var entries: Array = [] # {kind, id, path}
var index := 0
var anim_index := 0
var turn := -135.0 # face the camera; the red arrow shows forward

var _rig
var _stage: Node3D
var _model: Node3D
var _player: AnimationPlayer
var _anims: PackedStringArray = []
var _placeholder: Node3D
var _label: Label


func _ready() -> void:
	var want := ""
	var shot := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shot="):
			shot = arg.substr(7)
		if arg.begins_with("--root="):
			root = arg.substr(7)
		elif arg.begins_with("--model="):
			want = arg.substr(8)
	Models.root = root
	Models.reload()
	_build_scene()
	var v := Validator.new()
	for p in v._scan(root):
		var rel := str(p).substr(root.length() + 1)
		var kind := rel.get_slice("/", 0)
		var id := rel.substr(kind.length() + 1).get_basename()
		if id.get_file() == id.get_base_dir().get_file():
			id = id.get_base_dir()
		entries.append({"kind": kind, "id": id, "path": p})
		if id == want:
			index = entries.size() - 1
	_show()
	if shot != "":
		await get_tree().create_timer(0.8).timeout
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(shot)
		get_tree().quit()


func _build_scene() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -30, 0)
	sun.shadow_enabled = true
	sun.light_energy = 0.85
	sun.light_color = Color("#fff1dc")
	add_child(sun)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("#1b2129")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("#a9bdd1")
	env.ambient_light_energy = 0.4
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	# 9 x 9 tile checkerboard; tile (0,0) is centred on the origin like the game's tiles.
	for x in range(-4, 5):
		for z in range(-4, 5):
			var t := MeshInstance3D.new()
			var pm := PlaneMesh.new()
			pm.size = Vector2(0.98, 0.98)
			t.mesh = pm
			t.position = Vector3(x, 0, z)
			var m := StandardMaterial3D.new()
			m.albedo_color = Color("#5c7a66") if (x + z) % 2 == 0 else Color("#526e5c")
			t.material_override = m
			add_child(t)
	_stage = Node3D.new()
	add_child(_stage)
	# Forward arrow: actors face -Z when they walk.
	var arrow := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.06, 0.02, 0.6)
	arrow.mesh = bm
	arrow.position = Vector3(0, 0.02, -0.55)
	var am := StandardMaterial3D.new()
	am.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	am.albedo_color = Color("#ff4d4d")
	arrow.material_override = am
	_stage.add_child(arrow)
	# Placeholder body for scale, one tile to the left.
	_placeholder = Node3D.new()
	_placeholder.position = Vector3(-1.5, 0, 0)
	var cap := MeshInstance3D.new()
	var cm := CapsuleMesh.new()
	cm.radius = 0.28
	cm.height = 1.3
	cap.mesh = cm
	cap.position.y = 0.65
	var pmat := StandardMaterial3D.new()
	pmat.albedo_color = Color(0.6, 0.6, 0.65, 0.5)
	pmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	cap.material_override = pmat
	_placeholder.add_child(cap)
	var head := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.2
	sm.height = 0.4
	head.mesh = sm
	head.position.y = 1.48
	head.material_override = pmat
	_placeholder.add_child(head)
	add_child(_placeholder)
	_rig = preload("res://scripts/world/camera_rig.gd").new()
	_rig.zoom = 8.0
	add_child(_rig)
	var ui := CanvasLayer.new()
	add_child(ui)
	_label = Label.new()
	_label.position = Vector2(16, 12)
	_label.add_theme_font_size_override("font_size", 18)
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 6)
	ui.add_child(_label)


func _show() -> void:
	if _model != null:
		_model.queue_free()
		_model = null
	_player = null
	_anims = []
	anim_index = 0
	if entries.is_empty():
		_label.text = "No models under %s yet.\nExport one with the Blender add-on (docs/art_pipeline.md)." % root
		return
	var e: Dictionary = entries[index]
	var section: Dictionary = Models.registry.get(e["kind"], {})
	var spec: Dictionary = Models._make_spec(e["kind"], section[e["id"]] if section.get(e["id"]) is Dictionary else {})
	spec["path"] = e["path"]
	_model = Models.instantiate(spec)
	if _model == null:
		_label.text = "%s does not load." % e["path"]
		return
	_stage.add_child(_model)
	if e["kind"] == "items":
		# Items in the hand point forward like the character.
		_model.rotation_degrees.y += 180.0
		_model.position.y = 1.0
	if e["kind"] == "characters" or e["kind"] == "animations":
		var anim := ModelAnimator.new(_model, spec)
		_player = anim.player
		if _player != null:
			_anims = _player.get_animation_list()
			var idle := anim.clip_for("idle")
			anim_index = maxi(0, _anims.find(idle))
	_stage.rotation_degrees.y = turn
	_play()
	var box := Registry.bounds(_model, _stage)
	_rig.zoom = clampf(maxf(box.size.y, maxf(box.size.x, box.size.z)) * 3.2, 5.0, 34.0)
	_rig.position = Vector3(0, box.size.y * 0.4, 0)
	_update_label(e, box)


func _play() -> void:
	if _player != null and not _anims.is_empty():
		_player.play(_anims[anim_index])


func _update_label(e: Dictionary, box: AABB) -> void:
	var t := "%s  (%d/%d)\n%s\nSize: %.2f wide x %.2f deep x %.2f tall (m = tiles)\nBase at y = %.2f" % [
		e["id"], index + 1, entries.size(), e["path"], box.size.x, box.size.z, box.size.y, box.position.y]
	if _player != null and not _anims.is_empty():
		t += "\nAnimation: %s  (%d/%d)" % [_anims[anim_index], anim_index + 1, _anims.size()]
	t += "\n\nLeft/Right model   Up/Down animation   Q/E turn   G placeholder   wheel zoom"
	_label.text = t


func _unhandled_input(ev: InputEvent) -> void:
	if ev is InputEventKey and ev.pressed and not ev.echo and not entries.is_empty():
		match ev.keycode:
			KEY_RIGHT:
				index = (index + 1) % entries.size()
				_show()
			KEY_LEFT:
				index = (index - 1 + entries.size()) % entries.size()
				_show()
			KEY_DOWN, KEY_UP:
				if not _anims.is_empty():
					anim_index = (anim_index + (1 if ev.keycode == KEY_DOWN else -1) + _anims.size()) % _anims.size()
					_play()
					_update_label(entries[index], Registry.bounds(_model, _stage))
			KEY_Q, KEY_E:
				turn += 45.0 if ev.keycode == KEY_Q else -45.0
				_stage.rotation_degrees.y = turn
			KEY_G:
				_placeholder.visible = not _placeholder.visible
	elif ev is InputEventMouseButton and ev.pressed:
		if ev.button_index == MOUSE_BUTTON_WHEEL_UP:
			_rig.zoom_by(0.9)
		elif ev.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_rig.zoom_by(1.1)
