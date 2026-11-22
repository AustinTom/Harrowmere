extends Node
## Global signal bus. Systems talk through these signals so new systems
## (quests, gossip, factions) can listen in without touching existing code.

signal log_message(text: String)
signal resonance_changed(location_id: String, value: int)
signal flags_changed
signal inventory_changed
# Resident simulation (scripts/sim/residents.gd)
signal quest_hook_created(hook: Dictionary)
signal quest_hook_accepted(hook: Dictionary)
signal quest_hook_resolved(hook: Dictionary, solution: String)
signal rumor_started(rumor: Dictionary)
signal settlement_changed_hands(settlement_id: String, old_power: String, new_power: String)
signal war_shift(settlement_id: String, power: String, amount: int)


## Posts a line to the in-game log (BBCode allowed) and to stdout.
func post(text: String) -> void:
	log_message.emit(text)
	print(text)
