extends Node
## Resident simulation (autoload "Residents").
##
## Holds every generated resident in the world and keeps them living at
## three levels of detail, chosen per settlement:
##   ACTIVE  the settlement whose area is loaded. Hourly ticks, and
##           ResidentPresence turns the residents who are outdoors on the
##           map into Actors that walk their schedules.
##   NEAR    settlements one road away. Hourly ticks: needs, where everyone
##           is, gossip spreading person to person between people who share
##           a place that hour.
##   FAR     everything else. One cheap summary tick per game day: needs
##           drift toward their equilibrium, rumours spread by a logistic
##           curve.
## Every settlement, at every LOD, also gets the daily pass: opinions, aging,
## births, deaths, newcomers, emigration, and quest hooks.
##
## Work is queued and time-sliced: at most budget_per_frame residents are
## processed per frame, so a day change across 25,000 people never hitches.
##
## Other systems talk to this through Events (quest_hook_created,
## quest_hook_accepted, rumor_started, settlement_changed_hands, war_shift)
## and the public functions below: report_deed, accept_hook, resolve_hook,
## set_holder, to_actor_template, build_dialogue.

const FAR := 0
const NEAR := 1
const ACTIVE := 2
const LOD_NAMES := ["far", "near", "active"]
const RUMOR_LIFE_DAYS := 20
const HOOK_LIFE_DAYS := 14
const MAX_CATCHUP_HOURS := 48

var world: Dictionary = {}
var gen: PopulationGen
var jobs: Dictionary = {}
var shifts: Dictionary = {}
var races: Dictionary = {}
var traits: Dictionary = {}
var templates: Dictionary = {}
var lines: Dictionary = {}
var factions: Dictionary = {}
var hooks: Dictionary = {}
var rumors: Dictionary = {}
var is_ready := false
var auto_tick := true
var budget_per_frame := 300
var active_sid := ""
var area_deeds: Array = []
## Resident ids currently on screen as Actors (set by ResidentPresence).
var visible_ids: Dictionary = {}
var stats := {"births": 0, "deaths": 0, "arrivals": 0, "departures": 0, "hooks": 0, "rumors": 0}

var rng := RandomNumberGenerator.new()
var _queue: Array = []
var _last_hour := -1
var _next_hook := 1
var _next_rumor := 1
var _loc_res: Dictionary = {}


func _ready() -> void:
	Events.flags_changed.connect(_on_flags_changed)
	Events.resonance_changed.connect(_on_resonance_changed)


# ================================================================ setup

func ensure_world(world_seed := 1) -> void:
	if not is_ready:
		generate(world_seed)


func generate(world_seed: int) -> void:
	gen = PopulationGen.new()
	jobs = gen.jobs
	shifts = gen.data["jobs"]["shifts"]
	races = gen.races
	traits = gen.traits
	factions = gen.factions
	templates = DB.load_json("res://data/residents/quest_templates.json").get("templates", {})
	lines = DB.load_json("res://data/residents/lines.json")
	world = gen.generate_world(world_seed)
	rng.seed = PopulationGen.seed_for(world_seed, "sim")
	hooks = {}
	rumors = {}
	_queue = []
	visible_ids = {}
	active_sid = ""
	stats = {"births": 0, "deaths": 0, "arrivals": 0, "departures": 0, "hooks": 0, "rumors": 0}
	_last_hour = _abs_hour()
	is_ready = true
	for sid in world["order"]:
		_refresh_places(world["settlements"][sid], _day(), _hour())


func reset() -> void:
	is_ready = false
	world = {}
	hooks = {}
	rumors = {}
	_queue = []
	visible_ids = {}
	active_sid = ""
	area_deeds = []


func settlement(sid: String) -> Dictionary:
	return world["settlements"].get(sid, {})


func resident(id: int) -> Dictionary:
	if id < 0 or id >= world["residents"].size():
		return {}
	return world["residents"][id]


func population() -> int:
	var n := 0
	for sid in world["order"]:
		n += world["settlements"][sid]["residents"].size()
	return n


## Makes sid the ACTIVE settlement, its road neighbours NEAR, the rest FAR.
func set_active(sid: String) -> void:
	active_sid = sid
	for id in world["order"]:
		world["settlements"][id]["lod"] = FAR
	var s := settlement(sid)
	if s.is_empty():
		return
	s["lod"] = ACTIVE
	for l in s["links"]:
		world["settlements"][l]["lod"] = NEAR
	_refresh_places(s, _day(), _hour())


## Called by World when an area with a "settlement" key loads.
func bind_area(area: Dictionary) -> void:
	ensure_world(int(area.get("world_seed", 1)))
	var sid := str(area.get("settlement", ""))
	if not world["settlements"].has(sid):
		push_warning("Area names unknown settlement: " + sid)
		return
	set_active(sid)
	area_deeds = area.get("deeds", []).duplicate(true)
	for d in area_deeds:
		d["fired"] = false
	_loc_res = {}
	for l in GameState.locations:
		_loc_res[l["id"]] = int(l["resonance"])


# ================================================================ clock

func _abs_hour() -> int:
	return int(GameState.minutes / 60.0)


func _day() -> int:
	return GameState.day()


func _hour() -> int:
	return GameState.hour()


func _process(_delta: float) -> void:
	if not is_ready or not auto_tick:
		return
	advance_clock()
	work(budget_per_frame)


## Turns elapsed game hours into queued ticks. A long skip (resting,
## travelling) becomes whole-day summaries instead of hundreds of hourly
## ticks.
func advance_clock() -> void:
	var now := _abs_hour()
	if now <= _last_hour:
		return
	if now - _last_hour > MAX_CATCHUP_HOURS:
		var first_day := _last_hour / 24 + 1
		var last_day := now / 24
		for d in range(first_day, last_day + 1):
			for sid in world["order"]:
				_queue.append({"kind": "day", "sid": sid, "day": d, "summary": true, "i": 0})
		_last_hour = now - 1
	while _last_hour < now:
		_last_hour += 1
		var h := _last_hour % 24
		var d := _last_hour / 24 + 1
		if h == 0:
			for sid in world["order"]:
				_queue.append({"kind": "day", "sid": sid, "day": d - 1, "summary": world["settlements"][sid]["lod"] == FAR, "i": 0})
		for sid in world["order"]:
			var s: Dictionary = world["settlements"][sid]
			if s["lod"] == ACTIVE:
				# The loaded town goes first. A town is run on the spot so presence
				# reads it this frame; a big city is spread over a few frames.
				var item := {"kind": "hour", "sid": sid, "day": d, "hour": h, "i": 0}
				if s["residents"].size() <= 400:
					_run_now(item)
				else:
					_queue.push_front(item)
			elif s["lod"] == NEAR:
				_queue.append({"kind": "hour", "sid": sid, "day": d, "hour": h, "i": 0})


func _run_now(item: Dictionary) -> void:
	while not _step(item, 1 << 30):
		pass


## Processes up to `budget` residents of queued work. Returns true when the
## queue is empty.
func work(budget: int) -> bool:
	while budget > 0 and not _queue.is_empty():
		var item: Dictionary = _queue[0]
		var before: int = item["i"]
		var done := _step(item, budget)
		budget -= maxi(1, int(item["i"]) - before)
		if done:
			_queue.pop_front()
	return _queue.is_empty()


func pending() -> int:
	return _queue.size()


## Runs everything queued, for tests and tools.
func flush() -> void:
	while not work(1 << 30):
		pass


func _step(item: Dictionary, budget: int) -> bool:
	var s := settlement(item["sid"])
	if s.is_empty():
		return true
	var ids: Array = s["residents"]
	var start: int = item["i"]
	var end := mini(ids.size(), start + budget)
	if item["kind"] == "hour":
		if start == 0:
			item["occ"] = {}
		for k in range(start, end):
			_hour_resident(s, world["residents"][ids[k]], item)
		item["i"] = end
		if end >= ids.size():
			_hour_gossip(s, item["occ"])
			return true
		return false
	# Daily pass.
	if start == 0:
		item["dead"] = []
	for k in range(start, end):
		_day_resident(s, world["residents"][ids[k]], item)
	item["i"] = end
	if end >= ids.size():
		_day_settlement(s, item)
		return true
	return false


# ================================================================ hourly

func _hour_resident(s: Dictionary, r: Dictionary, item: Dictionary) -> void:
	var b := ResidentSchedule.block_at(self, r, s, item["day"], item["hour"])
	r["at"] = b[0]
	r["act"] = b[1]
	var kind: String = s["places"][b[0]]["kind"] if b[0] >= 0 else "home"
	advance_needs(r, s, 1.0 / 24.0, kind, b[1])
	if b[1] != "sleep":
		var occ: Dictionary = item["occ"]
		if not occ.has(b[0]):
			occ[b[0]] = []
		occ[b[0]].append(r["id"])


## People awake in the same place pass rumours on. Each person who knows a
## rumour gives everyone else there a chance to hear it this hour.
func _hour_gossip(s: Dictionary, occ: Dictionary) -> void:
	var live := _live_rumors(s)
	if live.is_empty():
		return
	for pi in occ:
		var group: Array = occ[pi]
		if group.size() < 2:
			continue
		for ru in live:
			var rid: int = ru["id"]
			var strength := 0.0
			for id in group:
				var r: Dictionary = world["residents"][id]
				if r["heard"].has(rid):
					strength += _gossip_mult(r)
			if strength <= 0.0:
				continue
			var p := 1.0 - pow(0.86, strength)
			for id in group:
				var r: Dictionary = world["residents"][id]
				if not r["heard"].has(rid) and rng.randf() < p:
					hear(r, ru)


func _gossip_mult(r: Dictionary) -> float:
	var m := 1.0
	for t in r["traits"]:
		m *= float(traits[t].get("gossip", 1.0))
	return m


# ================================================================ needs

func wage_of(r: Dictionary, s: Dictionary) -> float:
	if r["job"] != "":
		return float(jobs[r["job"]].get("wage", 1)) * float(s["prosperity"])
	var adult := int(races[r["race"]]["adult"])
	if int(r["age"]) < adult or r["spouse"] >= 0:
		return 1.5 * float(s["prosperity"])
	return 0.7


## Moves needs toward their equilibrium. dt is in days: hourly ticks pass
## 1/24 and the far summary passes 1, so both LODs land in the same place.
## place_kind/act add the short-term effect of what they're doing now.
func advance_needs(r: Dictionary, s: Dictionary, dt: float, place_kind := "", act := "") -> void:
	var n: Dictionary = r["needs"]
	var lean := float(r["lean"])
	var tr: Array = r["traits"]
	var noise := 4.0 * sqrt(dt)
	# Money
	var money_eq := 50.0 + 37.5 * (wage_of(r, s) - 1.5)
	var mrate := 0.08
	for t in tr:
		mrate *= float(traits[t].get("money_rate", 1.0))
	n["money"] = clampf(n["money"] + (money_eq - n["money"]) * mrate * dt + rng.randf_range(-noise, noise), 0, 100)
	# Safety
	var safety_eq := 100.0 - float(s["threat"]) * 1.2
	if "timid" in tr:
		safety_eq -= 12.0
	n["safety"] = clampf(n["safety"] + (safety_eq - n["safety"]) * 0.3 * dt + rng.randf_range(-noise, noise), 0, 100)
	# Belonging
	var hh_size: int = s["households"][r["hh"]]["members"].size()
	var bel_eq: float = 40.0 + 6.0 * hh_size + 4.0 * r["friends"].size()
	var brate := 0.1
	for t in tr:
		brate *= float(traits[t].get("belonging_rate", 1.0))
	if "gossip" in tr:
		bel_eq += 8.0
	if _day() - int(r["since_day"]) < 30:
		bel_eq -= 15.0
	n["belonging"] = clampf(n["belonging"] + (bel_eq - n["belonging"]) * brate * dt + rng.randf_range(-noise, noise), 0, 100)
	# Conviction: does this place's Resonance suit how they lean?
	var res := float(s["districts"][r["district"]]["resonance"])
	var conv_eq := 100.0 - absf(res - (50.0 + lean * 0.5)) * 1.6
	var crate := 0.1
	for t in tr:
		crate *= float(traits[t].get("conviction_rate", 1.0))
	n["conviction"] = clampf(n["conviction"] + (conv_eq - n["conviction"]) * crate * dt + rng.randf_range(-noise, noise), 0, 100)
	if act == "leisure":
		if place_kind == "tavern":
			n["belonging"] = minf(100, n["belonging"] + 1.0)
		elif place_kind == "shrine" or place_kind == "temple":
			n["conviction"] = clampf(n["conviction"] + (1.5 if lean > 0 else -0.5), 0, 100)
		elif place_kind == "square" or place_kind == "market":
			n["belonging"] = minf(100, n["belonging"] + 0.4)


## The power a resident would like to see hold their town, from lean and
## how their needs are going under the current holder.
func _opinion_targets(r: Dictionary, s: Dictionary) -> Dictionary:
	var lean := float(r["lean"])
	var n: Dictionary = r["needs"]
	var t := {"combine": -lean * 0.6, "compact": lean * 0.6, "meridian": 15.0 - absf(lean) * 0.4}
	var holder: String = s["held_by"]
	if t.has(holder):
		t[holder] += (n["money"] - 50.0) * 0.25 + (n["safety"] - 50.0) * 0.25
	for f in r["factions"]:
		var leans := str(factions["minor"][f].get("leans", ""))
		if t.has(leans):
			t[leans] += 15.0
	return t


# ================================================================ daily

func _day_resident(s: Dictionary, r: Dictionary, item: Dictionary) -> void:
	var day: int = item["day"]
	if item.get("summary", false):
		advance_needs(r, s, 1.0)
	var targets := _opinion_targets(r, s)
	for p in targets:
		r["op"][p] = clampf(r["op"][p] + (targets[p] - r["op"][p]) * 0.05, -100, 100)
	r["op"]["player"] *= 0.995
	# Aging, coming of age, death.
	var rd: Dictionary = races[r["race"]]
	if day % 360 == int(r["bday"]):
		r["age"] += 1
		if int(r["age"]) == int(rd["adult"]) and r["job"] == "":
			_give_labor_job(s, r)
	var elder := float(rd["elder"])
	var max_age := float(rd["max_age"])
	if float(r["age"]) > elder:
		var p := 0.00003 + pow((float(r["age"]) - elder) / maxf(1.0, max_age - elder), 3.0) * 0.004
		if float(r["age"]) >= max_age or rng.randf() < p:
			item["dead"].append(r["id"])
			return
	# Quest hooks: one roll against the summed chance, then check the pick.
	if rng.randf() < 0.2:
		_try_hook(s, r, day)


func _day_settlement(s: Dictionary, item: Dictionary) -> void:
	var day: int = item["day"]
	for id in item["dead"]:
		_kill(s, world["residents"][id], day)
	# Rumours in summary mode, and rumours travelling down the roads.
	for ru in _live_rumors(s):
		if s["lod"] == FAR:
			_spread_summary(s, ru)
		if not ru["sent"] and ru["hops"] < 2 and ru["heard"] >= int(s["residents"].size() * 0.3):
			ru["sent"] = true
			for l in s["links"]:
				_seed_rumor(world["settlements"][l], ru)
	# Births.
	var pop: int = s["residents"].size()
	var expected := float(pop) * 0.03 / 360.0
	var births := int(expected)
	if rng.randf() < expected - births:
		births += 1
	for i in births:
		_birth(s, day)
	# The Thaw keeps people coming: towns under their target take newcomers.
	if pop < int(s["pop_target"] * 0.98) and rng.randf() < 0.35:
		_newcomers(s, day)
	# Unhappy households leave towns held by a power they hate.
	_emigration(s, day)
	# Expire old hooks.
	for hid in s["hooks"].duplicate():
		var h: Dictionary = hooks[hid]
		if h["state"] == "open" and day > int(h["expires"]):
			h["state"] = "expired"
		if h["state"] in ["expired", "done"]:
			s["hooks"].erase(hid)
			var g := resident(h["giver"])
			if not g.is_empty():
				g["hooks"].erase(hid)


func _give_labor_job(s: Dictionary, r: Dictionary) -> void:
	var dist: Dictionary = s["districts"][r["district"]]
	var key: String = dist["kind"] if s["kind"] == "city" else s["specialty"]
	var labor_map: Dictionary = gen.data["jobs"]["specialty_labor"] if s["kind"] == "town" else gen.data["jobs"]["district_labor"]
	var labor := str(labor_map.get(key, "laborer"))
	var lr: Array = jobs[labor].get("res", [0, 100])
	if int(dist["resonance"]) < int(lr[0]) or int(dist["resonance"]) > int(lr[1]):
		labor = "laborer"
	gen._give_job(s, r["district"], rng, r["id"], labor)


func _kill(s: Dictionary, r: Dictionary, day: int) -> void:
	r["alive"] = false
	s["residents"].erase(r["id"])
	s["households"][r["hh"]]["members"].erase(r["id"])
	if r["spouse"] >= 0:
		world["residents"][r["spouse"]]["spouse"] = -1
	for hid in r["hooks"]:
		hooks[hid]["state"] = "expired"
	stats["deaths"] += 1
	_log(s, day, "%s died, aged %d." % [full_name(r), r["age"]])


func _birth(s: Dictionary, day: int) -> void:
	for attempt in 6:
		var mid: int = s["residents"][rng.randi() % s["residents"].size()]
		var m: Dictionary = world["residents"][mid]
		if m["sex"] != "f" or m["spouse"] < 0:
			continue
		var rd: Dictionary = races[m["race"]]
		var age := int(m["age"])
		if age < int(rd["adult"]) or age > int(rd["adult"]) + (int(rd["elder"]) - int(rd["adult"])) / 2:
			continue
		if m["kids"].size() >= 5:
			continue
		var id := gen._new_resident(s, m["district"], rng, m["race"], m["family"], 0, m["hh"])
		var c: Dictionary = world["residents"][id]
		c["parents"] = [mid, m["spouse"]]
		c["since_day"] = day
		m["kids"].append(id)
		world["residents"][m["spouse"]]["kids"].append(id)
		s["households"][m["hh"]]["members"].append(id)
		gen._init_state(s, c, rng)
		stats["births"] += 1
		_log(s, day, "%s had a child, %s." % [full_name(m), c["given"]])
		return


func _newcomers(s: Dictionary, day: int) -> void:
	var di: int = rng.randi() % s["districts"].size()
	var mix: Dictionary = {}
	for reg in gen.data["settlements"]["regions"]:
		if reg["id"] == s["region"]:
			mix = reg["race_mix"]
	var members := gen._make_household(s, di, rng, mix)
	for id in members:
		var r: Dictionary = world["residents"][id]
		r["since_day"] = day
		if gen._is_working_age(r) and rng.randf() < 0.85:
			_give_labor_job(s, r)
		var friend = PopulationGen.pick(rng, s["residents"])
		if friend != null and friend != id:
			r["friends"].append(friend)
		gen._init_state(s, r, rng)
		gen._join_factions(s, r, rng, s["region"])
	stats["arrivals"] += members.size()
	_log(s, day, "The %s family arrived off the road." % world["residents"][members[0]]["family"])


func _emigration(s: Dictionary, day: int) -> void:
	if s["lod"] == ACTIVE and s["residents"].size() < 40:
		return
	var holder: String = s["held_by"]
	var tries := maxi(1, s["households"].size() / 20)
	for i in tries:
		var hi: int = rng.randi() % s["households"].size()
		var hh: Dictionary = s["households"][hi]
		if hh["members"].is_empty() or hh.get("gone", false):
			continue
		var head: Dictionary = world["residents"][hh["members"][0]]
		if head.get("tier", "") == "anchor" or float(head["op"].get(holder, 0.0)) > -55.0:
			continue
		if rng.randf() > 0.15:
			continue
		var best := ""
		var best_op := float(head["op"][holder])
		for l in s["links"]:
			var o: Dictionary = world["settlements"][l]
			var v := float(head["op"].get(o["held_by"], 0.0))
			if v > best_op + 20.0:
				best_op = v
				best = l
		if best != "":
			move_household(s, hi, world["settlements"][best], day)


## Moves a whole household to another settlement: new home there, labor
## jobs, and they remember where they came from.
func move_household(s: Dictionary, hi: int, dest: Dictionary, day: int) -> void:
	var hh: Dictionary = s["households"][hi]
	var members: Array = hh["members"].duplicate()
	hh["members"] = []
	hh["gone"] = true
	var di: int = rng.randi() % dest["districts"].size()
	var home := gen._add_place(dest, di, "home", hh["family"], -1)
	var new_hh := {"members": [], "home": home, "family": hh["family"]}
	dest["households"].append(new_hh)
	var nhi: int = dest["households"].size() - 1
	for id in members:
		var r: Dictionary = world["residents"][id]
		s["residents"].erase(id)
		dest["residents"].append(id)
		new_hh["members"].append(id)
		r["sid"] = dest["id"]
		r["district"] = di
		r["hh"] = nhi
		r["home"] = home
		r["since_day"] = day
		r["from"] = s["id"]
		r.erase("at")
		for hid in r["hooks"]:
			hooks[hid]["state"] = "expired"
		r["hooks"] = []
		if r["job"] != "":
			r["job"] = ""
			r["work"] = -1
			_give_labor_job(dest, r)
	stats["departures"] += members.size()
	_log(s, day, "The %s family packed up for %s." % [hh["family"], dest["name"]])
	_log(dest, day, "The %s family came over from %s." % [hh["family"], s["name"]])


func _log(s: Dictionary, day: int, text: String) -> void:
	s["log"].append("Day %d: %s" % [day, text])
	if s["log"].size() > 60:
		s["log"].pop_front()


# ================================================================ rumours

## Something happened that people will talk about. deed keys:
##   id, text (what people repeat), pool (gear/arcane/neutral: who approves),
##   good (+1/-1, how the town as a whole sees it), mag (opinion swing),
##   witnesses (resident ids who saw it), by_player (default true).
func report_deed(sid: String, deed: Dictionary) -> Dictionary:
	var s := settlement(sid)
	if s.is_empty():
		return {}
	var ru := {
		"id": _next_rumor, "deed": str(deed.get("id", "deed")), "origin": sid, "sid": sid,
		"text": str(deed.get("text", "")), "pool": str(deed.get("pool", "neutral")),
		"good": float(deed.get("good", 0)), "mag": float(deed.get("mag", 10)),
		"by_player": bool(deed.get("by_player", true)),
		"day": _day(), "heard": 0, "hops": 0, "sent": false,
	}
	_next_rumor += 1
	rumors[ru["id"]] = ru
	s["rumors"].append(ru["id"])
	stats["rumors"] += 1
	var witnesses: Array = deed.get("witnesses", [])
	if witnesses.is_empty():
		witnesses = visible_ids.keys() if sid == active_sid else []
	for id in witnesses:
		var r := resident(int(id))
		if not r.is_empty() and r["sid"] == sid:
			hear(r, ru)
	if ru["heard"] == 0:
		for i in 3:
			var id = PopulationGen.pick(rng, s["residents"])
			if id != null:
				hear(world["residents"][id], ru)
	Events.rumor_started.emit(ru)
	return ru


func hear(r: Dictionary, ru: Dictionary) -> void:
	if r["heard"].has(ru["id"]):
		return
	r["heard"][ru["id"]] = true
	ru["heard"] += 1
	if not ru["by_player"]:
		return
	r["op"]["player"] = clampf(r["op"]["player"] + rumor_reaction(r, ru) * ru["mag"], -100, 100)


## -1..1: how this resident feels about what the rumour says.
func rumor_reaction(r: Dictionary, ru: Dictionary) -> float:
	var align := 0.0
	if ru["pool"] == "gear":
		align = -float(r["lean"]) / 60.0
	elif ru["pool"] == "arcane":
		align = float(r["lean"]) / 60.0
	return clampf(0.4 * float(ru["good"]) + 0.6 * align, -1.0, 1.0)


func _live_rumors(s: Dictionary) -> Array:
	var out: Array = []
	var day := _day()
	for id in s["rumors"]:
		var ru: Dictionary = rumors[id]
		if day - int(ru["day"]) <= RUMOR_LIFE_DAYS and ru["heard"] < s["residents"].size():
			out.append(ru)
	return out


func _spread_summary(s: Dictionary, ru: Dictionary) -> void:
	var pop: int = s["residents"].size()
	var k: int = ru["heard"]
	if k <= 0 or k >= pop:
		return
	var grow := int(ceil(float(k) * 0.9 * (1.0 - float(k) / float(pop))))
	for i in grow * 3:
		if grow <= 0:
			break
		var r: Dictionary = world["residents"][s["residents"][rng.randi() % pop]]
		if not r["heard"].has(ru["id"]):
			hear(r, ru)
			grow -= 1


func _seed_rumor(dest: Dictionary, src: Dictionary) -> void:
	for id in dest["rumors"]:
		if rumors[id]["deed"] == src["deed"] and rumors[id]["origin"] == src["origin"]:
			return
	var ru: Dictionary = src.duplicate()
	ru["id"] = _next_rumor
	_next_rumor += 1
	ru["sid"] = dest["id"]
	ru["heard"] = 0
	ru["hops"] = int(src["hops"]) + 1
	ru["mag"] = float(src["mag"]) * 0.6
	ru["sent"] = false
	ru["day"] = _day()
	rumors[ru["id"]] = ru
	dest["rumors"].append(ru["id"])
	for i in 2:
		var id = PopulationGen.pick(rng, dest["residents"])
		if id != null:
			hear(world["residents"][id], ru)


# ================================================================ quest hooks

func _try_hook(s: Dictionary, r: Dictionary, day: int) -> void:
	if not r["hooks"].is_empty() or int(r["age"]) < int(races[r["race"]]["adult"]):
		return
	var cap := maxi(2, s["residents"].size() / 40)
	if s["hooks"].size() >= cap:
		return
	var weights := {}
	for tid in templates:
		weights[tid] = float(templates[tid].get("chance", 0.01))
	var tid: String = PopulationGen.pick_weighted(rng, weights)
	var t: Dictionary = templates[tid]
	if day < int(s["cooldowns"].get(tid, 0)):
		return
	if not _giver_fits(r, s, t.get("giver", {})) or not _town_fits(s, t.get("town", {})):
		return
	var roles := {}
	for role in t.get("roles", {}):
		var who := _fill_role(s, r, str(t["roles"][role]))
		if who < 0:
			return
		roles[role] = who
	create_hook(s, r, tid, roles, day)


func _cmp(v: float, spec: String) -> bool:
	if spec.begins_with("<"):
		return v < float(spec.substr(1))
	if spec.begins_with(">"):
		return v > float(spec.substr(1))
	return true


func _giver_fits(r: Dictionary, s: Dictionary, g: Dictionary) -> bool:
	for need in g.get("needs", {}):
		if not _cmp(float(r["needs"][need]), str(g["needs"][need])):
			return false
	if g.has("problem") and r["problem"] != g["problem"]:
		return false
	if g.has("traits_any"):
		var ok := false
		for t in g["traits_any"]:
			if t in r["traits"]:
				ok = true
		if not ok:
			return false
	if g.has("tags_any"):
		var tags: Array = jobs.get(r["job"], {}).get("tags", [])
		var ok := false
		for t in g["tags_any"]:
			if t in tags:
				ok = true
		if not ok:
			return false
	if g.has("factions_any"):
		var ok := false
		for f in g["factions_any"]:
			if f in r["factions"]:
				ok = true
		if not ok:
			return false
	if g.has("opinion_of_holder") and not _cmp(float(r["op"].get(s["held_by"], 0.0)), str(g["opinion_of_holder"])):
		return false
	return true


func _town_fits(s: Dictionary, c: Dictionary) -> bool:
	if c.has("resonance"):
		var rr: Array = c["resonance"]
		if int(s["resonance"]) < int(rr[0]) or int(s["resonance"]) > int(rr[1]):
			return false
	if c.has("threat_min") and int(s["threat"]) < int(c["threat_min"]):
		return false
	if c.has("kinds") and not (s["kind"] in c["kinds"]):
		return false
	if c.has("held_by") and not (s["held_by"] in c["held_by"]):
		return false
	if c.has("changed_hands_within") and _day() - int(s.get("changed_day", -9999)) > int(c["changed_hands_within"]):
		return false
	return true


## Finds a resident for a role. Returns -1 if nobody fits.
func _fill_role(s: Dictionary, giver: Dictionary, spec: String) -> int:
	var ids: Array = s["residents"]
	var adult_ok := func(r: Dictionary) -> bool:
		return r["id"] != giver["id"] and r["alive"] and int(r["age"]) >= int(races[r["race"]]["adult"])
	if spec == "household":
		for id in s["households"][giver["hh"]]["members"]:
			if id != giver["id"]:
				return id
		return -1
	if spec == "outsider":
		for attempt in 10:
			var l = PopulationGen.pick(rng, s["links"])
			if l == null:
				return -1
			var o: Dictionary = world["settlements"][l]
			var id = PopulationGen.pick(rng, o["residents"])
			if id != null and adult_ok.call(world["residents"][id]):
				return id
		return -1
	for attempt in 40:
		var id: int = ids[rng.randi() % ids.size()]
		var r: Dictionary = world["residents"][id]
		if not adult_ok.call(r):
			continue
		if spec == "neighbour" and r["district"] == giver["district"] and r["hh"] != giver["hh"]:
			return id
		if spec == "same_job" and r["job"] == giver["job"] and r["work"] != giver["work"]:
			return id
		if spec == "authority" and "authority" in jobs.get(r["job"], {}).get("tags", []):
			return id
		if spec.begins_with("job_tags:"):
			var want := spec.substr(9).split("|")
			var tags: Array = jobs.get(r["job"], {}).get("tags", [])
			for t in want:
				if t in tags:
					return id
	return -1


func create_hook(s: Dictionary, giver: Dictionary, tid: String, roles: Dictionary, day: int) -> Dictionary:
	var t: Dictionary = templates[tid]
	var h := {
		"id": _next_hook, "template": tid, "name": str(t.get("name", tid)), "sid": s["id"],
		"giver": giver["id"], "roles": roles, "day": day, "expires": day + HOOK_LIFE_DAYS,
		"state": "open", "solutions": t.get("solutions", []).duplicate(),
		"war": t.get("war", {}).duplicate(), "pitch": "",
	}
	_next_hook += 1
	h["pitch"] = _fill_text(str(t.get("pitch", "")), s, h)
	hooks[h["id"]] = h
	s["hooks"].append(h["id"])
	giver["hooks"].append(h["id"])
	s["cooldowns"][tid] = day + int(t.get("cooldown", 10)) / maxi(1, s["districts"].size())
	stats["hooks"] += 1
	Events.quest_hook_created.emit(h)
	return h


func _fill_text(text: String, s: Dictionary, h: Dictionary) -> String:
	var out := text
	for role in h["roles"]:
		var r := resident(h["roles"][role])
		out = out.replace("{%s}" % role, full_name(r))
		var town := settlement(r["sid"])
		out = out.replace("{%s_town}" % role, str(town.get("name", "")))
	var road = PopulationGen.pick(rng, s["links"])
	out = out.replace("{road_town}", world["settlements"][road]["name"] if road != null else "the next town")
	var holder := str(factions["powers"].get(s["held_by"], {}).get("name", s["held_by"]))
	out = out.replace("{holder}", holder)
	out = out.replace("{holder_office}", "%s office" % holder.replace("The ", ""))
	return out


func accept_hook(id: int) -> void:
	var h: Dictionary = hooks.get(id, {})
	if h.is_empty() or h["state"] != "open":
		return
	h["state"] = "accepted"
	h["expires"] = _day() + 60
	Events.quest_hook_accepted.emit(h)


## The quest system calls this when a hook's quest ends. Applies the
## consequences the sim owns: the giver's needs and opinion of the player,
## a rumour, and a war shift toward whichever power the solution favours.
func resolve_hook(id: int, solution: String, success := true) -> void:
	var h: Dictionary = hooks.get(id, {})
	if h.is_empty() or h["state"] == "done":
		return
	h["state"] = "done"
	h["solution"] = solution
	var s := settlement(h["sid"])
	var g := resident(h["giver"])
	if success and not g.is_empty():
		var giver_t: Dictionary = templates[h["template"]].get("giver", {})
		for need in giver_t.get("needs", {}):
			g["needs"][need] = minf(100, g["needs"][need] + 35)
		g["op"]["player"] = clampf(g["op"]["player"] + 30, -100, 100)
		for f in g["friends"]:
			world["residents"][f]["op"]["player"] = clampf(world["residents"][f]["op"]["player"] + 8, -100, 100)
	var power := str(h["war"].get(solution, ""))
	if power == "_rival_of_holder":
		power = "meridian" if s["held_by"] != "meridian" else "compact"
	if success and power != "":
		Events.war_shift.emit(h["sid"], power, 1)
	var pool := "neutral"
	if solution == "spell":
		pool = "arcane"
	elif solution == "machine":
		pool = "gear"
	if success and not g.is_empty():
		report_deed(h["sid"], {"id": "helped_" + str(id), "text": "The newcomer helped %s: %s." % [full_name(g), h["name"].to_lower()], "pool": pool, "good": 1, "mag": 8, "witnesses": [g["id"]] + g["friends"]})
	Events.quest_hook_resolved.emit(h, solution)


func open_hooks(sid: String) -> Array:
	var out: Array = []
	for hid in settlement(sid).get("hooks", []):
		if hooks[hid]["state"] == "open":
			out.append(hooks[hid])
	return out


# ================================================================ factions

## A power takes (or loses) a settlement. Residents react through their
## opinions over the following days: the unhappy start hooks and leave.
func set_holder(sid: String, power: String) -> void:
	var s := settlement(sid)
	if s.is_empty() or s["held_by"] == power:
		return
	var old: String = s["held_by"]
	s["held_by"] = power
	s["changed_day"] = _day()
	var pname := str(factions["powers"].get(power, {}).get("name", power))
	_log(s, _day(), "%s took the town." % pname)
	report_deed(sid, {"id": "taken_" + power, "text": "%s holds %s now." % [pname, s["name"]], "by_player": false, "mag": 0})
	for id in s["residents"]:
		var r: Dictionary = world["residents"][id]
		# The first days under new masters are the worst for those who hate them.
		r["needs"]["safety"] = maxf(0, r["needs"]["safety"] - 20)
		r["op"][power] = clampf(r["op"][power] - 10, -100, 100)
	Events.settlement_changed_hands.emit(sid, old, power)


## Share of residents in a settlement who back each power (op > 25).
func support(sid: String) -> Dictionary:
	var s := settlement(sid)
	var out := {"combine": 0.0, "compact": 0.0, "meridian": 0.0}
	var n: int = maxi(1, s["residents"].size())
	for id in s["residents"]:
		var r: Dictionary = world["residents"][id]
		for p in out:
			if float(r["op"][p]) > 25.0:
				out[p] += 1.0 / n
	return out


# ================================================================ area bridge

func _on_flags_changed() -> void:
	if not is_ready or active_sid == "":
		return
	for d in area_deeds:
		if d["fired"]:
			continue
		if str(GameState.get_flag(str(d["flag"]), "")) == str(d["value"]):
			d["fired"] = true
			var s := settlement(active_sid)
			s["threat"] = clampi(int(s["threat"]) + int(d.get("threat", 0)), 0, 100)
			s["prosperity"] = clampf(float(s["prosperity"]) + float(d.get("prosperity", 0.0)), 0.5, 1.5)
			report_deed(active_sid, d)
	# Hooks accepted through dialogue set hook_<id> = accepted.
	for hid in settlement(active_sid).get("hooks", []):
		if hooks[hid]["state"] == "open" and str(GameState.get_flag("hook_%d" % hid, "")) == "accepted":
			accept_hook(hid)


## When a location in the loaded area changes Resonance, the settlement's
## Resonance follows by half (the area is only one corner of the town).
func _on_resonance_changed(loc_id: String, value: int) -> void:
	if not is_ready or active_sid == "" or not _loc_res.has(loc_id):
		return
	var delta: int = value - int(_loc_res[loc_id])
	_loc_res[loc_id] = value
	var s := settlement(active_sid)
	var shift := delta / 2
	s["resonance"] = clampi(int(s["resonance"]) + shift, 0, 100)
	for d in s["districts"]:
		d["resonance"] = clampi(int(d["resonance"]) + shift, 0, 100)


func _refresh_places(s: Dictionary, day: int, hour: int) -> void:
	if s["lod"] == FAR:
		return
	for id in s["residents"]:
		var r: Dictionary = world["residents"][id]
		var b := ResidentSchedule.block_at(self, r, s, day, hour)
		r["at"] = b[0]
		r["act"] = b[1]


# ================================================================ adapters

func full_name(r: Dictionary) -> String:
	if r.is_empty():
		return "someone"
	if r["race"] == "wrought":
		return "%s %s" % [r["given"], r["family"]]
	return "%s %s" % [r["given"], r["family"]]


func job_name(r: Dictionary) -> String:
	if r["job"] == "":
		var rd: Dictionary = races[r["race"]]
		if int(r["age"]) < int(rd["adult"]):
			return "child"
		if int(r["age"]) >= int(rd["elder"]):
			return "retired"
		return "out of work"
	return str(jobs[r["job"]]["name"])


## Short line for hover text: "Smith, Fennick's Landing. Freeholders' League."
func describe_short(id: int) -> String:
	var r := resident(id)
	if r.is_empty():
		return ""
	var s := settlement(r["sid"])
	var txt := "%s, %s %s" % [job_name(r).capitalize(), r["race"], s["name"]]
	if not r["factions"].is_empty():
		txt += "\n" + ", ".join(r["factions"].map(func(f): return factions["minor"][f]["name"]))
	return txt


const POOL_COLORS := {"gear": ["#7a6a58", "#6b6f75", "#8a5d3b"], "arcane": ["#6f5ca8", "#4f7d9c", "#8a6fb0"], "neutral": ["#6d8a4a", "#a0703c", "#9c8a5a", "#5f7f6e", "#9a6a6a"]}


## Turns a resident into an actors.json-style template for World.spawn().
## The flat fields work with the prototype Actor today; "gen" is the compact
## block the character system expands into a full sheet (archetype, level,
## race, heritage, seed), so residents never store full character sheets.
func to_actor_template(id: int) -> Dictionary:
	var r := resident(id)
	var j: Dictionary = jobs.get(r["job"], {})
	var pool := str(j.get("pool", "neutral"))
	var cols: Array = POOL_COLORS[pool]
	var stats := {"str": 10, "dex": 10, "con": 10, "int": 10, "wis": 10, "cha": 10}
	var bias: Dictionary = races[r["race"]].get("stat_bias", {})
	var h: int = r["seed"]
	for k in stats:
		stats[k] += int(bias.get(k, 0)) + (h % 5) - 2
		h = h / 5 + 7
	var rd: Dictionary = races[r["race"]]
	var level := 1 + mini(5, maxi(0, (int(r["age"]) - int(rd["adult"])) / 8))
	return {
		"id": "res_%d" % id,
		"name": full_name(r),
		"faction": "neutral",
		"race": r["race"],
		"color": cols[int(r["seed"]) % cols.size()],
		"stats": stats,
		"hp": 6 + level * 2 + (stats["con"] - 10) / 2,
		"ac": 10 + (stats["dex"] - 10) / 2,
		"aptitude": r["lean"],
		"dialogue": "res:%d" % id,
		"resident_id": id,
		"gen": {"archetype": str(j.get("archetype", "labourer")), "level": level, "race": r["race"],
			"heritage": r["heritage"] if r["heritage"] != "" else null, "seed": r["seed"], "gender": r["sex"]},
	}


# ================================================================ dialogue

func _line(pool: Array, seed: int) -> String:
	if pool.is_empty():
		return ""
	return str(pool[absi(seed) % pool.size()])


func _fill(text: String, r: Dictionary, s: Dictionary) -> String:
	var holder := str(factions["powers"].get(s["held_by"], {}).get("name", s["held_by"]))
	var place := ""
	if r["work"] >= 0:
		place = str(s["places"][r["work"]]["name"]).trim_prefix("the ")
	return text.replace("{name}", full_name(r)).replace("{job}", job_name(r).to_lower()).replace("{town}", s["name"]).replace("{holder}", holder).replace("{place}", place)


## Builds a dialogue (same format as data/dialogue.json) for a generated
## resident from line pools, their needs, opinions, what they've heard and
## any quest hook they're holding. Called by DB.get_dialogue("res:<id>").
func build_dialogue(id: int) -> Dictionary:
	var r := resident(id)
	if r.is_empty():
		return {}
	var s := settlement(r["sid"])
	var seed: int = int(r["seed"]) + _day()
	var op := float(r["op"]["player"])
	var mood := "good" if op > 25 else ("bad" if op < -25 else "neutral")
	var greet: String = _line(lines["greet"][mood], seed)
	var role_lines: Dictionary = lines.get("jobs", {}).get(r["job"], {})
	if mood != "bad" and role_lines.has("greet"):
		greet = _line(role_lines["greet"], seed)
	var opts: Array = [
		{"text": "What do you do here?", "next": "job"},
		{"text": "Heard anything?", "next": "news"},
		{"text": "How are things?", "next": "life"},
	]
	var nodes := {}
	var my_hook: Dictionary = {}
	for hid in r["hooks"]:
		if hooks[hid]["state"] == "open":
			my_hook = hooks[hid]
	if not my_hook.is_empty() and mood != "bad":
		opts.insert(0, {"text": "You look like something's wrong.", "next": "hook"})
		nodes["hook"] = {
			"text": my_hook["pitch"],
			"options": [
				{"text": "I'll see what I can do.", "next": "",
					"effects": [{"type": "set_flag", "flag": "hook_%d" % my_hook["id"], "value": "accepted"},
						{"type": "log", "text": "[color=#ffd84d]New lead: %s (%s).[/color]" % [my_hook["name"], full_name(r)]}]},
				{"text": "Not my business.", "next": "start"},
			],
		}
	opts.append({"text": "Goodbye.", "next": ""})
	nodes["start"] = {"text": _fill(greet, r, s), "options": opts}
	# Job and schedule.
	var job_txt := "I'm %s." % _with_article(job_name(r).to_lower())
	var where := ResidentSchedule.describe(self, r, s)
	if where != "":
		job_txt = "I'm %s. You'll find me at %s." % [_with_article(job_name(r).to_lower()), where]
	if not r["factions"].is_empty():
		var fname: String = factions["minor"][r["factions"][0]]["name"]
		if fname.begins_with("The "):
			fname = "the " + fname.substr(4)
		elif not fname.begins_with("House"):
			fname = "the " + fname
		job_txt += " I'm with %s." % fname
	nodes["job"] = {"text": job_txt, "options": [{"text": "Back.", "next": "start"}]}
	# News: the freshest rumour they've heard, with their take on it.
	var news := ""
	var best_day := -1
	for rid in r["heard"]:
		var ru: Dictionary = rumors.get(rid, {})
		if not ru.is_empty() and int(ru["day"]) > best_day and ru["text"] != "":
			best_day = int(ru["day"])
			news = ru["text"]
			if ru["by_player"]:
				var react := rumor_reaction(r, ru)
				if react > 0.2:
					news += " Good on them, I say."
				elif react < -0.2:
					news += " Can't say I like it."
			if ru["sid"] != ru["origin"]:
				news = "Word from %s: %s" % [settlement(ru["origin"])["name"], news]
	if news == "":
		var hl := float(r["op"].get(s["held_by"], 0.0))
		var key := "like" if hl > 20 else ("dislike" if hl < -20 else "neutral")
		news = _line(lines["holder"][key], seed) if seed % 2 == 0 else _line(lines["no_news"], seed)
	nodes["news"] = {"text": _fill(news, r, s), "options": [{"text": "Back.", "next": "start"}]}
	# Life: the need that hurts most.
	var n: Dictionary = r["needs"]
	var worst := "content"
	var low := 45.0
	for k in n:
		if float(n[k]) < low:
			low = float(n[k])
			worst = k
	var pool_key := worst
	if worst == "conviction":
		pool_key = "conviction_arcane" if int(r["lean"]) > 0 else "conviction_gear"
	var life := _line(lines["needs"].get(pool_key, []), seed)
	var hh: Array = s["households"][r["hh"]]["members"]
	if hh.size() > 1:
		life += " There's %d of us under one roof." % hh.size()
	if r["problem"] != "" and mood != "bad" and my_hook.is_empty():
		life += " Between us, things are worse than they look."
	nodes["life"] = {"text": _fill(life, r, s), "options": [{"text": "Back.", "next": "start"}]}
	return {"entries": [{"node": "start"}], "nodes": nodes}


func _with_article(w: String) -> String:
	if w == "child" or w == "retired" or w == "out of work":
		return {"child": "just a child", "retired": "retired", "out of work": "out of work"}[w]
	return ("an " if w.substr(0, 1) in ["a", "e", "i", "o", "u"] else "a ") + w
