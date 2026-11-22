extends Node
## Town preview: generates the world, runs one settlement (or the whole
## world) for some game days, and prints a report: census, sample residents
## with their day, needs, gossip spread, quest hooks and life events.
##
##   godot --headless res://tests/town_preview.tscn -- --settlement=fennicks_landing --days=7
##   godot --headless res://tests/town_preview.tscn -- --world --days=3
##   options: --seed=N  --deed  (inject a test rumour on day 2)  --holder=combine (hand the town over on day 3)
##            --out=/path/report.md (also write the report to a file)

var lines: PackedStringArray = []


func out(t := "") -> void:
	print(t)
	lines.append(t)


func _ready() -> void:
	var sid := "fennicks_landing"
	var days := 7
	var seed := 1
	var whole := false
	var deed := false
	var holder := ""
	var out_path := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--settlement="):
			sid = a.substr(13)
		elif a.begins_with("--days="):
			days = int(a.substr(7))
		elif a.begins_with("--seed="):
			seed = int(a.substr(7))
		elif a == "--world":
			whole = true
		elif a == "--deed":
			deed = true
		elif a.begins_with("--holder="):
			holder = a.substr(9)
		elif a.begins_with("--out="):
			out_path = a.substr(6)
	GameState.reset()
	GameState.clock_running = false
	var t0 := Time.get_ticks_msec()
	Residents.generate(seed)
	Residents.auto_tick = false
	var gen_ms := Time.get_ticks_msec() - t0
	if not Residents.world["settlements"].has(sid):
		printerr("Unknown settlement ", sid)
		get_tree().quit(1)
		return
	Residents.set_active(sid)
	var s: Dictionary = Residents.settlement(sid)
	out("# Town preview: %s" % s["name"])
	out("Seed %d. World: %d residents in %d settlements, generated in %d ms." % [seed, Residents.population(), Residents.world["order"].size(), gen_ms])
	if whole:
		_world_census()
	_census(s)
	var samples := _pick_samples(s)
	out("\n## A day in the life (day 1)")
	for id in samples:
		_print_day(Residents.resident(id), s)
	out("\n## Simulating %d days" % days)
	var tick_ms := 0
	var day_ms := 0
	var start_hooks: int = Residents.stats["hooks"]
	for d in days:
		for h in 24:
			GameState.minutes += 60.0
			var ta := Time.get_ticks_msec()
			Residents.advance_clock()
			Residents.flush()
			var el := Time.get_ticks_msec() - ta
			if GameState.hour() == 0:
				day_ms += el
			else:
				tick_ms += el
			if deed and GameState.day() == 2 and GameState.hour() == 10:
				Residents.report_deed(sid, {"id": "preview_deed", "text": "Someone relit the pumphouse boiler.", "pool": "gear", "good": 0.3, "mag": 25})
			if holder != "" and GameState.day() == 3 and GameState.hour() == 9:
				Residents.set_holder(sid, holder)
		out("Day %d: %s" % [GameState.day() - 1, _needs_line(s)])
		for ru_id in s["rumors"]:
			var ru: Dictionary = Residents.rumors[ru_id]
			out("    rumour '%s': heard by %d of %d" % [ru["text"], ru["heard"], s["residents"].size()])
	out("\nTiming: %d hourly ticks (all NEAR+ACTIVE settlements) took %d ms in total; %d day passes over the whole world took %d ms (%.1f ms per day)." % [days * 23, tick_ms, days, day_ms, float(day_ms) / maxi(1, days)])
	out("\n## Quest hooks raised in %s" % s["name"])
	for hid in Residents.hooks:
		var h: Dictionary = Residents.hooks[hid]
		if h["sid"] == sid:
			out("- [%s] %s, from %s (%s): \"%s\" Paths: %s" % [h["state"], h["name"], Residents.full_name(Residents.resident(h["giver"])), Residents.job_name(Residents.resident(h["giver"])).to_lower(), h["pitch"], ", ".join(h["solutions"])])
	out("World total: %d hooks raised in %d days." % [Residents.stats["hooks"] - start_hooks, days])
	out("\n## Town log")
	for l in s["log"]:
		out("- " + l)
	out("\nWorld life events: %s" % str(Residents.stats))
	out("Support by power in %s (share with opinion > 25): %s" % [s["name"], _fmt_support(Residents.support(sid))])
	if out_path != "":
		var f := FileAccess.open(out_path, FileAccess.WRITE)
		f.store_string("\n".join(lines))
	get_tree().quit()


func _fmt_support(d: Dictionary) -> String:
	var p: PackedStringArray = []
	for k in d:
		p.append("%s %d%%" % [k, roundi(d[k] * 100)])
	return ", ".join(p)


func _world_census() -> void:
	out("\n## World")
	out("| Settlement | Region | Kind | Residents | Held by | Resonance |")
	out("|---|---|---|---|---|---|")
	for sid in Residents.world["order"]:
		var s: Dictionary = Residents.world["settlements"][sid]
		out("| %s | %s | %s | %d | %s | %d |" % [s["name"], s["region"], s["kind"], s["residents"].size(), s["held_by"], s["resonance"]])


func _census(s: Dictionary) -> void:
	var races := {}
	var jobs := {}
	var tiers := {}
	var facs := {}
	for id in s["residents"]:
		var r: Dictionary = Residents.resident(id)
		races[r["race"]] = races.get(r["race"], 0) + 1
		var jn := Residents.job_name(r)
		jobs[jn] = jobs.get(jn, 0) + 1
		tiers[r["tier"]] = tiers.get(r["tier"], 0) + 1
		for f in r["factions"]:
			facs[f] = facs.get(f, 0) + 1
	out("\n## %s (%s, %s)" % [s["name"], s["kind"], Residents.world["regions"][s["region"]]["name"]])
	out("%d residents in %d households, %d places. Held by %s. Resonance %d, threat %d. Roads to: %s." % [s["residents"].size(), s["households"].size(), s["places"].size(), s["held_by"], s["resonance"], s["threat"], ", ".join(s["links"].map(func(l): return Residents.settlement(l)["name"]))])
	out("Races: " + _fmt(races))
	out("Tiers: " + _fmt(tiers))
	out("Jobs: " + _fmt(jobs))
	out("Minor factions: " + _fmt(facs))


func _fmt(d: Dictionary) -> String:
	var keys := d.keys()
	keys.sort_custom(func(a, b): return d[a] > d[b])
	var p: PackedStringArray = []
	for k in keys:
		p.append("%s %d" % [k, d[k]])
	return ", ".join(p)


func _pick_samples(s: Dictionary) -> Array:
	var out_ids: Array = []
	var seen_jobs := {}
	for id in s["residents"]:
		var r: Dictionary = Residents.resident(id)
		if seen_jobs.has(r["job"]) or out_ids.size() >= 5:
			continue
		seen_jobs[r["job"]] = true
		out_ids.append(id)
	return out_ids


func _print_day(r: Dictionary, s: Dictionary) -> void:
	out("\n**%s**, %s %s, age %d, %s. Traits: %s. Lean %+d.%s" % [Residents.full_name(r), r["race"], ("(" + r["heritage"] + ")") if r["heritage"] != "" else "", r["age"], Residents.job_name(r).to_lower(), ", ".join(r["traits"]), r["lean"], (" Problem: " + Residents.gen.problems[r["problem"]]["text"] + ".") if r["problem"] != "" else ""])
	var parts: PackedStringArray = []
	var last := ""
	for h in 24:
		var b := ResidentSchedule.block_at(Residents, r, s, 1, h)
		var label := "%s at %s" % [b[1], s["places"][b[0]]["name"]]
		if label != last:
			parts.append("%02d:00 %s" % [h, label])
			last = label
	out("  " + "; ".join(parts))


func _needs_line(s: Dictionary) -> String:
	var tot := {"money": 0.0, "safety": 0.0, "belonging": 0.0, "conviction": 0.0}
	var op := 0.0
	for id in s["residents"]:
		var r: Dictionary = Residents.resident(id)
		for k in tot:
			tot[k] += r["needs"][k]
		op += r["op"]["player"]
	var n: int = maxi(1, s["residents"].size())
	return "avg money %d, safety %d, belonging %d, conviction %d; opinion of you %+.1f; %d residents" % [tot["money"] / n, tot["safety"] / n, tot["belonging"] / n, tot["conviction"] / n, op / n, s["residents"].size()]
