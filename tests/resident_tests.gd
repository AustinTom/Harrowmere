extends Node
## Tests for the resident simulation.
## Run: godot --headless res://tests/resident_tests.tscn

var checks := 0
var failures := 0


func check(cond: bool, msg: String) -> void:
	checks += 1
	if cond:
		print("  ok   ", msg)
	else:
		failures += 1
		printerr("  FAIL ", msg)


func _ready() -> void:
	GameState.reset()
	GameState.clock_running = false
	Residents.auto_tick = false

	print("Generation")
	var t0 := Time.get_ticks_msec()
	Residents.generate(1)
	var gen_ms := Time.get_ticks_msec() - t0
	var w: Dictionary = Residents.world
	var pop := Residents.population()
	check(absi(pop - 25000) < 750, "world population near 25,000 (%d)" % pop)
	check(gen_ms < 15000, "whole world generates in under 15 s (%d ms)" % gen_ms)
	var cities := 0
	var towns := 0
	for sid in w["order"]:
		if w["settlements"][sid]["kind"] == "city":
			cities += 1
		else:
			towns += 1
	check(cities == 13 and towns == 73, "13 cities and 73 towns (%d, %d)" % [cities, towns])
	var fl: Dictionary = Residents.settlement("fennicks_landing")
	check(not fl.is_empty() and absi(fl["residents"].size() - 80) <= 10, "Fennick's Landing has about 80 residents (%d)" % fl["residents"].size())
	var anchors := 0
	for id in fl["residents"]:
		if Residents.resident(id)["tier"] == "anchor":
			anchors += 1
	check(anchors == 3, "the three hand-written residents live in Fennick's Landing")
	var wardens := 0
	for id in fl["residents"]:
		if Residents.resident(id)["job"] == "warden":
			wardens += 1
	check(wardens == 1, "Osk is the town's only warden")

	var first_names: PackedStringArray = []
	for i in 50:
		first_names.append(Residents.full_name(w["residents"][i * 400]))
	var gen2 := PopulationGen.new()
	var w2 := gen2.generate_world(1)
	var same := true
	for i in 50:
		var r2: Dictionary = w2["residents"][i * 400]
		if "%s %s" % [r2["given"], r2["family"]] != first_names[i]:
			same = false
	check(same and w2["residents"].size() == w["residents"].size(), "same seed gives the same world")
	var w3 := PopulationGen.new().generate_world(2)
	check(w3["residents"][5000]["given"] + w3["residents"][5000]["family"] != w["residents"][5000]["given"] + w["residents"][5000]["family"] or w3["residents"].size() != w["residents"].size(), "a different seed gives a different world")
	w2 = {}
	w3 = {}

	var banned: Array = Residents.gen.data["settlements"]["town_names"]["banned"]
	var bad_name := false
	for sid in w["order"]:
		if w["settlements"][sid]["name"] in banned:
			bad_name = true
	check(not bad_name, "no banned names among towns")

	var homes_ok := true
	var hh_ok := true
	var work_ok := true
	var res_ok := true
	var ids_ok := true
	for sid in w["order"]:
		var s: Dictionary = w["settlements"][sid]
		for id in s["residents"]:
			var r: Dictionary = w["residents"][id]
			if r["id"] != id or r["sid"] != sid:
				ids_ok = false
			if r["home"] < 0 or s["places"][r["home"]]["kind"] != "home":
				homes_ok = false
			if s["households"][r["hh"]]["home"] != r["home"] or not (id in s["households"][r["hh"]]["members"]):
				hh_ok = false
			if r["job"] != "":
				if r["work"] < 0 or r["work"] >= s["places"].size():
					work_ok = false
				var rr: Array = Residents.jobs[r["job"]].get("res", [0, 100])
				var dres := int(s["districts"][r["district"]]["resonance"])
				if r["tier"] != "anchor" and (dres < int(rr[0]) or dres > int(rr[1])):
					res_ok = false
	check(ids_ok, "resident ids and settlements are consistent")
	check(homes_ok, "every resident has a home")
	check(hh_ok, "household members share a home")
	check(work_ok, "every worker has a workplace")
	check(res_ok, "jobs respect Resonance (no foundries in temple districts)")
	var cinder: Dictionary = Residents.settlement("cinderhythe")
	var vael: Dictionary = Residents.settlement("vaelstrand")
	check(_count_pool(cinder, "gear") > _count_pool(cinder, "arcane") * 5, "Cinderhythe is a Gear city")
	check(_count_pool(vael, "arcane") > _count_pool(vael, "gear") * 3, "Vaelstrand is an Arcane city")

	print("Schedules")
	var sched_ok := true
	var sleep_ok := true
	var night_ok := true
	var night_checked := 0
	for k in 600:
		var r: Dictionary = w["residents"][(k * 41) % w["residents"].size()]
		if not r["alive"]:
			continue
		var s: Dictionary = Residents.settlement(r["sid"])
		for h in 24:
			var b := ResidentSchedule.block_at(Residents, r, s, 3, h)
			if b[0] < 0 or b[0] >= s["places"].size():
				sched_ok = false
		var shift := ResidentSchedule.shift_of(Residents.jobs, Residents.shifts, r)
		var night := not shift.is_empty() and int(shift[0][1]) > 24
		var b3 := ResidentSchedule.block_at(Residents, r, s, 3, 3)
		if r["race"] != "wrought" and not night and not ResidentSchedule.in_shift(shift, 3) and (b3[1] != "sleep" or b3[0] != r["home"]):
			sleep_ok = false
		if night and not ResidentSchedule.is_rest_day(r, 3):
			night_checked += 1
			if ResidentSchedule.block_at(Residents, r, s, 3, 23)[1] != "work":
				night_ok = false
	check(sched_ok, "every hour of every sampled schedule resolves to a real place")
	check(sleep_ok, "people asleep at home at 3 AM unless their shift says otherwise")
	check(night_ok, "night shift workers are at work at 11 PM (%d checked)" % night_checked)
	var kid := _find(fl, func(r): return int(r["age"]) >= 7 and int(r["age"]) < 12)
	if not kid.is_empty():
		var day := 2 if 2 % 7 != 0 else 3
		var b := ResidentSchedule.block_at(Residents, kid, fl, day, 9)
		check(b[1] == "study" or fl["venues"][kid["district"]].get("school", []).is_empty(), "school-age children are at school at 9 AM")

	print("Simulation")
	Residents.set_active("fennicks_landing")
	check(fl["lod"] == Residents.ACTIVE, "Fennick's Landing is ACTIVE")
	var near := 0
	var far := 0
	for sid in w["order"]:
		if w["settlements"][sid]["lod"] == Residents.NEAR:
			near += 1
		elif w["settlements"][sid]["lod"] == Residents.FAR:
			far += 1
	check(near >= 2 and far > 70, "road neighbours are NEAR, the rest FAR (%d near, %d far)" % [near, far])
	var deed := Residents.report_deed("fennicks_landing", {"id": "test_boiler", "text": "Someone lit the boiler.", "pool": "gear", "mag": 30})
	var t1 := Time.get_ticks_msec()
	_advance_days(4)
	var sim_ms := Time.get_ticks_msec() - t1
	check(sim_ms < 60000, "4 game days of the whole world simulate in under 60 s (%d ms)" % sim_ms)
	check(deed["heard"] > fl["residents"].size() / 2, "a rumour reaches most of the town in 4 days (%d of %d)" % [deed["heard"], fl["residents"].size()])
	var spread := false
	for l in fl["links"]:
		for rid in Residents.settlement(l)["rumors"]:
			if Residents.rumors[rid]["origin"] == "fennicks_landing":
				spread = true
	check(spread, "the rumour travels down the road to a neighbouring town")
	var gear_fan := _find(fl, func(r): return int(r["lean"]) < -40 and r["heard"].has(deed["id"]))
	var arcane_fan := _find(fl, func(r): return int(r["lean"]) > 30 and r["heard"].has(deed["id"]))
	if not gear_fan.is_empty() and not arcane_fan.is_empty():
		check(gear_fan["op"]["player"] > arcane_fan["op"]["player"], "Gear-leaning residents liked the boiler more than Arcane-leaning ones")
	var needs_ok := true
	for r in w["residents"]:
		for k in r["needs"]:
			if r["needs"][k] < 0.0 or r["needs"][k] > 100.0:
				needs_ok = false
	check(needs_ok, "needs stay within 0..100")
	check(Residents.hooks.size() > 50, "quest hooks are being raised across the world (%d)" % Residents.hooks.size())
	var roles_ok := true
	var pitch_ok := true
	for hid in Residents.hooks:
		var h: Dictionary = Residents.hooks[hid]
		for role in h["roles"]:
			if Residents.resident(h["roles"][role]).is_empty():
				roles_ok = false
		if h["pitch"].contains("{"):
			pitch_ok = false
	check(roles_ok, "every hook role is a real resident")
	check(pitch_ok, "every hook pitch is fully filled in")

	print("LOD consistency")
	# The same town run hourly and run as daily summaries should end up in
	# the same place on average.
	var town: Dictionary = Residents.settlement("brannock")
	for id in town["residents"]:
		Residents.resident(id)["needs"]["money"] = 50.0
	var hourly := _avg_money_after(town, 10, true)
	for id in town["residents"]:
		Residents.resident(id)["needs"]["money"] = 50.0
	var summary := _avg_money_after(town, 10, false)
	check(absf(hourly - summary) < 6.0, "hourly and summary ticks agree on money (%.1f vs %.1f)" % [hourly, summary])

	print("Hooks and factions")
	var h0: Dictionary = {}
	for hid in fl["hooks"]:
		if Residents.hooks[hid]["state"] == "open":
			h0 = Residents.hooks[hid]
	if h0.is_empty():
		var giver := _find(fl, func(r): return r["tier"] == "generated" and int(r["age"]) > 20 and r["hooks"].is_empty())
		h0 = Residents.create_hook(fl, giver, "protection", {}, GameState.day())
	var dlg := DB.get_dialogue("res:%d" % h0["giver"])
	check(dlg["nodes"].has("hook") and dlg["nodes"]["hook"]["text"] == h0["pitch"], "the giver's dialogue offers the hook")
	var got := []
	Events.quest_hook_accepted.connect(func(h): got.append(h["id"]))
	GameState.set_flag("hook_%d" % h0["id"], "accepted")
	check(h0["state"] == "accepted" and got.has(h0["id"]), "accepting in dialogue marks the hook accepted and tells the quest system")
	var shifts := []
	Events.war_shift.connect(func(sid, p, n): shifts.append(p))
	var before: float = Residents.resident(h0["giver"])["op"]["player"]
	var sol: String = h0["war"].keys()[0] if not h0["war"].is_empty() else h0["solutions"][0]
	Residents.resolve_hook(h0["id"], sol)
	check(Residents.resident(h0["giver"])["op"]["player"] > before, "resolving a hook raises the giver's opinion of you")
	check(h0["war"].is_empty() or not shifts.is_empty(), "solutions that favour a power shift the war")
	var gen_id := -1
	for id in fl["residents"]:
		if Residents.resident(id)["tier"] == "generated":
			gen_id = id
			break
	var tpl := Residents.to_actor_template(gen_id)
	check(tpl.has("gen") and tpl["gen"].has("archetype") and tpl["stats"].has("str") and tpl["dialogue"] == "res:%d" % gen_id, "residents become actor templates with a character-system gen block")

	var hollow: Dictionary = Residents.settlement("hollowbridge")
	var hollow_pop: int = hollow["residents"].size()
	for id in hollow["residents"]:
		var r: Dictionary = Residents.resident(id)
		r["op"]["compact"] = -90.0
		r["lean"] = -80
	Residents.set_holder("hollowbridge", "compact")
	check(hollow["held_by"] == "compact", "a power can take a town")
	_advance_days(12)
	check(hollow["residents"].size() < hollow_pop, "people leave a town held by a power they hate (%d -> %d)" % [hollow_pop, hollow["residents"].size()])
	var fallen := false
	for hid in Residents.hooks:
		if Residents.hooks[hid]["sid"] == "hollowbridge" and Residents.hooks[hid]["template"] == "town_fallen":
			fallen = true
	check(fallen, "a town changing hands raises 'new masters' hooks")
	var world_count := 0
	for sid in w["order"]:
		world_count += w["settlements"][sid]["residents"].size()
	var alive := 0
	for r in w["residents"]:
		if r["alive"]:
			alive += 1
	check(world_count == alive, "nobody is lost or duplicated when people move, die or are born (%d)" % alive)

	print("\n%d checks, %d failures" % [checks, failures])
	get_tree().quit(1 if failures > 0 else 0)


func _advance_days(n: int) -> void:
	for i in n * 24:
		GameState.minutes += 60.0
		Residents.advance_clock()
		Residents.flush()


func _avg_money_after(s: Dictionary, days: int, hourly: bool) -> float:
	var saved: int = s["lod"]
	var day := GameState.day()
	for d in days:
		if hourly:
			for h in 24:
				for id in s["residents"]:
					var r: Dictionary = Residents.resident(id)
					Residents.advance_needs(r, s, 1.0 / 24.0)
		else:
			for id in s["residents"]:
				Residents.advance_needs(Residents.resident(id), s, 1.0)
	s["lod"] = saved
	var t := 0.0
	for id in s["residents"]:
		t += Residents.resident(id)["needs"]["money"]
	return t / s["residents"].size()


func _count_pool(s: Dictionary, pool: String) -> int:
	var n := 0
	for id in s["residents"]:
		var j: String = Residents.resident(id)["job"]
		if j != "" and Residents.jobs[j]["pool"] == pool:
			n += 1
	return n


func _find(s: Dictionary, f: Callable) -> Dictionary:
	for id in s["residents"]:
		var r: Dictionary = Residents.resident(id)
		if f.call(r):
			return r
	return {}
