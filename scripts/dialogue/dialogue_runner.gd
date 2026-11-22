class_name DialogueRunner
extends RefCounted
## Evaluates data-driven dialogue (data/dialogue.json): entry selection by
## flag conditions, option filtering, and effects. The HUD only renders.


static func entry_node(dlg: Dictionary) -> String:
	for e in dlg.get("entries", []):
		if check(e.get("if", {})):
			return str(e["node"])
	return ""


static func check(cond: Dictionary) -> bool:
	for k in cond:
		var want = cond[k]
		var have = GameState.get_flag(k, "")
		if want is Array:
			if not (have in want):
				return false
		elif str(have) != str(want):
			return false
	return true


static func visible_options(node: Dictionary) -> Array:
	var out: Array = []
	for o in node.get("options", []):
		if check(o.get("if", {})):
			out.append(o)
	return out


## Applies effects. Returns UI requests (like "open_inventory") for the caller.
static func apply_effects(effects: Array, receiver) -> Array:
	var requests: Array = []
	for e in effects:
		match str(e.get("type", "")):
			"set_flag":
				GameState.set_flag(str(e["flag"]), e["value"])
			"give_item":
				if receiver != null:
					var qty := int(e.get("qty", 1))
					receiver.inventory.add(str(e["item"]), qty)
					Events.post("Received %s x%d." % [DB.get_item(str(e["item"])).get("name", e["item"]), qty])
			"shift_resonance":
				GameState.shift_resonance(str(e["location"]), int(e["amount"]))
			"log":
				Events.post(str(e["text"]))
			"open_inventory":
				requests.append("open_inventory")
			_:
				push_warning("Unknown dialogue effect: " + str(e))
	return requests
