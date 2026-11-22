class_name ModelAnimator
extends RefCounted
## Plays a model's animations by their Harrowmere names (idle, walk,
## attack_melee...), whatever the clips are called in the file.
##
## Clip names are matched loosely: case is ignored, a Blender
## "Armature|" prefix and a "-loop" / "_loop" suffix are dropped. A
## models.json entry can map names explicitly: "anims": {"attack_melee": "Slash_02"}.
## Missing clips fall back along FALLBACKS, then to nothing (the actor
## still works, it just doesn't animate that action).

const LOOPING := ["idle", "walk", "run", "talk", "work", "sit"]
const FALLBACKS := {
	"idle": ["idle"],
	"walk": ["walk", "run"],
	"run": ["run", "walk"],
	"attack_melee": ["attack_melee", "attack", "slash", "swing"],
	"attack_ranged": ["attack_ranged", "shoot", "fire", "attack", "attack_melee"],
	"cast": ["cast", "spell", "attack_ranged", "shoot", "attack", "attack_melee"],
	"hit": ["hit", "hurt", "flinch"],
	"death": ["death", "die", "dead"],
	"talk": ["talk", "idle"],
}

var player: AnimationPlayer
var _clips: Dictionary = {} # normalised name -> real animation name
var _overrides: Dictionary = {}
var _current := ""


func _init(model: Node, spec: Dictionary) -> void:
	_overrides = spec.get("anims", {})
	player = Models.find_first(model, "AnimationPlayer") as AnimationPlayer
	var lib_id := str(spec.get("anim_library", ""))
	if lib_id != "":
		_add_shared_library(model, lib_id)
	if player == null:
		return
	for full in player.get_animation_list():
		var n := normalise(full)
		if not _clips.has(n) or full.find("/") == -1:
			_clips[n] = full
		if n in LOOPING or str(full).to_lower().ends_with("loop"):
			player.get_animation(full).loop_mode = Animation.LOOP_LINEAR
	for canonical in _overrides:
		var real := str(_overrides[canonical])
		if player.has_animation(real):
			_clips[canonical] = real
			if canonical in LOOPING:
				player.get_animation(real).loop_mode = Animation.LOOP_LINEAR
	player.animation_finished.connect(_on_finished)


static func normalise(anim_name: String) -> String:
	var n := anim_name.get_file() # drops "library/" prefixes
	if n.contains("|"):
		n = n.get_slice("|", n.get_slice_count("|") - 1)
	n = n.to_lower().strip_edges().replace(" ", "_").replace("-", "_")
	if n.ends_with("_loop"):
		n = n.substr(0, n.length() - 5)
	return n


func has_any() -> bool:
	return player != null and not _clips.is_empty()


## The real clip that plays for a Harrowmere action, or "".
func clip_for(action: String) -> String:
	for cand in FALLBACKS.get(action, [action]):
		if _clips.has(cand):
			return _clips[cand]
	return ""


func play(action: String, blend := 0.15) -> bool:
	var clip := clip_for(action)
	if clip == "":
		return false
	if clip == _current and player.is_playing() and player.get_animation(clip).loop_mode != Animation.LOOP_NONE:
		return true
	_current = clip
	player.play(clip, blend)
	return true


func length(action: String) -> float:
	var clip := clip_for(action)
	return player.get_animation(clip).length if clip != "" else 0.0


## After a one-shot clip ends, go back to idle (but a death pose stays).
func _on_finished(anim_name: StringName) -> void:
	if str(anim_name) == clip_for("death"):
		return
	if player.get_animation(anim_name).loop_mode == Animation.LOOP_NONE:
		play("idle", 0.2)


## Merges a shared clip set (one .glb per rig, holding only the armature and
## its actions) into this model, so many characters share one set of clips.
## Tracks bind by node path, so the armature object and bone names must match.
func _add_shared_library(model: Node, lib_id: String) -> void:
	var path := Models.animation_library_path(lib_id)
	if path == "":
		push_warning("Animation library '%s' not found" % lib_id)
		return
	var src = load(path)
	if not (src is PackedScene):
		return
	var tmp: Node = src.instantiate()
	var src_player := Models.find_first(tmp, "AnimationPlayer") as AnimationPlayer
	if src_player != null:
		if player == null:
			player = AnimationPlayer.new()
			player.name = "AnimationPlayer"
			var host: Node = model.get_child(0) if model.get_child_count() > 0 else model
			host.add_child(player)
		var lib := AnimationLibrary.new()
		for a in src_player.get_animation_list():
			lib.add_animation(normalise(a), src_player.get_animation(a))
		var key := lib_id.validate_filename().replace(".", "_")
		if not player.has_animation_library(key):
			player.add_animation_library(key, lib)
	tmp.free()
