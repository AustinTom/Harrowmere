extends Node
## Global signal bus. Systems talk through these signals so new systems
## (quests, gossip, factions) can listen in without touching existing code.

signal log_message(text: String)
signal resonance_changed(location_id: String, value: int)
signal flags_changed
signal inventory_changed


## Posts a line to the in-game log (BBCode allowed) and to stdout.
func post(text: String) -> void:
	log_message.emit(text)
	print(text)
