class_name Inventory
extends RefCounted
## A pack of item entries. Every actor (player, followers, NPCs, enemies) owns one.
## An entry is a plain dictionary: {id, qty, identified, equipped} plus optional
## instance data (quality, enchants, curse, curse_known, quirks, uses), see ItemStats.
## Stackable items (materials, essences, potions) never carry instance data.

signal changed

const INSTANCE_KEYS := ["quality", "enchants", "curse", "curse_known", "quirks", "uses", "crafted_by", "ident_tries"]

var entries: Array = []


## Adds items. `extra` is instance data for non-stackable items (quality, enchants...).
## Returns the last entry added (handy for crafting and loot rolls).
func add(id: String, qty := 1, identified: Variant = null, extra := {}) -> Variant:
	var item: Dictionary = DB.get_item(id)
	if item.is_empty():
		push_warning("Unknown item id: " + id)
		return null
	var ident: bool = (not item.get("identify_required", false)) if identified == null else bool(identified)
	if item.get("stack", false):
		for e in entries:
			if e["id"] == id:
				e["qty"] += qty
				_changed()
				return e
		var s := {"id": id, "qty": qty, "identified": true, "equipped": false}
		entries.append(s)
		_changed()
		return s
	var last = null
	for i in qty:
		last = {"id": id, "qty": 1, "identified": ident, "equipped": false}
		for k in extra:
			last[k] = extra[k].duplicate(true) if extra[k] is Array or extra[k] is Dictionary else extra[k]
		entries.append(last)
	_changed()
	return last


## Adds a copy of an entry from elsewhere, keeping its instance data.
func add_entry(e: Dictionary, qty := -1) -> Variant:
	var extra := {}
	for k in INSTANCE_KEYS:
		if e.has(k):
			extra[k] = e[k]
	return add(str(e["id"]), int(e["qty"]) if qty < 0 else qty, e.get("identified", true), extra)


func count(id: String) -> int:
	var n := 0
	for e in entries:
		if e["id"] == id:
			n += int(e["qty"])
	return n


## Counts items carrying a tag (data field "tags"), e.g. "essence_frost".
func count_tag(tag: String) -> int:
	var n := 0
	for e in entries:
		if DB.get_item(e["id"]).get("tags", []).has(tag):
			n += int(e["qty"])
	return n


func find_first(id: String) -> Variant:
	for e in entries:
		if e["id"] == id:
			return e
	return null


func has_tool(tag: String) -> bool:
	for e in entries:
		var it: Dictionary = DB.get_item(e["id"])
		if it.get("tool_tags", []).has(tag):
			return true
	return false


func remove_one(e: Dictionary) -> void:
	var idx := entries.find(e)
	if idx < 0:
		return
	e["qty"] -= 1
	if e["qty"] <= 0:
		entries.remove_at(idx)
	_changed()


## Removes up to `qty` of an item id, never touching equipped entries.
## Returns how many were removed.
func remove_id(id: String, qty: int) -> int:
	var left := qty
	for e in entries.duplicate():
		if left <= 0:
			break
		if e["id"] != id or e.get("equipped", false):
			continue
		var take := mini(left, int(e["qty"]))
		e["qty"] -= take
		left -= take
		if e["qty"] <= 0:
			entries.erase(e)
	if left != qty:
		_changed()
	return qty - left


## Moves one of an entry (or a whole stack) into another inventory.
func transfer(e: Dictionary, to: Inventory, whole_stack := true) -> void:
	if entries.find(e) < 0:
		return
	var qty: int = int(e["qty"]) if whole_stack else 1
	var copy: Dictionary = e.duplicate(true)
	if whole_stack:
		entries.erase(e)
		_changed()
	else:
		remove_one(e)
	to.add_entry(copy, qty)


func clear() -> void:
	entries.clear()
	_changed()


func _changed() -> void:
	changed.emit()
	Events.inventory_changed.emit()
