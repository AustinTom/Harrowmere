extends Node3D
## Fixed isometric orthographic camera that follows a target.

var target: Node3D = null
var camera: Camera3D
var zoom := 16.0


func _ready() -> void:
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = zoom
	camera.near = 0.1
	camera.far = 300.0
	var offset := Vector3(1, 1, 1).normalized() * 40.0
	camera.transform = Transform3D(Basis.looking_at(-offset, Vector3.UP), offset)
	add_child(camera)
	camera.make_current()


func snap() -> void:
	if target:
		global_position = target.global_position


func _process(delta: float) -> void:
	if target:
		global_position = global_position.lerp(target.global_position, clampf(delta * 6.0, 0.0, 1.0))
	camera.size = lerpf(camera.size, zoom, clampf(delta * 10.0, 0.0, 1.0))


func zoom_by(f: float) -> void:
	zoom = clampf(zoom * f, 8.0, 34.0)
