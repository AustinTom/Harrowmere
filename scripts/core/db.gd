extends Node
## Read-only game data loaded from res://data. Every item, skill, actor
## template and dialogue is a JSON entry, so content can be added (or
## generated) without code changes.

var items: Dictionary = {}
var skills: Dictionary = {}
var actor_templates: Dictionary = {}
var dialogues: Dictionary = {}


func _init() -> void:
	items = load_json("res://data/items.json")
	skills = load_json("res://data/skills.json")
	actor_templates = load_json("res://data/actors.json")
	dialogues = load_json("res://data/dialogue.json")
	for k in actor_templates:
		actor_templates[k]["id"] = k
	for k in items:
		items[k]["id"] = k


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


## Display name for an inventory entry, hiding the true name until identified.
func entry_name(e: Dictionary) -> String:
	var it := get_item(e["id"])
	if not e.get("identified", true):
		return str(it.get("unidentified_name", "Unknown item"))
	return str(it.get("name", e["id"]))


func describe(e: Dictionary) -> String:
	var it := get_item(e["id"])
	if not e.get("identified", true):
		return "Unidentified. Use an Assayer's Lens to learn what it does."
	var parts: PackedStringArray = []
	parts.append(str(it.get("name", e["id"])))
	if it.get("type") == "weapon":
		parts.append("%s pool. Damage %s, %d AP, range %d ft." % [str(it.get("pool", "neutral")).capitalize(), it.get("damage", "?"), int(it.get("ap", 0)), int(it.get("range", 5))])
		if it.has("alt"):
			parts.append("Alt: %s, %s damage, %d AP." % [it["alt"].get("label", "alt"), it["alt"].get("damage", "?"), int(it["alt"].get("ap", 0))])
	if it.has("desc"):
		parts.append(str(it["desc"]))
	return "\n".join(parts)
