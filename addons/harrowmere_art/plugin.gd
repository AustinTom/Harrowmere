@tool
extends EditorPlugin
## Applies the Harrowmere import rules to every imported model and adds
## Project > Tools > "Validate Harrowmere Art".

var _import_plugin: EditorScenePostImportPlugin


func _enter_tree() -> void:
	_import_plugin = preload("res://addons/harrowmere_art/post_import.gd").new()
	add_scene_post_import_plugin(_import_plugin)
	add_tool_menu_item("Validate Harrowmere Art", _validate)


func _exit_tree() -> void:
	remove_scene_post_import_plugin(_import_plugin)
	remove_tool_menu_item("Validate Harrowmere Art")


func _validate() -> void:
	var v = preload("res://tools/art/art_validator.gd").new()
	var res: Dictionary = v.validate_all()
	for line in res["lines"]:
		print(line)
	print("Harrowmere art: %d errors, %d warnings, %d models" % [res["errors"], res["warnings"], res["models"]])
