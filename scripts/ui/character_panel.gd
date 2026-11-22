class_name CharacterPanel
extends PanelContainer
## The character sheet (C): stats, derived numbers, skills, disciplines and
## abilities for each party member, with buttons to spend character points.
## Everything shown comes from the Actor's CharacterSheet.

var world = null
var member_index := 0

var _tabs: HBoxContainer
var _header: RichTextLabel
var _cols: HBoxContainer


func _init() -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.08, 0.1, 0.95)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(12)
	sb.border_color = Color(0.4, 0.45, 0.5, 0.6)
	sb.set_border_width_all(1)
	add_theme_stylebox_override("panel", sb)
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(1320, 720)
	var v := VBoxContainer.new()
	add_child(v)
	var top := HBoxContainer.new()
	v.add_child(top)
	var t := Label.new()
	t.text = "Character   (C or Esc to close. Hover anything for details.)   "
	top.add_child(t)
	_tabs = HBoxContainer.new()
	top.add_child(_tabs)
	_header = RichTextLabel.new()
	_header.bbcode_enabled = true
	_header.fit_content = true
	_header.custom_minimum_size = Vector2(1290, 0)
	v.add_child(_header)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(1290, 600)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	_cols = HBoxContainer.new()
	_cols.add_theme_constant_override("separation", 22)
	scroll.add_child(_cols)
	Events.character_changed.connect(_on_changed)


func _on_changed(_a) -> void:
	if visible:
		refresh.call_deferred()


func members() -> Array:
	var out: Array = []
	for a in world.party_all():
		if not a.summoned:
			out.append(a)
	return out


func refresh() -> void:
	var ms := members()
	if ms.is_empty():
		return
	member_index = clampi(member_index, 0, ms.size() - 1)
	var a = ms[member_index]
	var s: CharacterSheet = a.sheet
	for c in _tabs.get_children():
		c.queue_free()
	for i in ms.size():
		var b := Button.new()
		b.text = ms[i].display_name + (" (%d CP)" % ms[i].sheet.cp if ms[i].sheet.cp > 0 else "")
		b.focus_mode = Control.FOCUS_NONE
		b.disabled = i == member_index
		var idx := i
		b.pressed.connect(func():
			member_index = idx
			refresh())
		_tabs.add_child(b)
	var bg: Dictionary = DB.backgrounds.get(s.background, {})
	var traits: PackedStringArray = []
	for t in s.trait_ids():
		traits.append(str(DB.traits.get(t, {}).get("name", t)))
	_header.text = "[font_size=22][b]%s[/b][/font_size]   level %d %s, %s   XP %d (next level in %d)   [color=#ffd84d][b]%d CP to spend[/b][/color]\nTraits: %s   Aptitude: [b]%s[/b]" % [
		a.display_name, s.level, s.race_name(), str(bg.get("name", "no background")), s.xp, s.xp_to_next(), s.cp,
		", ".join(traits) if not traits.is_empty() else "none", CharacterSheet.aptitude_word(a.aptitude)]
	_header.tooltip_text = "%s\n\n%s" % [str(s.race_data().get("lore", "")), str(bg.get("desc", ""))]
	for c in _cols.get_children():
		c.queue_free()
	_stats_col(a, s)
	_skills_col(a, s)
	_disc_col(a, s)


func _col(title: String, w: float) -> VBoxContainer:
	var c := VBoxContainer.new()
	c.custom_minimum_size = Vector2(w, 0)
	_cols.add_child(c)
	var l := Label.new()
	l.text = title
	l.add_theme_color_override("font_color", Color("#ffd84d"))
	c.add_child(l)
	return c


func _row(parent: Control, text: String, tip: String, a, kind: String, id: String, dim := false) -> void:
	var r := HBoxContainer.new()
	parent.add_child(r)
	var l := Label.new()
	l.text = text
	l.tooltip_text = tip
	l.mouse_filter = Control.MOUSE_FILTER_PASS
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.add_theme_font_size_override("font_size", 14)
	if dim:
		l.add_theme_color_override("font_color", Color("#8a929a"))
	r.add_child(l)
	if kind == "":
		return
	var chk: Dictionary = a.can_buy(kind, id)
	var b := Button.new()
	b.text = "+%d" % int(chk["cost"]) if chk["cost"] > 0 else "+"
	b.focus_mode = Control.FOCUS_NONE
	b.disabled = not chk["ok"]
	b.tooltip_text = "Spend %d CP" % int(chk["cost"]) if chk["ok"] else str(chk["reason"])
	b.mouse_filter = Control.MOUSE_FILTER_PASS
	b.pressed.connect(func():
		if a.buy(kind, id):
			Events.post("%s improves %s." % [a.display_name, text.split("  ")[0].strip_edges()])
		refresh())
	r.add_child(b)


func _stats_col(a, s: CharacterSheet) -> void:
	var c := _col("Attributes", 300)
	var names := {"str": "Strength", "dex": "Dexterity", "con": "Constitution", "int": "Intelligence", "wis": "Wisdom", "cha": "Charisma"}
	for k in CharacterSheet.STATS:
		var v: int = a.stats[k]
		var rm := s.race_stat_mod(k)
		_row(c, "%s  %d  (%+d)" % [names[k], v, Rules.mod(v)], "Base %d, race %+d, effects %+d" % [s.base_stats[k], rm, v - s.natural_stat(k)], a, "stat", k)
	c.add_child(HSeparator.new())
	var lines := [
		["HP", "%d / %d" % [a.hp, a.max_hp], "Race base + CON, plus per level. Grade: %s." % s.grade],
		["AC", str(a.ac), "10 + DEX mod + Dodge rank / 2 + armour and effects."],
		["AP per round", str(a.ap_max), "6, plus effects."],
		["Initiative", "%+d" % s.initiative_bonus(), "DEX mod + modifiers."],
		["Proficiency", "+%d" % s.proficiency(), "Grows every 8 levels. Trained skills add it."],
		["Saves", "STR %+d DEX %+d CON %+d INT %+d WIS %+d CHA %+d" % [s.save_bonus("str"), s.save_bonus("dex"), s.save_bonus("con"), s.save_bonus("int"), s.save_bonus("wis"), s.save_bonus("cha")], "d20 + this vs the DC."],
	]
	for l in lines:
		_row(c, "%s:  %s" % [l[0], l[1]], l[2], a, "", "")
	var res: PackedStringArray = []
	for t in ["fire", "cold", "lightning", "poison", "acid", "necrotic"]:
		var r := s.resist(t)
		if r != 0.0:
			res.append("%s %d%%" % [t, roundi(r)])
	if not res.is_empty():
		_row(c, "Resist: " + ", ".join(res), "", a, "", "")
	if not a.statuses.is_empty():
		var st: PackedStringArray = []
		for x in a.statuses:
			st.append("%s (%d)" % [str(DB.statuses.get(x["id"], {}).get("name", x["id"])), int(x["rounds"])])
		_row(c, "Effects: " + ", ".join(st), "", a, "", "")
	c.add_child(HSeparator.new())
	var pp := s.pool_points()
	_row(c, "Spent: Arcane %d, Neutral %d, Gear %d" % [pp["arcane"], pp["neutral"], pp["gear"]], "Skill ranks count 1, discipline tiers count 2. Arcane minus Gear sets your aptitude.", a, "", "")


func _skills_col(a, s: CharacterSheet) -> void:
	var c := _col("Skills", 400)
	var groups := ["combat", "magic", "stealth", "social", "knowledge", "craft"]
	var rank_names: Array = DB.progression.get("skill_ranks", {}).get("names", [])
	for g in groups:
		var gl := Label.new()
		gl.text = g.capitalize()
		gl.add_theme_color_override("font_color", Color("#9fd8ff"))
		gl.add_theme_font_size_override("font_size", 13)
		c.add_child(gl)
		for id in DB.char_skills:
			var sk: Dictionary = DB.char_skills[id]
			if sk.get("group") != g:
				continue
			var r := s.skill_rank(id)
			var pool := str(sk.get("pool", "neutral"))
			var tag: String = {"arcane": "A", "gear": "G", "neutral": "N"}.get(pool, "N")
			_row(c, "%s [%s]  %s  %+d" % [sk.get("name", id), tag, str(rank_names[r]) if r < rank_names.size() else str(r), s.skill_bonus(id)],
				"%s\n%s pool, %s. Rank %d." % [sk.get("desc", ""), pool.capitalize(), str(sk.get("stat", "")).to_upper(), r], a, "skill", id, r == 0)


func _disc_col(a, s: CharacterSheet) -> void:
	var c := _col("Disciplines and abilities (each tier costs 1 CP and grants its abilities)", 540)
	var kinds := [["school", "Arcane schools"], ["domain", "Divine domains"], ["trade", "Gear trades"], ["style", "Neutral styles"], ["craft", "Craft trees"]]
	for kd in kinds:
		var gl := Label.new()
		gl.text = kd[1]
		gl.add_theme_color_override("font_color", Color("#9fd8ff"))
		gl.add_theme_font_size_override("font_size", 13)
		c.add_child(gl)
		for id in DB.disciplines:
			var d: Dictionary = DB.disciplines[id]
			if d.get("kind") != kd[0]:
				continue
			var t := s.tier(id)
			var chk: Dictionary = s.can_buy("tier", id)
			if t == 0 and not chk["ok"] and a.sheet.has_flag("no_magic") and d.get("pool") == "arcane":
				continue
			var extra := ""
			if int(d.get("schematic_picks", 0)) > 0 and t > 0:
				extra = "   %d schematic picks left" % s.schematic_picks_left(id)
			_row(c, "%s  tier %d/5%s" % [d.get("name", id), t, extra], "%s\nGoverned by %s, key stat %s." % [d.get("desc", ""), "/".join(CharacterSheet.governing_skills(d)), str(d.get("stat", "")).to_upper()], a, "tier", id, t == 0)
			if t == 0:
				continue
			for aid in DB.abilities_by_discipline.get(id, []):
				var ab: Dictionary = DB.get_ability(aid)
				var at := int(ab.get("tier", 1))
				if at > t + 1:
					continue
				var known := at <= t
				_row(c, "      %s%s  (t%d %s)" % ["" if known else "next: ", ab.get("name", aid), at, ab.get("kind", "")], AbilityRules.describe(ab), a, "", "", not known)
