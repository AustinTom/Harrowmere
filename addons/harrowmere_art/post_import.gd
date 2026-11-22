@tool
extends EditorScenePostImportPlugin
## Runs on every imported 3D scene (.glb, .gltf, .blend):
##  * loops idle / walk / run / talk clips (and anything ending in "loop"),
##    so nobody has to tick Loop in the import dock for each one;
##  * drops cameras and lights that came along from Blender, because the
##    game sets its own camera and lighting.
## Godot's own name suffixes (-col, -noimp, -loop ...) still work as usual.

const LOOPING := ["idle", "walk", "run", "talk", "work", "sit"]


func _post_process(scene: Node) -> void:
	_fix(scene, scene)


func _fix(n: Node, root: Node) -> void:
	for c in n.get_children():
		_fix(c, root)
	if n == root:
		return
	if n is Camera3D or n is Light3D:
		n.get_parent().remove_child(n)
		n.free()
		return
	if n is AnimationPlayer:
		for anim_name in n.get_animation_list():
			var short := str(anim_name).get_file().get_slice("|", str(anim_name).get_slice_count("|") - 1).to_lower()
			if short in LOOPING or short.ends_with("loop"):
				n.get_animation(anim_name).loop_mode = Animation.LOOP_LINEAR
