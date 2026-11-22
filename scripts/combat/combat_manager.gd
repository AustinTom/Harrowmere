class_name CombatManager
extends Node
## Runs fights. One rule set, two pacings:
##  - Turn-based: initiative order, each actor gets its AP at turn start.
##  - Real-time: everyone acts at once, AP refills continuously
##    (a full bar every ROUND_SECONDS).
## Every action (move, attack, cast, use, equip) goes through this node and
## spends AP the same way in both modes, so switching mid-fight is safe.

signal combat_started
signal combat_ended(victory: bool)
signal turn_changed(actor)
signal mode_changed(mode: int)

const TURN_BASED := 0
const REAL_TIME := 1
const ROUND_SECONDS := 3.0

var world = null
var ai := AI.new()
var active := false
var mode := TURN_BASED
var combatants: Array = []
var turn_index := 0
var _turn_serial := 0
var _mode_serial := 0
var _rt_thinking := {}


func _ready() -> void:
	mode = GameState.preferred_mode


func mode_name(m := -1) -> String:
	if m < 0:
		m = mode
	return "turn-based" if m == TURN_BASED else "real-time"


func is_turn_based() -> bool:
	return active and mode == TURN_BASED


func current_actor() -> Variant:
	if not is_turn_based() or combatants.is_empty():
		return null
	return combatants[turn_index % combatants.size()]


func can_act(actor) -> bool:
	if actor.is_dead:
		return false
	if not active or not actor.in_combat:
		return true
	if mode == REAL_TIME:
		return true
	return current_actor() == actor


# ---------------------------------------------------------------- lifecycle

func start(hostiles: Array) -> void:
	if active:
		return
	var list: Array = []
	for a in world.party():
		list.append(a)
	for h in hostiles:
		if not h.is_dead and not list.has(h):
			list.append(h)
	active = true
	mode = GameState.preferred_mode
	combatants = list
	for a in combatants:
		a.cancel_move()
		a.in_combat = true
		a.initiative = Rules.d20() + Rules.mod(int(a.stats["dex"]))
		a.ap = float(a.ap_max)
		a.ap_debt = 0
		a.skip_refill_once = false
	combatants.sort_custom(func(x, y): return x.initiative > y.initiative)
	var names: PackedStringArray = []
	for a in combatants:
		names.append("%s %d" % [a.display_name, a.initiative])
	Events.post("[color=#ff8080][b]Combat![/b][/color] Initiative: " + ", ".join(names))
	Events.post("Mode: [b]%s[/b]. Press T at any time to switch." % mode_name())
	GameState.clock_running = false
	combat_started.emit()
	if mode == TURN_BASED:
		_begin_turn.call_deferred(0)


func _check_end() -> bool:
	if not active:
		return true
	if world.player == null or world.player.is_dead:
		_finish(false)
		return true
	for a in combatants:
		if not a.is_dead and a.faction == "hostile":
			return false
	_finish(true)
	return true


func _finish(victory: bool) -> void:
	active = false
	_turn_serial += 1
	_mode_serial += 1
	for a in combatants:
		a.in_combat = false
		a.ap = float(a.ap_max)
		a.ap_debt = 0
		a.set_turn_highlight(false)
	combatants.clear()
	_rt_thinking.clear()
	GameState.clock_running = victory
	if victory:
		Events.post("[color=#80ff9f][b]Victory.[/b][/color] The fight is over.")
	else:
		Events.post("[color=#ff8080][b]You have fallen.[/b][/color] Press R to restart.")
	combat_ended.emit(victory)


func on_actor_died(actor) -> void:
	if not active:
		return
	var idx := combatants.find(actor)
	if idx < 0:
		return
	var was_current := is_turn_based() and idx == turn_index
	combatants.remove_at(idx)
	actor.in_combat = false
	if idx < turn_index:
		turn_index -= 1
	if _check_end():
		return
	if was_current:
		turn_index -= 1
		_advance.call_deferred()


# ---------------------------------------------------------------- turns

func _begin_turn(index: int) -> void:
	if not is_turn_based() or combatants.is_empty():
		return
	turn_index = posmod(index, combatants.size())
	_turn_serial += 1
	var a = combatants[turn_index]
	if a.skip_refill_once:
		a.skip_refill_once = false
		a.ap = maxf(0.0, floorf(a.ap))
	else:
		a.ap = float(a.ap_max)
	if a.ap_debt > 0:
		a.ap = maxf(0.0, a.ap - a.ap_debt)
		a.ap_debt = 0
	for c in combatants:
		c.set_turn_highlight(c == a)
	turn_changed.emit(a)
	if a.ai_controlled:
		_run_ai_turn(a, _turn_serial)


func _turn_valid(a, serial: int) -> bool:
	return is_turn_based() and serial == _turn_serial and current_actor() == a and not a.is_dead


func _run_ai_turn(a, serial: int) -> void:
	await get_tree().create_timer(0.3).timeout
	var guard := 0
	while _turn_valid(a, serial) and guard < 25:
		guard += 1
		var acted: bool = await ai.take_step(a, world, self)
		if not acted:
			break
		await get_tree().create_timer(0.2).timeout
	if _turn_valid(a, serial):
		_advance()


func end_turn(actor) -> void:
	if not is_turn_based() or current_actor() != actor:
		return
	actor.cancel_move()
	_advance()


func _advance() -> void:
	if _check_end():
		return
	_begin_turn(turn_index + 1)


func _process(delta: float) -> void:
	if not active:
		return
	if mode == TURN_BASED:
		# Auto-end the player's turn once they are out of AP and idle.
		var cur = current_actor()
		if cur != null and not cur.ai_controlled and cur.ap < 1.0 and not cur.busy and not cur.moving:
			_advance()
		return
	var regen := delta / ROUND_SECONDS
	for a in combatants.duplicate():
		if a.is_dead:
			continue
		a.ap = minf(float(a.ap_max), a.ap + a.ap_max * regen)
		if a.ai_controlled and not _rt_thinking.has(a):
			_rt_think(a)


func _rt_think(a) -> void:
	_rt_thinking[a] = true
	var serial := _mode_serial
	var acted: bool = await ai.take_step(a, world, self)
	if not acted:
		await get_tree().create_timer(0.3).timeout
	if serial == _mode_serial:
		_rt_thinking.erase(a)


func toggle_mode() -> void:
	var new_mode := REAL_TIME if mode == TURN_BASED else TURN_BASED
	GameState.preferred_mode = new_mode
	mode = new_mode
	_mode_serial += 1
	_turn_serial += 1
	_rt_thinking.clear()
	mode_changed.emit(mode)
	if not active:
		Events.post("Fights will start [b]%s[/b]." % mode_name())
		return
	Events.post("[color=#ffd84d]Switched to %s mid-fight.[/color]" % mode_name())
	if mode == TURN_BASED:
		# Keep what everyone has left; no free refill for switching.
		for a in combatants:
			a.skip_refill_once = true
			if a.ap < 0.0:
				a.ap_debt += int(ceil(-a.ap))
				a.ap = 0.0
		var serial := _mode_serial
		await get_tree().create_timer(0.35).timeout
		if is_turn_based() and serial == _mode_serial:
			_begin_turn(0)
	else:
		for a in combatants:
			a.set_turn_highlight(false)
			if a.ap_debt > 0:
				a.ap -= a.ap_debt
				a.ap_debt = 0


# ---------------------------------------------------------------- AP

func apply_ap_loss(actor, amount: int) -> void:
	if amount <= 0:
		return
	if active and mode == REAL_TIME:
		actor.ap = maxf(actor.ap - amount, -float(actor.ap_max))
	else:
		actor.ap_debt += amount


## Spends AP, waiting for it to refill in real time. Returns false if the
## action can't happen (not your turn, not enough AP in turn-based, mode switch).
func wait_for_ap(actor, cost: float) -> bool:
	if not active or not actor.in_combat:
		return true
	var serial := _mode_serial
	while true:
		if not active:
			return false # the fight ended while we waited
		if serial != _mode_serial or not can_act(actor):
			return false
		if actor.ap >= cost - 0.001:
			actor.ap -= cost
			return true
		if mode == TURN_BASED:
			return false
		await get_tree().process_frame
	return false


# ---------------------------------------------------------------- actions

func do_attack(attacker, target, use_alt := false) -> bool:
	if attacker.busy or attacker.is_dead or target == null or target.is_dead:
		return false
	var p := Rules.attack_profile(attacker.weapon_data(), use_alt)
	var reach := Rules.ft_to_tiles(int(p.get("range", 5)))
	if Rules.tile_distance(attacker.tile, target.tile) > reach:
		return false
	if not active and target.faction == "hostile":
		world.start_combat_with(target)
		if not can_act(attacker):
			return false
	attacker.busy = true
	if not await wait_for_ap(attacker, float(p.get("ap", 3))):
		attacker.busy = false
		_note_no_ap(attacker)
		return false
	if target.is_dead or attacker.is_dead:
		attacker.busy = false
		return false
	var res: int = world.resonance_at(attacker.tile)
	var r := Rules.resolve_attack(attacker, target, p, res)
	var tint := Color("#ffe08a") if p.get("pool") == "gear" else Color("#dddddd")
	if not r["misfire"]:
		await attacker.play_attack(target, p, tint)
	if attacker.is_dead or target.is_dead:
		attacker.busy = false
		return false
	_apply(attacker, target, r)
	attacker.busy = false
	return true


func do_cast(caster, target, skill_id: String) -> bool:
	var skill: Dictionary = DB.get_skill(skill_id)
	if skill.is_empty() or not caster.known_skills.has(skill_id):
		return false
	if caster.busy or caster.is_dead or target == null or target.is_dead:
		return false
	if Rules.tile_distance(caster.tile, target.tile) > Rules.ft_to_tiles(int(skill.get("range", 30))):
		return false
	if skill.get("kind") == "attack" and not active and target.faction == "hostile":
		world.start_combat_with(target)
		if not can_act(caster):
			return false
	caster.busy = true
	if not await wait_for_ap(caster, float(skill.get("ap", 4))):
		caster.busy = false
		_note_no_ap(caster)
		return false
	if target.is_dead or caster.is_dead:
		caster.busy = false
		return false
	var res: int = world.resonance_at(caster.tile)
	var r := Rules.resolve_spell(caster, target, skill, res, caster.spell_power())
	if target != caster:
		await caster.play_attack(target, {"projectile": true}, Color(str(skill.get("color", "#ffffff"))))
	if caster.is_dead or target.is_dead:
		caster.busy = false
		return false
	_apply(caster, target, r)
	caster.busy = false
	return true


func do_use_item(actor, entry: Dictionary) -> bool:
	var item: Dictionary = DB.get_item(entry["id"])
	if item.get("type") != "consumable" or actor.is_dead or actor.busy:
		return false
	if active and actor.in_combat:
		if not can_act(actor):
			Events.post("Not %s's turn." % actor.display_name)
			return false
		if not await wait_for_ap(actor, float(item.get("ap", 2))):
			_note_no_ap(actor)
			return false
	if item.has("heal"):
		var amt := Rules.roll_dice(str(item["heal"]))
		actor.heal(amt)
		Events.post("%s drinks a %s and recovers %d HP." % [actor.display_name, item["name"], amt])
	elif item.get("identify", false):
		var found = null
		for holder in [actor] + world.party_all():
			for e in holder.inventory.entries:
				if not e["identified"]:
					found = e
					break
			if found != null:
				break
		if found == null:
			Events.post("There is nothing unknown in the party's packs.")
			return false
		found["identified"] = true
		var real: Dictionary = DB.get_item(found["id"])
		Events.post("[color=#9fd8ff]%s studies it through the Assayer's Lens. It is a [b]%s[/b].[/color] %s" % [actor.display_name, real.get("name", "?"), real.get("desc", "")])
	actor.inventory.remove_one(entry)
	return true


func do_equip(actor, entry: Dictionary) -> bool:
	if actor.is_dead or actor.busy:
		return false
	if active and actor.in_combat:
		if not can_act(actor):
			Events.post("Not %s's turn." % actor.display_name)
			return false
		if not await wait_for_ap(actor, 2.0):
			_note_no_ap(actor)
			return false
	actor.equip_entry(entry)
	Events.post("%s readies the %s." % [actor.display_name, DB.entry_name(entry)])
	return true


func _note_no_ap(actor) -> void:
	if not actor.ai_controlled and is_turn_based():
		Events.post("[color=gray]Not enough AP. Press Space to end your turn.[/color]")


func _apply(attacker, target, r: Dictionary) -> void:
	for line in r["lines"]:
		Events.post(line)
	if r["misfire"]:
		world.float_text(attacker.global_position, "misfire!", Color("#ffb347"))
	if r["self_damage"] > 0:
		attacker.take_damage(r["self_damage"])
	if r["damage"] > 0:
		target.take_damage(r["damage"], r["crit"])
	elif r["heal"] > 0:
		target.heal(r["heal"])
	elif not r["misfire"]:
		world.float_text(target.global_position, "miss", Color("#bbbbbb"))
	for e in r["effects"]:
		if not target.is_dead:
			apply_ap_loss(target, int(e.get("ap_loss", 0)))
