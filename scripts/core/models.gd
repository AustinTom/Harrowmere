@tool
extends Node
## Model registry (autoload "Models"). Finds the 3D model for a character,
## item or structure, and returns nothing when there isn't one, so callers
## fall back to the placeholder primitives.
##
## Lookup order for each kind (first hit wins):
##   1. An explicit "model" key on the data entry (actor template, item,
##      area structure). It may be a registry id or a res:// path.
##   2. An entry with the same id in data/models.json.
##   3. A file that follows the folder convention, e.g.
##      res://assets/characters/iska/iska.glb  or  res://assets/characters/iska.glb
##   4. Characters only: the race default from data/models.json, then
##      res://assets/characters/races/<race>.glb
##   5. Nothing: the game draws the placeholder.
##
## See docs/art_pipeline.md for the rules models must follow.

const KINDS := ["characters", "items", "structures", "animations"]
## Tried in this order, so an inherited .tscn wrapper overrides its .glb.
const EXTENSIONS := ["tscn", "scn", "glb", "gltf", "blend"]
## Characters are authored facing the viewer in Blender's Front view, which
## is +Z in Godot. Actors treat -Z as forward, so they turn 180 by default.
const KIND_DEFAULTS := {
	"characters": {"rotate_y": 180.0, "scale": 1.0},
	"items": {"rotate_y": 0.0, "scale": 1.0},
	"structures": {"rotate_y": 0.0, "scale": 1.0},
	"animations": {},
}

## Root folder for convention lookups. Tests point this at fixtures.
var root := "res://assets"
var registry: Dictionary = {}

var _scene_cache: Dictionary = {}
var _exists_cache: Dictionary = {}
## kind -> {id: path or ""}, for the "what still uses a placeholder" report.
var usage: Dictionary = {}


func _init() -> void:
	reload()


func reload(registry_path := "res://data/models.json") -> void:
	registry = {}
	if FileAccess.file_exists(registry_path):
		var f := FileAccess.open(registry_path, FileAccess.READ)
		var parsed = JSON.parse_string(f.get_as_text())
		if parsed is Dictionary:
			registry = parsed
		else:
			push_error("Bad JSON in " + registry_path)
	_scene_cache.clear()
	_exists_cache.clear()
	usage.clear()


# ---------------------------------------------------------------- lookups

## Spec for an actor template, or {} for "use the placeholder".
## A spec is a Dictionary: {path, rotate_y, scale, offset, anims, anim_library, ...}
func character_spec(tpl: Dictionary) -> Dictionary:
	var id := str(tpl.get("id", ""))
	var spec := _resolve("characters", id, str(tpl.get("model", "")))
	if spec.is_empty():
		spec = _race_default(id, str(tpl.get("race", "")))
	_note("characters", id, spec)
	return spec


func item_spec(item_id: String, item: Dictionary = {}) -> Dictionary:
	var it := item
	if it.is_empty():
		var db = Engine.get_main_loop().root.get_node_or_null("DB") if Engine.get_main_loop() is SceneTree else null
		if db != null:
			it = db.get_item(item_id)
	var spec := _resolve("items", item_id, str(it.get("model", "")))
	_note("items", item_id, spec)
	return spec


## Structures are looked up by size first, so one kind can have a model per
## footprint: house_4x3, then house. An area entry can name a model directly.
func structure_spec(s: Dictionary) -> Dictionary:
	var kind := str(s.get("kind", "box"))
	var ra: Array = s.get("rect", [0, 0, 1, 1])
	var sized := "%s_%dx%d" % [kind, int(ra[2]), int(ra[3])]
	var spec := _resolve("structures", sized, str(s.get("model", "")))
	if spec.is_empty():
		spec = _resolve("structures", kind, "")
	_note("structures", sized, spec)
	return spec


## A shared animation library (a .glb with only an armature and actions).
func animation_library_path(id: String) -> String:
	var spec := _resolve("animations", id, "")
	return str(spec.get("path", ""))


func _resolve(kind: String, id: String, explicit: String) -> Dictionary:
	var section: Dictionary = registry.get(kind, {})
	if explicit != "":
		if explicit.begins_with("res://"):
			if _exists(explicit):
				return _make_spec(kind, {"path": explicit})
			push_warning("Model file not found: %s (wanted by %s '%s')" % [explicit, kind, id])
			return {}
		if section.has(explicit):
			return _from_entry(kind, explicit, section[explicit])
		var by_conv := _find_by_convention(kind, explicit)
		if by_conv != "":
			return _make_spec(kind, {"path": by_conv})
		push_warning("No model '%s' for %s '%s'" % [explicit, kind, id])
		return {}
	if id != "" and section.has(id):
		return _from_entry(kind, id, section[id])
	if id != "":
		var p := _find_by_convention(kind, id)
		if p != "":
			return _make_spec(kind, {"path": p})
	return {}


func _from_entry(kind: String, id: String, entry) -> Dictionary:
	var e: Dictionary = entry if entry is Dictionary else {"path": str(entry)}
	e = e.duplicate(true)
	if not e.has("path"):
		var p := _find_by_convention(kind, id)
		if p == "":
			push_warning("models.json %s '%s' has no path and no file at the usual place" % [kind, id])
			return {}
		e["path"] = p
	elif not _exists(str(e["path"])):
		push_warning("models.json %s '%s': file not found: %s" % [kind, id, e["path"]])
		return {}
	return _make_spec(kind, e)


func _make_spec(kind: String, e: Dictionary) -> Dictionary:
	var spec: Dictionary = KIND_DEFAULTS.get(kind, {}).duplicate(true)
	spec.merge(registry.get("defaults", {}).get(kind, {}), true)
	spec.merge(e, true)
	spec["kind"] = kind
	return spec


func _race_default(id: String, race: String) -> Dictionary:
	if race == "":
		return {}
	var rd = registry.get("race_defaults", {}).get(race, null)
	var choices: Array = []
	if rd is Array:
		choices = rd
	elif rd != null:
		choices = [rd]
	if not choices.is_empty():
		# Same template always gets the same variant.
		var pick = choices[absi(hash(id)) % choices.size()]
		var spec := _resolve("characters", id, str(pick))
		if not spec.is_empty():
			return spec
	var p := _find_by_convention("characters", "races/" + race)
	return _make_spec("characters", {"path": p}) if p != "" else {}


func _find_by_convention(kind: String, id: String) -> String:
	var leaf := id.get_file()
	for base in ["%s/%s/%s/%s" % [root, kind, id, leaf], "%s/%s/%s" % [root, kind, id]]:
		for ext in EXTENSIONS:
			var p: String = base + "." + ext
			if _exists(p):
				return p
	return ""


func _exists(path: String) -> bool:
	if not _exists_cache.has(path):
		_exists_cache[path] = ResourceLoader.exists(path)
	return _exists_cache[path]


func _note(kind: String, id: String, spec: Dictionary) -> void:
	if not usage.has(kind):
		usage[kind] = {}
	usage[kind][id] = str(spec.get("path", ""))


# ---------------------------------------------------------------- instancing

## Builds the model for a spec, wrapped in a Node3D that applies the spec's
## rotation, scale and offset. Returns null if the file won't load.
func instantiate(spec: Dictionary) -> Node3D:
	var path := str(spec.get("path", ""))
	if path == "":
		return null
	var scene: PackedScene = _scene_cache.get(path, null)
	if scene == null:
		var res = load(path)
		if not (res is PackedScene):
			push_warning("Model is not a scene: " + path)
			return null
		scene = res
		_scene_cache[path] = scene
	var inst := scene.instantiate()
	if not (inst is Node3D):
		inst.free()
		push_warning("Model root is not 3D: " + path)
		return null
	var wrap := Node3D.new()
	wrap.name = "Model"
	wrap.rotation_degrees.y = float(spec.get("rotate_y", 0.0))
	var sc = spec.get("scale", 1.0)
	wrap.scale = Vector3(sc[0], sc[1], sc[2]) if sc is Array else Vector3.ONE * float(sc)
	var off: Array = spec.get("offset", [0, 0, 0])
	wrap.position = Vector3(off[0], off[1], off[2])
	wrap.add_child(inst)
	return wrap


## Finds a named attachment point in a model: an Empty exported from
## Blender (a plain Node3D, or a BoneAttachment3D's child). Names compare
## case-insensitively and ignore "." "_" "-" so socket_hand_r == Socket.Hand.R.
static func find_socket(model: Node, socket_name: String) -> Node3D:
	var want := _norm(socket_name)
	var stack: Array = [model]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Node3D and _norm(n.name) == want:
			return n
		stack.append_array(n.get_children())
	return null


## Falls back to the hand bone when a rig has no socket empty.
static func find_or_make_hand_socket(model: Node, socket_name := "socket_hand_r") -> Node3D:
	var s := find_socket(model, socket_name)
	if s != null:
		return s
	var skel := find_first(model, "Skeleton3D") as Skeleton3D
	if skel == null:
		return null
	# Godot turns an Empty parented to a bone into a bone of its own, so the
	# socket is usually found here.
	for bone in [socket_name, "hand_r", "hand.r", "righthand", "mixamorig:righthand", "hand_right", "r_hand"]:
		for i in skel.get_bone_count():
			if _norm(skel.get_bone_name(i)) == _norm(bone):
				var ba := BoneAttachment3D.new()
				ba.name = socket_name
				skel.add_child(ba)
				ba.bone_idx = i
				return ba
	return null


static func find_first(n: Node, cls: String) -> Node:
	if n.is_class(cls):
		return n
	for c in n.get_children():
		var r := find_first(c, cls)
		if r != null:
			return r
	return null


static func mesh_instances(n: Node, out: Array = []) -> Array:
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		mesh_instances(c, out)
	return out


## Combined bounds of every mesh under `n`, in the space of `relative_to`
## (an ancestor of `n`, or `n` itself when left out).
static func bounds(n: Node3D, relative_to: Node3D = null) -> AABB:
	var ref := relative_to if relative_to != null else n
	var out := AABB()
	var first := true
	for mi in mesh_instances(n):
		if mi.mesh == null:
			continue
		var box: AABB = _local_xf(mi, ref) * mi.mesh.get_aabb()
		out = box if first else out.merge(box)
		first = false
	return out


static func _local_xf(n: Node3D, ref: Node3D) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var cur: Node = n
	while cur != null and cur != ref:
		if cur is Node3D:
			xf = cur.transform * xf
		cur = cur.get_parent()
	return xf


static func _norm(s: String) -> String:
	return s.to_lower().replace(".", "").replace("_", "").replace("-", "").replace(" ", "")


## Human-readable summary of which things have models and which are still
## placeholders. Printed once at startup.
func report() -> String:
	var lines: PackedStringArray = []
	for kind in ["characters", "items", "structures"]:
		var u: Dictionary = usage.get(kind, {})
		if u.is_empty():
			continue
		var have := 0
		var missing: PackedStringArray = []
		for id in u:
			if u[id] != "":
				have += 1
			else:
				missing.append(id)
		lines.append("%s: %d of %d have models%s" % [kind.capitalize(), have, u.size(), ("" if missing.is_empty() else " (placeholders: %s)" % ", ".join(missing))])
	return "\n".join(lines)
