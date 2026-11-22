class_name PopulationGen
extends RefCounted
## Builds the whole simulated population from data/world and data/residents.
## Deterministic: the same seed always gives the same world, and every
## settlement draws from its own RNG, so editing one town's data never
## reshuffles another town.
##
## Output (a plain Dictionary, so it can be saved as JSON):
##   world.settlements[sid] = settlement (see _new_settlement)
##   world.order            = settlement ids in generation order
##   world.residents[id]    = resident (see _new_resident), id = index
##
## Places and households are indices into their settlement's arrays.

const CHILD_AGE := 6
const SCHOOL_END := 14

var data := {}
var jobs: Dictionary = {}
var races: Dictionary = {}
var traits: Dictionary = {}
var problems: Dictionary = {}
var factions: Dictionary = {}
var world := {}
var _used_names: Dictionary = {}


func _init() -> void:
	data = {
		"settlements": DB.load_json("res://data/world/settlements.json"),
		"jobs": DB.load_json("res://data/residents/jobs.json"),
		"demo": DB.load_json("res://data/residents/demographics.json"),
		"factions": DB.load_json("res://data/world/factions.json"),
	}
	jobs = data["jobs"]["jobs"]
	races = data["demo"]["races"]
	traits = data["demo"]["traits"].duplicate()
	traits.erase("_doc")
	problems = data["demo"]["problems"].duplicate()
	problems.erase("_doc")
	factions = data["factions"]


# ---------------------------------------------------------------- helpers

static func pick_weighted(rng: RandomNumberGenerator, weights: Dictionary) -> Variant:
	var total := 0.0
	for k in weights:
		total += float(weights[k])
	if total <= 0.0:
		return null
	var roll := rng.randf() * total
	for k in weights:
		roll -= float(weights[k])
		if roll <= 0.0:
			return k
	return weights.keys()[weights.size() - 1]


static func pick(rng: RandomNumberGenerator, arr: Array) -> Variant:
	if arr.is_empty():
		return null
	return arr[rng.randi() % arr.size()]


static func seed_for(a: Variant, b: Variant = 0) -> int:
	return hash([a, b]) & 0x7FFFFFFF


# ---------------------------------------------------------------- world

## Generates every settlement. Returns the world dictionary.
func generate_world(world_seed: int) -> Dictionary:
	world = {"seed": world_seed, "settlements": {}, "order": [], "residents": [], "regions": {}, "day": 1}
	_used_names = {}
	var sdata: Dictionary = data["settlements"]
	var defs := _settlement_defs(world_seed, sdata)
	for def in defs:
		var s := generate_settlement(def, world_seed)
		world["settlements"][s["id"]] = s
		world["order"].append(s["id"])
	_link_roads()
	return world


## Lays out every settlement definition: cities and named towns from data,
## generated towns scaled so the world lands near target_total.
func _settlement_defs(world_seed: int, sdata: Dictionary) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_for(world_seed, "layout")
	var defs: Array = []
	var fixed_pop := 0
	var gen_towns: Array = []
	var names: Dictionary = sdata.get("town_names", {})
	for k in names.get("banned", []):
		_used_names[str(k)] = true
	var radius := float(sdata.get("map_radius", 80))
	for reg in sdata["regions"]:
		var rid := str(reg["id"])
		world["regions"][rid] = {"id": rid, "name": reg["name"], "neighbors": reg.get("neighbors", [])}
		var centre := Vector2(float(reg["map"][0]), float(reg["map"][1]))
		for c in reg.get("cities", []):
			var d: Dictionary = c.duplicate(true)
			d["kind"] = "city"
			d["region"] = rid
			d["reg"] = reg
			d["resonance"] = _avg_district_res(c)
			d["pos"] = centre + Vector2(rng.randf_range(-0.5, 0.5), rng.randf_range(-0.5, 0.5)) * radius
			fixed_pop += int(c["pop"])
			defs.append(d)
		var named: Array = reg.get("named_towns", [])
		for t in named:
			var d: Dictionary = t.duplicate(true)
			d["kind"] = "town"
			d["region"] = rid
			d["reg"] = reg
			d["pos"] = centre + Vector2(rng.randf_range(-1, 1), rng.randf_range(-1, 1)) * radius
			_used_names[str(t["name"])] = true
			fixed_pop += int(t["pop"])
			defs.append(d)
		var res_range: Array = reg["resonance"]
		var pop_range: Array = reg["town_pop"]
		for i in int(reg["towns"]) - named.size():
			var nm := _town_name(rng, names)
			var held = pick_weighted(rng, reg["held_by"])
			var d := {
				"id": nm.to_snake_case().replace("'", ""),
				"name": nm, "kind": "town", "region": rid, "reg": reg,
				"pop": lerpf(float(pop_range[0]), float(pop_range[1]), pow(rng.randf(), 1.6)),
				"resonance": rng.randi_range(int(res_range[0]), int(res_range[1])),
				"held_by": held,
				"specialty": pick_weighted(rng, reg["specialties"]),
				"threat": clampi(int(reg.get("threat", 30)) + rng.randi_range(-15, 15), 0, 100),
				"pos": centre + Vector2(rng.randf_range(-1, 1), rng.randf_range(-1, 1)) * radius,
			}
			gen_towns.append(d)
			defs.append(d)
	var target := int(sdata.get("target_total", 25000))
	var gen_sum := 0.0
	for d in gen_towns:
		gen_sum += float(d["pop"])
	var scale := 1.0
	if gen_sum > 0.0:
		scale = maxf(0.2, float(target - fixed_pop) / gen_sum)
	for d in gen_towns:
		d["pop"] = maxi(30, roundi(float(d["pop"]) * scale))
	return defs


func _avg_district_res(c: Dictionary) -> int:
	var t := 0
	for d in c["districts"]:
		t += int(d["resonance"])
	return t / maxi(1, c["districts"].size())


func _town_name(rng: RandomNumberGenerator, names: Dictionary) -> String:
	var first: Array = names.get("first", ["New"])
	var second: Array = names.get("second", ["town"])
	for attempt in 200:
		var a: String = pick(rng, first)
		var b: String = pick(rng, second)
		if a.to_lower().ends_with(b.substr(0, 1)) and rng.randf() < 0.7:
			continue
		var nm := a + b
		if not _used_names.has(nm):
			_used_names[nm] = true
			return nm
	var fallback := "%s %d" % [pick(rng, first), _used_names.size()]
	_used_names[fallback] = true
	return fallback


## Joins each settlement to its nearest neighbours (roads). Used for
## travel text, rumours spreading between towns, and emigration.
func _link_roads() -> void:
	var ids: Array = world["order"]
	for sid in ids:
		var s: Dictionary = world["settlements"][sid]
		var others: Array = []
		for oid in ids:
			if oid == sid:
				continue
			var o: Dictionary = world["settlements"][oid]
			var d: float = (s["pos"] as Vector2).distance_to(o["pos"])
			if o["region"] != s["region"] and not (o["region"] in world["regions"][s["region"]]["neighbors"]):
				d *= 3.0
			others.append([d, oid])
		others.sort_custom(func(a, b): return a[0] < b[0])
		for i in mini(3, others.size()):
			var oid: String = others[i][1]
			if not (oid in s["links"]):
				s["links"].append(oid)
			var o: Dictionary = world["settlements"][oid]
			if not (sid in o["links"]):
				o["links"].append(sid)


# ---------------------------------------------------------------- settlement

func _new_settlement(def: Dictionary) -> Dictionary:
	var reg: Dictionary = def["reg"]
	return {
		"id": str(def["id"]),
		"name": str(def["name"]),
		"kind": str(def["kind"]),
		"region": str(def["region"]),
		"pop_target": int(def["pop"]),
		"resonance": int(def.get("resonance", 50)),
		"held_by": str(def.get("held_by", "meridian")),
		"threat": int(def.get("threat", reg.get("threat", 30))),
		"specialty": str(def.get("specialty", "")),
		"prosperity": 1.0,
		"area": str(def.get("area", "")),
		"capital": bool(def.get("capital", false)),
		"pos": def["pos"],
		"links": [],
		"districts": [],
		"places": [],
		"households": [],
		"residents": [],
		"venues": [],
		"rumors": [],
		"hooks": [],
		"cooldowns": {},
		"lod": 0,
		"log": [],
	}


## Generates one settlement and appends its residents to world.residents.
func generate_settlement(def: Dictionary, world_seed: int) -> Dictionary:
	var s := _new_settlement(def)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_for(world_seed, s["id"])
	s["prosperity"] = rng.randf_range(0.85, 1.15)
	# Districts and their share of the people.
	var dist_defs: Array = def.get("districts", [])
	if dist_defs.is_empty():
		dist_defs = [{"id": s["id"], "name": s["name"], "kind": s["specialty"], "resonance": s["resonance"]}]
	var weights := {"residential": 1.5, "slum": 1.6, "docks": 1.0, "industrial": 1.0, "market": 0.8,
		"temple": 0.6, "civic": 0.5, "noble": 0.5, "campus": 0.8}
	var wsum := 0.0
	for d in dist_defs:
		wsum += float(weights.get(str(d["kind"]), 1.0))
	for d in dist_defs:
		var share := float(weights.get(str(d["kind"]), 1.0)) / wsum
		s["districts"].append({
			"id": str(d["id"]), "name": str(d["name"]), "kind": str(d["kind"]),
			"resonance": int(d["resonance"]), "pop_target": maxi(10, roundi(s["pop_target"] * share)),
		})
		s["venues"].append({})
	var essentials_done := {}
	for a in def.get("anchors", []):
		_add_anchor(s, a, rng, essentials_done)
	for di in s["districts"].size():
		_populate_district(s, di, rng, essentials_done)
	_assign_social(s, rng)
	return s


## A hand-written character living in the town: same record as everyone
## else, tier "anchor", linked to its actors.json template.
func _add_anchor(s: Dictionary, a: Dictionary, rng: RandomNumberGenerator, essentials_done: Dictionary) -> void:
	var tpl: Dictionary = DB.get_actor_template(str(a["template"]))
	var parts := str(tpl.get("name", "Someone Unknown")).split(" ", false, 1)
	var race := str(tpl.get("race", "human"))
	var family: String = parts[1] if parts.size() > 1 else ""
	var home := _add_place(s, 0, "home", family, -1)
	s["households"].append({"members": [], "home": home, "family": family})
	var hh: int = s["households"].size() - 1
	var id := _new_resident(s, 0, rng, race, family, int(a.get("age", 40)), hh)
	s["households"][hh]["members"].append(id)
	var r: Dictionary = world["residents"][id]
	r["given"] = parts[0]
	r["tier"] = "anchor"
	r["template"] = str(a["template"])
	r["lean"] = int(tpl.get("aptitude", r["lean"]))
	var jid := str(a.get("job", ""))
	if jid != "":
		r["job"] = jid
		r["work"] = _workplace_for(s, 0, rng, jid, r)
		essentials_done[jid] = true


func _populate_district(s: Dictionary, di: int, rng: RandomNumberGenerator, essentials_done: Dictionary) -> void:
	var dist: Dictionary = s["districts"][di]
	var reg_mix: Dictionary = data["settlements"]["regions"].filter(func(r): return r["id"] == s["region"])[0]["race_mix"]
	var made := []
	var already := 0
	for id in s["residents"]:
		if world["residents"][id]["district"] == di:
			already += 1
	# 1. Households.
	while made.size() + already < int(dist["pop_target"]):
		var members := _make_household(s, di, rng, reg_mix)
		made.append_array(members)
	# 2. Jobs.
	var workers: Array = []
	for rid in made:
		var r: Dictionary = world["residents"][rid]
		if _is_working_age(r):
			workers.append(rid)
	_shuffle(workers, rng)
	_assign_jobs(s, di, rng, workers, essentials_done)
	# 3. Venues every district needs.
	_ensure_venue(s, di, "square", "")
	if int(dist["pop_target"]) >= 50:
		_ensure_venue(s, di, "market", "")
	if int(dist["resonance"]) >= 30:
		_ensure_venue(s, di, "shrine", "")
	if _venue_list(s, di, "tavern").is_empty() and s["kind"] == "town":
		var t := _add_place(s, di, "tavern", _tavern_name(rng), -1)
		_add_venue(s, di, "tavern", t)


func _is_working_age(r: Dictionary) -> bool:
	var rd: Dictionary = races[r["race"]]
	return int(r["age"]) >= int(rd["adult"]) and int(r["age"]) < int(rd["elder"]) + 5


func _make_household(s: Dictionary, di: int, rng: RandomNumberGenerator, mix: Dictionary) -> Array:
	var race: String = pick_weighted(rng, mix)
	var rd: Dictionary = races[race]
	var size: int = 1 if rd.get("no_family", false) else int(pick_weighted(rng, {1: 22, 2: 28, 3: 20, 4: 15, 5: 9, 6: 4, 7: 2}))
	var hh_index: int = s["households"].size()
	var family := _family_name(rng, race)
	var home := _add_place(s, di, "home", family, -1)
	var hh := {"members": [], "home": home, "family": family}
	s["households"].append(hh)
	var adult := int(rd["adult"])
	var elder := int(rd["elder"])
	var head_age := rng.randi_range(adult, mini(elder + 15, int(rd["max_age"]) - 5))
	if race == "wrought":
		head_age = rng.randi_range(1, 60)
	var head := _new_resident(s, di, rng, race, family, head_age, hh_index)
	hh["members"].append(head)
	if race == "wrought":
		s["places"][home]["name"] = "%s's berth" % world["residents"][head]["given"]
	var left := size - 1
	if left > 0 and rng.randf() < 0.72:
		var srace := race
		if rng.randf() < 0.12:
			srace = str(pick_weighted(rng, mix))
			if srace == "wrought":
				srace = race
		var srd: Dictionary = races[srace]
		var span := float(head_age - adult) / float(maxi(1, elder - adult))
		var sage := clampi(int(lerpf(float(srd["adult"]), float(srd["elder"]), span)) + rng.randi_range(-5, 5), int(srd["adult"]), int(srd["max_age"]) - 5)
		var spouse := _new_resident(s, di, rng, srace, family, sage, hh_index)
		world["residents"][head]["spouse"] = spouse
		world["residents"][spouse]["spouse"] = head
		_set_opposite_sex(world["residents"][head], world["residents"][spouse], rng)
		hh["members"].append(spouse)
		left -= 1
	if left > 0 and head_age < elder and rng.randf() < 0.18:
		var eage := mini(head_age + rng.randi_range(20, 35), int(rd["max_age"]) - 2)
		if eage >= elder:
			var e := _new_resident(s, di, rng, race, family, eage, hh_index)
			world["residents"][e]["kids"].append(head)
			world["residents"][head]["parents"].append(e)
			hh["members"].append(e)
			left -= 1
	var parents: Array = hh["members"].filter(func(id): return int(world["residents"][id]["age"]) <= int(rd["elder"]) + 5 and not world["residents"][head]["parents"].has(id))
	var max_child_age := maxi(0, head_age - adult)
	for i in left:
		var cage: int
		if max_child_age <= 0 or rng.randf() < 0.25:
			# A household of adult siblings or lodgers.
			cage = rng.randi_range(adult, maxi(adult, head_age + 6))
		else:
			cage = rng.randi_range(0, mini(max_child_age, adult + 6))
		var c := _new_resident(s, di, rng, race, family, cage, hh_index)
		if cage < adult:
			for p in parents:
				world["residents"][p]["kids"].append(c)
				world["residents"][c]["parents"].append(p)
		hh["members"].append(c)
	return hh["members"]


func _set_opposite_sex(a: Dictionary, b: Dictionary, rng: RandomNumberGenerator) -> void:
	if rng.randf() < 0.9 and a["sex"] == b["sex"]:
		b["sex"] = "f" if a["sex"] == "m" else "m"
		b["given"] = _given_name(rng, b["race"])


func _family_name(rng: RandomNumberGenerator, race: String) -> String:
	var rd: Dictionary = races[race]
	return str(pick(rng, rd["family_c"])) + str(pick(rng, rd["family_d"]))


func _given_name(rng: RandomNumberGenerator, race: String) -> String:
	var rd: Dictionary = races[race]
	return str(pick(rng, rd["given_a"])) + str(pick(rng, rd["given_b"]))


func _new_resident(s: Dictionary, di: int, rng: RandomNumberGenerator, race: String, family: String, age: int, hh: int) -> int:
	var rd: Dictionary = races[race]
	var id: int = world["residents"].size()
	var heritage := ""
	if rd.has("heritages"):
		heritage = str(pick_weighted(rng, rd["heritages"]))
	var sex: String = "x" if race == "wrought" else ("m" if rng.randf() < 0.5 else "f")
	var lean_r: Array = rd["lean"]
	var lean := rng.randi_range(int(lean_r[0]), int(lean_r[1]))
	if heritage == "godtouched":
		lean = rng.randi_range(40, 80)
	var tr: Array = []
	var tweights := {}
	for k in traits:
		tweights[k] = float(traits[k].get("weight", 5))
	var ntraits := 1 if rng.randf() < 0.6 else 2
	for i in ntraits:
		var t = pick_weighted(rng, tweights)
		if t != null and not (t in tr):
			tr.append(t)
			lean += int(traits[t].get("lean_shift", 0))
	var r := {
		"id": id, "sid": s["id"], "district": di,
		"given": _given_name(rng, race), "family": family,
		"race": race, "heritage": heritage, "sex": sex, "age": age,
		"bday": rng.randi_range(0, 359),
		"hh": hh, "home": s["households"][hh]["home"], "work": -1, "job": "",
		"traits": tr, "problem": "", "tier": "generated",
		"needs": {"money": 50.0, "safety": 50.0, "belonging": 50.0, "conviction": 50.0},
		"lean": clampi(lean, -100, 100),
		"op": {"combine": 0.0, "compact": 0.0, "meridian": 0.0, "player": 0.0},
		"factions": [],
		"spouse": -1, "parents": [], "kids": [], "friends": [],
		"heard": {}, "hooks": [],
		"alive": true, "seed": rng.randi(), "since_day": 1,
	}
	world["residents"].append(r)
	s["residents"].append(id)
	return id


# ---------------------------------------------------------------- jobs

func _assign_jobs(s: Dictionary, di: int, rng: RandomNumberGenerator, workers: Array, essentials_done: Dictionary) -> void:
	var dist: Dictionary = s["districts"][di]
	var key: String = dist["kind"] if s["kind"] == "city" else s["specialty"]
	var res := int(dist["resonance"])
	var dpop := int(dist["pop_target"])
	var spop := int(s["pop_target"])
	var slots: Array = []
	for jid in jobs:
		var j: Dictionary = jobs[jid]
		if int(j.get("per", 9999)) >= 9999 and not j.get("essential", false):
			continue
		if spop < int(j.get("min_pop", 0)):
			continue
		var rr: Array = j.get("res", [0, 100])
		if res < int(rr[0]) or res > int(rr[1]):
			continue
		var mult := float(j.get("mult", {}).get(key, 1.0))
		var demand := float(dpop) / float(j.get("per", 9999)) * mult
		var n := int(demand)
		if rng.randf() < demand - n:
			n += 1
		if j.get("essential", false) and not essentials_done.has(jid) and mult > 0.0:
			n = maxi(n, 1)
		if jid == "warden":
			n = 0 if essentials_done.has(jid) else 1
		for i in n:
			slots.append(jid)
		if n > 0:
			essentials_done[jid] = true
	_shuffle(slots, rng)
	# Hosts first so joiners (barkeeps, farmhands) find their workplace.
	slots.sort_custom(func(a, b): return int(jobs[a].has("joins")) < int(jobs[b].has("joins")))
	var cap_specific := int(ceil(workers.size() * 0.65))
	var wi := 0
	for jid in slots:
		if wi >= cap_specific:
			break
		_give_job(s, di, rng, workers[wi], jid)
		wi += 1
	var labor_map: Dictionary = data["jobs"]["specialty_labor"] if s["kind"] == "town" else data["jobs"]["district_labor"]
	var labor := str(labor_map.get(key, "laborer"))
	var lj: Dictionary = jobs.get(labor, {})
	var lr: Array = lj.get("res", [0, 100])
	if res < int(lr[0]) or res > int(lr[1]):
		labor = "laborer"
	while wi < workers.size():
		var rid: int = workers[wi]
		wi += 1
		var roll := rng.randf()
		if roll < 0.07:
			continue # out of work
		if roll < 0.13 and world["residents"][rid]["spouse"] >= 0:
			continue # keeps house
		_give_job(s, di, rng, rid, labor)


func _give_job(s: Dictionary, di: int, rng: RandomNumberGenerator, rid: int, jid: String) -> void:
	var r: Dictionary = world["residents"][rid]
	var j: Dictionary = jobs[jid]
	r["job"] = jid
	r["work"] = _workplace_for(s, di, rng, jid, r)
	if j.get("role", false):
		r["tier"] = "role"
		if rng.randf() < 0.6:
			r["problem"] = str(pick(rng, problems.keys()))
	elif rng.randf() < 0.1:
		r["problem"] = str(pick(rng, problems.keys()))
	var pool := str(j.get("pool", "neutral"))
	if pool == "gear":
		r["lean"] = clampi(r["lean"] - rng.randi_range(10, 30), -100, 100)
	elif pool == "arcane":
		r["lean"] = clampi(r["lean"] + rng.randi_range(10, 30), -100, 100)


## Returns the place index a worker of jid works at, creating it if needed.
func _workplace_for(s: Dictionary, di: int, rng: RandomNumberGenerator, jid: String, r: Dictionary) -> int:
	var j: Dictionary = jobs[jid]
	var kind := str(j["place"])
	if kind in data["jobs"]["commons"]:
		return _ensure_venue(s, di, kind, "")
	var host := str(j.get("joins", jid))
	var cap := int(j.get("cap", 4))
	# Find an existing place of the host job with room for this job.
	for pi in s["places"].size():
		var p: Dictionary = s["places"][pi]
		if p["district"] != di or p["job"] != host:
			continue
		var c: int = p["staff"].get(jid, 0)
		if c < cap:
			p["staff"][jid] = c + 1
			return pi
	var owner := str(r["family"])
	var nm := _tavern_name(rng) if kind == "tavern" else owner
	var pi := _add_place(s, di, kind, nm, -1)
	s["places"][pi]["job"] = jid if not j.has("joins") else host
	s["places"][pi]["staff"][jid] = 1
	if kind in ["tavern", "temple", "library", "market", "workshop"]:
		_add_venue(s, di, kind, pi)
	return pi


func _tavern_name(rng: RandomNumberGenerator) -> String:
	return str(pick(rng, data["jobs"]["tavern_names"]))


func _add_place(s: Dictionary, di: int, kind: String, owner: String, _cap: int) -> int:
	var kinds: Dictionary = data["jobs"]["place_kinds"]
	var kd: Dictionary = kinds.get(kind, {"outdoor": false, "name": kind})
	var fmt := str(kd["name"])
	var nm := fmt % owner if fmt.contains("%s") else fmt
	if kind == "office" and owner != "":
		nm = "the %s office" % owner
	s["places"].append({"kind": kind, "name": nm, "district": di, "outdoor": bool(kd["outdoor"]), "job": "", "staff": {}})
	return s["places"].size() - 1


func _venue_list(s: Dictionary, di: int, kind: String) -> Array:
	return s["venues"][di].get(kind, [])


func _add_venue(s: Dictionary, di: int, kind: String, pi: int) -> void:
	if not s["venues"][di].has(kind):
		s["venues"][di][kind] = []
	if not (pi in s["venues"][di][kind]):
		s["venues"][di][kind].append(pi)


## One shared place of this kind per district (square, market, docks...).
func _ensure_venue(s: Dictionary, di: int, kind: String, owner: String) -> int:
	var l := _venue_list(s, di, kind)
	if not l.is_empty():
		return l[0]
	var pi := _add_place(s, di, kind, owner, -1)
	_add_venue(s, di, kind, pi)
	return pi


# ---------------------------------------------------------------- social

func _assign_social(s: Dictionary, rng: RandomNumberGenerator) -> void:
	var by_work := {}
	var by_district := {}
	for rid in s["residents"]:
		var r: Dictionary = world["residents"][rid]
		if r["work"] >= 0:
			if not by_work.has(r["work"]):
				by_work[r["work"]] = []
			by_work[r["work"]].append(rid)
		if not by_district.has(r["district"]):
			by_district[r["district"]] = []
		by_district[r["district"]].append(rid)
	var reg_id: String = s["region"]
	for rid in s["residents"]:
		var r: Dictionary = world["residents"][rid]
		var nfr := rng.randi_range(1, 4)
		if "recluse" in r["traits"]:
			nfr = 1
		if "gossip" in r["traits"]:
			nfr += 2
		var pool: Array = by_work.get(r["work"], []) if r["work"] >= 0 and rng.randf() < 0.6 else by_district[r["district"]]
		for i in nfr:
			var f = pick(rng, pool)
			if f == null or f == rid or f in r["friends"] or f == r["spouse"]:
				continue
			r["friends"].append(f)
			var fr: Dictionary = world["residents"][f]
			if not (rid in fr["friends"]):
				fr["friends"].append(rid)
		_init_state(s, r, rng)
		_join_factions(s, r, rng, reg_id)


func _init_state(s: Dictionary, r: Dictionary, rng: RandomNumberGenerator) -> void:
	var lean := float(r["lean"])
	var wage := float(jobs.get(r["job"], {}).get("wage", 0.7 if _is_working_age(r) else 1.5))
	var n: Dictionary = r["needs"]
	n["money"] = clampf(50.0 + 37.5 * (wage - 1.5) + rng.randf_range(-20, 20), 0, 100)
	n["safety"] = clampf(100.0 - float(s["threat"]) * 1.2 + rng.randf_range(-15, 15), 0, 100)
	n["belonging"] = clampf(40.0 + 6.0 * s["households"][r["hh"]]["members"].size() + 4.0 * r["friends"].size() + rng.randf_range(-15, 10), 0, 100)
	var dres := float(s["districts"][r["district"]]["resonance"])
	n["conviction"] = clampf(100.0 - absf(dres - (50.0 + lean * 0.5)) * 1.6 + rng.randf_range(-10, 10), 0, 100)
	var op: Dictionary = r["op"]
	op["combine"] = clampf(-lean * 0.6 + rng.randf_range(-25, 25), -100, 100)
	op["compact"] = clampf(lean * 0.6 + rng.randf_range(-25, 25), -100, 100)
	op["meridian"] = clampf(15.0 - absf(lean) * 0.4 + rng.randf_range(-25, 25), -100, 100)


func _join_factions(s: Dictionary, r: Dictionary, rng: RandomNumberGenerator, reg_id: String) -> void:
	if int(r["age"]) < int(races[r["race"]]["adult"]):
		return
	var tags: Array = jobs.get(r["job"], {}).get("tags", [])
	for fid in factions["minor"]:
		var f: Dictionary = factions["minor"][fid]
		var jn: Dictionary = f.get("join", {})
		if jn.has("race_only") and not (r["race"] in jn["race_only"]):
			continue
		var w := 0.0
		for t in jn.get("tags", []):
			if t in tags:
				w = 1.0
		w = maxf(w, float(jn.get("races", {}).get(r["race"], 0.0)) * 0.5)
		for t in jn.get("traits", {}):
			if t in r["traits"]:
				w *= float(jn["traits"][t])
		if w <= 0.0:
			continue
		w *= float(jn.get("regions", {}).get(reg_id, 1.0))
		if rng.randf() < float(jn.get("chance", 0.2)) * w:
			var rival := false
			for other in r["factions"]:
				if other in f.get("rivals", []):
					rival = true
			if not rival:
				r["factions"].append(fid)


static func _shuffle(arr: Array, rng: RandomNumberGenerator) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := rng.randi() % (i + 1)
		var t = arr[i]
		arr[i] = arr[j]
		arr[j] = t
