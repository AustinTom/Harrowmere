class_name Inventory
extends RefCounted
## A pack of item entries. Each entry is {id, qty, identified, equipped}.
## Every actor (player, followers, NPCs, enemies) owns one.

signal changed

var entries: Array = []


func add(id: String, qty := 1, identified: Variant = null) -> void:
	var item: Dictionary = DB.get_item(id)
	if item.is_empty():
		push_warning("Unknown item id: " + id)
		return
	var ident: bool = (not item.get("identify_required", false)) if identified == null else bool(identified)
	if item.get("stack", false):
		for e in entries:
			if e["id"] == id:
				e["qty"] += qty
				_changed()
				return
		entries.append({"id": id, "qty": qty, "identified": true, "equipped": false})
	else:
		for i in qty:
			entries.append({"id": id, "qty": 1, "identified": ident, "equipped": false})
	_changed()


func count(id: String) -> int:
	var n := 0
	for e in entries:
		if e["id"] == id:
			n += int(e["qty"])
	return n


func find_first(id: String) -> Variant:
	for e in entries:
		if e["id"] == id:
			return e
	return null


func remove_one(e: Dictionary) -> void:
	var idx := entries.find(e)
	if idx < 0:
		return
	e["qty"] -= 1
	if e["qty"] <= 0:
		entries.remove_at(idx)
	_changed()


## Moves one of an entry (or a whole stack) into another inventory.
func transfer(e: Dictionary, to: Inventory, whole_stack := true) -> void:
	if entries.find(e) < 0:
		return
	var qty: int = int(e["qty"]) if whole_stack else 1
	var ident: bool = e["identified"]
	var id: String = e["id"]
	if whole_stack:
		entries.erase(e)
		_changed()
	else:
		remove_one(e)
	to.add(id, qty, ident)


func clear() -> void:
	entries.clear()
	_changed()


func _changed() -> void:
	changed.emit()
	Events.inventory_changed.emit()
