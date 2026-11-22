extends Node
## Headless runner for the art validator. Exits with code 1 on errors.
##   godot --headless res://tools/art/validate_art.tscn [-- --root=res://assets]


func _ready() -> void:
	var root := "res://assets"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--root="):
			root = arg.substr(7)
	var v = preload("res://tools/art/art_validator.gd").new()
	var res: Dictionary = v.validate_all(root)
	for line in res["lines"]:
		print(line)
	print("\n%d models, %d errors, %d warnings" % [res["models"], res["errors"], res["warnings"]])
	get_tree().quit(1 if res["errors"] > 0 else 0)
