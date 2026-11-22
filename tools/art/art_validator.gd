@tool
extends RefCounted
## Checks every model under res://assets against the art rules in
## docs/art_pipeline.md, and lists which game things still use placeholders.
## Run it from Project > Tools > Validate Harrowmere Art, or headless:
##   godot --headless res://tools/art/validate_art.tscn
##   godot --headless res://tools/art/validate_art.tscn -- --root=res://tests/fixtures/assets

const Registry := preload("res://scripts/core/models.gd")
const REQUIRED_ANIMS := ["idle", "walk"]
const KNOWN_ANIMS := ["idle", "walk", "run", "attack_melee", "attack_ranged", "cast", "hit", "death", "talk", "work", "sit"]
const TRI_BUDGET := {"characters": 25000, "items": 4000, "structures": 60000} # docs/art/README.md (art style thread)
const HEIGHT_RANGE := {"characters": [0.5, 3.5], "items": [0.05, 3.0], "structures": [0.1, 30.0]}

var lines: PackedStringArray = []
var errors := 0
var warnings := 0
var models := 0
var reg


func validate_all(root := "res://assets") -> Dictionary:
	reg = Registry.new()
	reg.root = root
	for path in _scan(root):
		_validate_file(root, path)
	_coverage()
	reg.free()
	return {"lines": lines, "errors": errors, "warnings": warnings, "models": models}


func _err(path: String, msg: String) -> void:
	errors += 1
	lines.append("ERROR %s: %s" % [path, msg])


func _warn(path: String, msg: String) -> void:
	warnings += 1
	lines.append("WARN  %s: %s" % [path, msg])


func _ok(path: String, msg: String) -> void:
	lines.append("ok    %s: %s" % [path, msg])


func _scan(dir: String, out: PackedStringArray = []) -> PackedStringArray:
	var d := DirAccess.open(dir)
	if d == null:
		return out
	for sub in d.get_directories():
		if not sub.begins_with("."):
			_scan(dir.path_join(sub), out)
	for f in d.get_files():
		if f.get_extension().to_lower() in Registry.EXTENSIONS:
			out.append(dir.path_join(f))
	return out


func _validate_file(root: String, path: String) -> void:
	models += 1
	var rel := path.substr(root.length() + 1)
	var kind := rel.get_slice("/", 0)
	if not kind in ["characters", "items", "structures", "animations"]:
		_warn(path, "is not inside characters/, items/, structures/ or animations/, so the game will never look for it.")
		return
	var id := rel.substr(kind.length() + 1).get_basename()
	if id.get_file() == id.get_base_dir().get_file():
		id = id.get_base_dir() # characters/iska/iska.glb -> iska
	if id != id.to_lower() or id.contains(" ") or id.contains("-"):
		_warn(path, "id '%s' should be lowercase_with_underscores to match the game data." % id)
	var section: Dictionary = reg.registry.get(kind, {})
	var spec: Dictionary = reg._make_spec(kind, section[id] if section.get(id) is Dictionary else {})
	spec["path"] = path
	var holder := Node3D.new()
	var model: Node3D = reg.instantiate(spec)
	if model == null:
		_err(path, "does not load as a 3D scene.")
		holder.free()
		return
	holder.add_child(model)
	var meshes: Array = Registry.mesh_instances(model)
	# Triangle counts need mesh data, which the headless (dummy) renderer
	# doesn't keep, so they are only checked in the editor or a window.
	var count_tris := DisplayServer.get_name() != "headless"
	var tris := 0
	for mi in meshes:
		if mi.mesh == null:
			continue
		if count_tris:
			for si in mi.mesh.get_surface_count():
				var arr: Array = mi.mesh.surface_get_arrays(si)
				var idx = arr[Mesh.ARRAY_INDEX]
				tris += (idx.size() if idx != null else arr[Mesh.ARRAY_VERTEX].size()) / 3
		if not mi.scale.is_equal_approx(Vector3.ONE) and not (mi.get_parent() is Skeleton3D):
			_warn(path, "mesh '%s' has scale %s. Apply scale in Blender (Ctrl+A)." % [mi.name, mi.scale])
	if kind != "animations" and meshes.is_empty():
		_err(path, "has no meshes.")
	var box: AABB = Registry.bounds(model, holder)
	if kind in HEIGHT_RANGE and not meshes.is_empty():
		var rng: Array = HEIGHT_RANGE[kind]
		var h := box.size.y if kind != "items" else maxf(box.size.x, maxf(box.size.y, box.size.z))
		if h < rng[0] or h > rng[1]:
			_warn(path, "is %.2f m %s; expected %s to %s m (1 unit = 1 m = 1 tile)." % [h, "long" if kind == "items" else "tall", rng[0], rng[1]])
		if kind in ["characters", "structures"]:
			if absf(box.position.y) > 0.05:
				_warn(path, "lowest point is at %.2f m. Feet / floor should sit at 0." % box.position.y)
			var c := box.get_center()
			if absf(c.x) > 0.3 or absf(c.z) > 0.3:
				_warn(path, "is centred at (%.2f, %.2f), not on the origin." % [c.x, c.z])
		if kind == "structures":
			var m := RegEx.create_from_string("_(\\d+)x(\\d+)$").search(id)
			if m != null:
				var fw := float(m.get_string(1))
				var fd := float(m.get_string(2))
				var sx := box.size.x
				var sz := box.size.z
				if absf(sx - fw) > 0.6 or absf(sz - fd) > 0.6:
					_warn(path, "footprint is %.1f x %.1f m, but the name says %dx%d tiles." % [sx, sz, int(fw), int(fd)])
	var budget: int = TRI_BUDGET.get(kind, 0)
	if budget > 0 and tris > budget:
		_warn(path, "%d triangles, over the %d low-poly budget." % [tris, budget])
	if Registry.find_first(model, "Camera3D") or Registry.find_first(model, "Light3D"):
		_warn(path, "contains a camera or light. Turn the Harrowmere import plugin on, or leave them out of the export.")
	if kind in ["characters", "animations"]:
		var ap := Registry.find_first(model, "AnimationPlayer") as AnimationPlayer
		var names: Array = []
		if ap != null:
			for a in ap.get_animation_list():
				names.append(ModelAnimatorNames.normalise(a))
		var lib := str(spec.get("anim_library", ""))
		if names.is_empty() and lib == "" and Registry.find_first(model, "Skeleton3D") != null:
			_warn(path, "has a rig but no animations and no anim_library in data/models.json.")
		for req in REQUIRED_ANIMS:
			if lib == "" and Registry.find_first(model, "Skeleton3D") != null and not names.has(req) and not (spec.get("anims", {}) as Dictionary).has(req):
				_warn(path, "has no '%s' animation." % req)
		var odd: Array = names.filter(func(n): return not n in KNOWN_ANIMS and not (spec.get("anims", {}) as Dictionary).values().has(n))
		if not odd.is_empty():
			_warn(path, "animations the game won't use unless mapped in data/models.json: %s" % ", ".join(odd))
	if kind == "characters" and Registry.find_first(model, "Skeleton3D") != null:
		var sock := str(spec.get("hand_socket", "socket_hand_r"))
		var skel := Registry.find_first(model, "Skeleton3D") as Skeleton3D
		var has_bone := false
		for i in skel.get_bone_count():
			if Registry._norm(skel.get_bone_name(i)) == Registry._norm(sock):
				has_bone = true
		if not has_bone and Registry.find_socket(model, sock) == null:
			_warn(path, "no socket_hand_r empty; weapons will go on the hand bone if one is named like hand.R, else at the hip.")
	_ok(path, "%s, %.2f wide x %.2f deep x %.2f tall%s" % [kind.trim_suffix("s"), box.size.x, box.size.z, box.size.y, (", %d tris" % tris) if count_tris else ""])
	holder.free()


## Which actors, items and structures in the game data have a model.
func _coverage() -> void:
	var actors := _json("res://data/actors.json")
	var items := _json("res://data/items.json")
	var have := 0
	for id in actors:
		var tpl: Dictionary = actors[id].duplicate()
		tpl["id"] = id
		if not reg.character_spec(tpl).is_empty():
			have += 1
	lines.append("Characters: %d of %d actor templates have a model." % [have, actors.size()])
	have = 0
	for id in items:
		if not reg.item_spec(id, items[id]).is_empty():
			have += 1
	lines.append("Items: %d of %d have a model." % [have, items.size()])
	var kinds := {}
	var d := DirAccess.open("res://data/areas")
	if d != null:
		for f in d.get_files():
			if f.ends_with(".json"):
				for s in _json("res://data/areas/" + f).get("structures", []):
					var key := "%s_%dx%d" % [s["kind"], int(s["rect"][2]), int(s["rect"][3])]
					kinds[key] = not reg.structure_spec(s).is_empty()
	var missing: Array = kinds.keys().filter(func(k): return not kinds[k])
	lines.append("Structures: %d of %d kind+size combos have a model.%s" % [kinds.size() - missing.size(), kinds.size(), "" if missing.is_empty() else " Missing: " + ", ".join(missing)])


func _json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var p = JSON.parse_string(f.get_as_text())
	return p if p is Dictionary else {}


## Same name rules as ModelAnimator, without needing the game's autoloads.
class ModelAnimatorNames:
	static func normalise(anim_name: String) -> String:
		var n := anim_name.get_file()
		if n.contains("|"):
			n = n.get_slice("|", n.get_slice_count("|") - 1)
		n = n.to_lower().strip_edges().replace(" ", "_").replace("-", "_")
		if n.ends_with("_loop"):
			n = n.substr(0, n.length() - 5)
		return n
