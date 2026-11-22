extends Node
## Read-only game data loaded from res://data. Every item, skill, actor
## template and dialogue is a JSON entry, so content can be added (or
## generated) without code changes.

var items: Dictionary = {}
var skills: Dictionary = {}
var actor_templates: Dictionary = {}
var dialogues: Dictionary = {}
## Crafting data (data/crafting/*.json): disciplines (trades), schematics
## (also formulae and recipes), enchantments (also curses), quality grades.
var disciplines: Dictionary = {}
var schematics: Dictionary = {}
var enchantments: Dictionary = {}
var qualities: Dictionary = {}


func _init() -> void:
	items = load_json("res://data/items.json")
	# Items can be split across any number of files in data/items/ so the
	# ~1,500 base items stay manageable (one file per family or trade).
	for path in json_files_in("res://data/items"):
		items.merge(load_json(path), false)
	skills = load_json("res://data/skills.json")
	actor_templates = load_json("res://data/actors.json")
	dialogues = load_json("res://data/dialogue.json")
	disciplines = load_json("res://data/crafting/disciplines.json")
	schematics = load_json("res://data/crafting/schematics.json")
	for path in json_files_in("res://data/crafting/schematics"):
		schematics.merge(load_json(path), false)
	enchantments = load_json("res://data/crafting/enchantments.json")
	qualities = load_json("res://data/crafting/qualities.json")
	for k in actor_templates:
		actor_templates[k]["id"] = k
	_resolve_extends(items)
	for table in [items, schematics, enchantments, disciplines]:
		for k in table:
			table[k]["id"] = k


## "extends": "other_id" copies the other entry's fields under this one's,
## so item families (iron/steel/starglass variants) are a few lines each.
func _resolve_extends(table: Dictionary) -> void:
	var done := {}
	for k in table.keys():
		_resolve_one(table, k, done, [])


func _resolve_one(table: Dictionary, k: String, done: Dictionary, stack: Array) -> void:
	if done.has(k) or not table.has(k):
		return
	var e: Dictionary = table[k]
	if e.has("extends"):
		var base := str(e["extends"])
		if stack.has(base):
			push_error("Item extends loop at " + k)
		else:
			_resolve_one(table, base, done, stack + [k])
			var merged: Dictionary = table.get(base, {}).duplicate(true)
			merged.erase("abstract")
			merged.merge(e, true)
			merged.erase("extends")
			table[k] = merged
	done[k] = true


func json_files_in(dir_path: String) -> PackedStringArray:
	var out: PackedStringArray = []
	var d := DirAccess.open(dir_path)
	if d == null:
		return out
	for f in d.get_files():
		if f.ends_with(".json"):
			out.append(dir_path.path_join(f))
	out.sort()
	return out


func load_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("Missing data file: " + path)
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	if parsed is Dictionary:
		return parsed
	push_error("Bad JSON in " + path)
	return {}


func get_item(id: String) -> Dictionary:
	return items.get(id, {})


func get_skill(id: String) -> Dictionary:
	return skills.get(id, {})


func get_actor_template(id: String) -> Dictionary:
	return actor_templates.get(id, {})


func get_dialogue(id: String) -> Dictionary:
	return dialogues.get(id, {})


func get_schematic(id: String) -> Dictionary:
	return schematics.get(id, {})


func get_enchantment(id: String) -> Dictionary:
	return enchantments.get(id, {})


func get_discipline(id: String) -> Dictionary:
	return disciplines.get(id, {})


func get_quality(id: String) -> Dictionary:
	return qualities.get(id, qualities.get("standard", {}))


## Display name for an inventory entry, hiding the true name until identified.
func entry_name(e) -> String:
	if e == null:
		return "Nothing"
	return ItemStats.display_name(e)


func describe(e: Dictionary) -> String:
	return ItemStats.describe(e)
