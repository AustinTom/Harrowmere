class_name ResidentSchedule
extends RefCounted
## Where a resident is and what they're doing at a given day and hour.
## Pure function of (resident, settlement, day, hour): nothing is stored, so
## 25,000 schedules cost no memory, and any LOD can ask at any time.
##
## Rules, in order: sleep at home, work shift (every 7th day off, offset per
## person), school for children, a meal at home, otherwise leisure. Leisure
## is picked per 2-hour block from venues in the resident's district,
## weighted by traits, age, lean and time of day.

const LEISURE_BASE := {"home": 3.0, "square": 1.5, "market": 1.0, "tavern": 1.2, "shrine": 0.6, "temple": 0.6, "library": 0.2, "workshop": 0.0}


static func shift_of(jobs: Dictionary, shifts: Dictionary, r: Dictionary) -> Array:
	if r["job"] == "":
		return []
	return shifts.get(str(jobs[r["job"]].get("shift", "day")), [])


static func in_shift(shift: Array, hour: int) -> bool:
	for span in shift:
		var a := int(span[0])
		var b := int(span[1])
		if (hour >= a and hour < b) or (b > 24 and hour < b - 24):
			return true
	return false


static func is_rest_day(r: Dictionary, day: int) -> bool:
	return (day + int(r["id"])) % 7 == 0


## Returns [place_index, activity]. Activities: sleep, wake, eat, work,
## study, leisure.
static func block_at(sim, r: Dictionary, s: Dictionary, day: int, hour: int) -> Array:
	var home: int = r["home"]
	var rd: Dictionary = sim.races[r["race"]]
	var age := int(r["age"])
	var tr: Array = r["traits"]
	var shift := shift_of(sim.jobs, sim.shifts, r)
	var night := not shift.is_empty() and int(shift[0][1]) > 24
	var wake := 6
	var bed := 22
	if age < int(rd["adult"]):
		wake = 7
		bed = 20
	elif age >= int(rd["elder"]):
		bed = 21
	for t in tr:
		wake += int(sim.traits[t].get("wake", 0))
		bed += int(sim.traits[t].get("bed", 0))
	if r["race"] == "wrought":
		wake = 0
		bed = 24
	var asleep: bool
	if night:
		asleep = hour >= 8 and hour < 16
	else:
		asleep = hour < wake or hour >= bed
	var resting := is_rest_day(r, day)
	if not resting and r["work"] >= 0 and in_shift(shift, hour):
		return [r["work"], "work"]
	if asleep:
		return [home, "sleep"]
	if age < int(rd["adult"]):
		if age >= PopulationGen.CHILD_AGE and age < PopulationGen.SCHOOL_END and day % 7 != 0 and hour >= 8 and hour < 14:
			var school := venue(s, r["district"], "school", r["seed"])
			if school >= 0:
				return [school, "study"]
		if age < PopulationGen.CHILD_AGE:
			return [home, "leisure"]
	if r["race"] != "wrought" and (hour == wake or (hour == 12 and not night)):
		return [home, "eat"]
	return [leisure_place(sim, r, s, day, hour), "leisure"]


static func leisure_place(sim, r: Dictionary, s: Dictionary, day: int, hour: int) -> int:
	var weights: Dictionary = LEISURE_BASE.duplicate()
	if hour >= 17:
		weights["tavern"] *= 2.5
		weights["market"] = 0.0
	if hour >= 23 or hour < 6:
		for k in ["square", "market", "shrine", "temple", "library", "workshop"]:
			weights[k] = 0.0
	elif hour < 8:
		weights["tavern"] = 0.0
	if int(r["lean"]) > 30:
		weights["shrine"] += 1.0
		weights["temple"] += 1.0
	if int(r["age"]) < int(sim.races[r["race"]]["adult"]):
		weights["tavern"] = 0.0
		weights["square"] += 2.0
	for t in r["traits"]:
		var lw: Dictionary = sim.traits[t].get("leisure", {})
		for k in lw:
			weights[k] = float(weights.get(k, 0.0)) + float(lw[k])
	var hv := hash([r["seed"], day, hour / 2])
	var total := 0.0
	for k in weights:
		if k != "home" and not s["venues"][r["district"]].has(k):
			weights[k] = 0.0
		total += float(weights[k])
	var roll := float(hv % 10000) / 10000.0 * total
	for k in weights:
		roll -= float(weights[k])
		if roll <= 0.0:
			if k == "home":
				return r["home"]
			return venue(s, r["district"], k, hv)
	return r["home"]


static func venue(s: Dictionary, di: int, kind: String, h: int) -> int:
	var l: Array = s["venues"][di].get(kind, [])
	if l.is_empty():
		return -1
	return l[absi(h) % l.size()]


## One readable line: "works 7:00-17:00 at Millfield's smithy".
static func describe(sim, r: Dictionary, s: Dictionary) -> String:
	var shift := shift_of(sim.jobs, sim.shifts, r)
	if shift.is_empty() or r["work"] < 0:
		return ""
	var spans: PackedStringArray = []
	for span in shift:
		var e := int(span[1]) % 24
		spans.append("%d:00 to %s" % [int(span[0]), "midnight" if e == 0 else "%d:00" % e])
	return "%s, %s" % [s["places"][r["work"]]["name"], " and ".join(spans)]
