extends Node
## Read-only game data loaded from res://data. Every item, ability, actor
## template and dialogue is a JSON entry, so content can be added (or
## generated) without code changes. Character data lives in data/character/.

var items: Dictionary = {}
var actor_templates: Dictionary = {}
var dialogues: Dictionary = {}

# Character system (data/character/*.json, see docs/character-system.md)
var abilities: Dictionary = {}
var abilities_by_discipline: Dictionary = {}
var char_skills: Dictionary = {}
var disciplines: Dictionary = {}
var races: Dictionary = {}
var traits: Dictionary = {}
var backgrounds: Dictionary = {}
var statuses: Dictionary = {}
var archetypes: Dictionary = {}
var progression: Dictionary = {}


func _init() -> void:
	items = load_json("res://data/items.json")
	actor_templates = load_json("res://data/actors.json")
	dialogues = load_json("res://data/dialogue.json")
	abilities = load_json("res://data/character/abilities.json")
	char_skills = load_json("res://data/character/skills.json")
	disciplines = load_json("res://data/character/disciplines.json")
	races = load_json("res://data/character/races.json")
	traits = load_json("res://data/character/traits.json")
	backgrounds = load_json("res://data/character/backgrounds.json")
	statuses = load_json("res://data/character/statuses.json")
	archetypes = load_json("res://data/character/archetypes.json")
	progression = load_json("res://data/character/progression.json")
	var summons := load_json("res://data/character/summons.json")
	for k in summons:
		if not actor_templates.has(k):
			actor_templates[k] = summons[k]
	for k in actor_templates:
		actor_templates[k]["id"] = k
	for k in items:
		items[k]["id"] = k
	for k in abilities:
		abilities[k]["id"] = k
		var d := str(abilities[k].get("discipline", ""))
		if not abilities_by_discipline.has(d):
			abilities_by_discipline[d] = []
		abilities_by_discipline[d].append(k)
	for d in abilities_by_discipline:
		abilities_by_discipline[d].sort_custom(func(a, b): return int(abilities[a].get("tier", 1)) < int(abilities[b].get("tier", 1)))


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


func get_ability(id: String) -> Dictionary:
	return abilities.get(id, {})


## Old name for get_ability, kept so older code and branches still work.
func get_skill(id: String) -> Dictionary:
	return abilities.get(id, {})


func get_actor_template(id: String) -> Dictionary:
	return actor_templates.get(id, {})


func get_dialogue(id: String) -> Dictionary:
	return dialogues.get(id, {})


## Which weapon skill an item uses. Items may name it with "skill"; otherwise
## it is inferred from the item's pool and shape.
func weapon_skill(it: Dictionary) -> String:
	if it.has("skill"):
		return str(it["skill"])
	if it.get("id", "") == "fists":
		return "brawling"
	var pool := str(it.get("pool", "neutral"))
	if it.get("ranged", false):
		return "firearms" if pool == "gear" else "bows"
	if pool == "gear":
		return "heavy_gear"
	return "blades"


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
		parts.append("%s pool, %s skill. Damage %s, %d AP, range %d ft." % [str(it.get("pool", "neutral")).capitalize(), str(char_skills.get(weapon_skill(it), {}).get("name", "?")), it.get("damage", "?"), int(it.get("ap", 0)), int(it.get("range", 5))])
		if it.has("alt"):
			parts.append("Alt: %s, %s damage, %d AP." % [it["alt"].get("label", "alt"), it["alt"].get("damage", "?"), int(it["alt"].get("ap", 0))])
	if it.has("desc"):
		parts.append(str(it["desc"]))
	return "\n".join(parts)
