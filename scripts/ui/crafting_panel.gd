extends PanelContainer
## The workbench (C): Craft, Trades and Enchant tabs for any party member.
## All rules live in scripts/crafting; this only lists and calls them.
## Parts are drawn from the crafter's pack first, then the rest of the party.

var hud = null
var world = null

var _crafter = null
var _tab := "craft"
var _target_entry = null ## item selected on the Enchant tab
var _who_row: HBoxContainer
var _tab_row: HBoxContainer
var _status: Label
var _list: VBoxContainer
var _scroll: ScrollContainer


func _ready() -> void:
	custom_minimum_size = Vector2(900, 560)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.07, 0.09, 0.94)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(12)
	add_theme_stylebox_override("panel", sb)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var v := VBoxContainer.new()
	add_child(v)
	var title := Label.new()
	title.text = "Workbench   (B or Esc to close. Hover a row for details.)"
	v.add_child(title)
	_who_row = HBoxContainer.new()
	v.add_child(_who_row)
	_tab_row = HBoxContainer.new()
	v.add_child(_tab_row)
	_status = Label.new()
	_status.add_theme_color_override("font_color", Color("#9aa7b3"))
	_status.add_theme_font_size_override("font_size", 13)
	v.add_child(_status)
	_scroll = ScrollContainer.new()
	_scroll.custom_minimum_size = Vector2(880, 440)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(_scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_list)
	visible = false


func open(tab := "") -> void:
	if tab != "":
		_tab = tab
	if _crafter == null or _crafter.is_dead:
		_crafter = world.player
	visible = true
	refresh()


func refresh() -> void:
	if not visible:
		return
	for c in _who_row.get_children() + _tab_row.get_children() + _list.get_children():
		c.queue_free()
	var party: Array = world.party_all()
	var who := Label.new()
	who.text = "Crafter: "
	_who_row.add_child(who)
	for a in party:
		if a.is_dead:
			continue
		var b := _button(_who_row, ("[%s]" if a == _crafter else "%s") % a.display_name, func(): _crafter = a; _target_entry = null; refresh())
		b.tooltip_text = "Let %s do the work. Their skills and schematics apply; parts come from everyone's packs." % a.display_name
	for t in [["craft", "Craft"], ["trades", "Trades and schematics"], ["enchant", "Enchant"]]:
		var id: String = t[0]
		_button(_tab_row, ("[%s]" if _tab == id else "%s") % t[1], func(): _tab = id; refresh())
	var res: int = world.resonance_at(_crafter.tile)
	var loc: Dictionary = GameState.location_at(_crafter.tile)
	_status.text = "%s at %s, Resonance %d (%s). Machines come out better where it's low, magic where it's high.   Trade points: %d" % [
		_crafter.display_name, loc.get("name", "the wilds"), res, GameState.resonance_word(res), SkillHooks.trade_points(_crafter)]
	match _tab:
		"craft":
			_fill_craft(res)
		"trades":
			_fill_trades()
		"enchant":
			_fill_enchant(res)


func _packs() -> Array:
	var packs: Array = [_crafter.inventory]
	for a in world.party_all():
		if a != _crafter and not a.is_dead:
			packs.append(a.inventory)
	return packs


func _busy() -> bool:
	if hud.combat.active:
		Events.post("[color=gray]Not in the middle of a fight.[/color]")
		return true
	return false


# ---------------------------------------------------------------- craft

func _fill_craft(res: int) -> void:
	var ids: Array = Crafting.known_craftables(_crafter)
	if ids.is_empty():
		_note("%s doesn't know any schematics, formulae or recipes yet. Buy a trade tier on the Trades tab, read a found schematic, or pay a trainer." % _crafter.display_name)
		return
	var packs := _packs()
	var last_disc := ""
	for sid in ids:
		var s: Dictionary = DB.get_schematic(sid)
		var disc := str(s.get("discipline", ""))
		if disc != last_disc:
			last_disc = disc
			_header(DB.get_discipline(disc).get("name", disc))
		var req: Dictionary = Crafting.requirements(_crafter, sid, packs)
		var b: Dictionary = Crafting.check_bonus(_crafter, s, res)
		var dc := int(s.get("dc", 10))
		var ok_ch := Crafting.chance(int(b["total"]), dc, -5)
		var std_ch := Crafting.chance(int(b["total"]), dc, 0)
		var ins: PackedStringArray = []
		for i in req["inputs"]:
			ins.append("%s %d/%d" % [Crafting.input_label(i["key"]), i["have"], i["need"]])
		var out: Dictionary = s.get("output", {})
		var row := HBoxContainer.new()
		_list.add_child(row)
		var l := Label.new()
		var tier_txt := "patent" if s.get("patent", false) else ("T%d" % int(s.get("tier", 0)) if DB.get_discipline(disc).get("tiered", true) else "recipe")
		l.text = "%s  (%s)   %s   %d%% to make, %d%% standard or better" % [s.get("name", sid), tier_txt, ", ".join(ins), roundi(ok_ch * 100), roundi(std_ch * 100)]
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.mouse_filter = Control.MOUSE_FILTER_PASS
		l.clip_text = true
		var tip: PackedStringArray = [str(DB.get_item(str(out.get("item", ""))).get("desc", ""))]
		tip.append("DC %d. Bonus %+d: %s." % [dc, int(b["total"]), Crafting.bonus_text(b)])
		tip.append("Takes %d minutes." % int(s.get("minutes", 30)))
		if s.has("desc"):
			tip.append(str(s["desc"]))
		for p in req["problems"]:
			tip.append("! " + p)
		l.tooltip_text = "\n".join(tip)
		if not req["ok"]:
			l.add_theme_color_override("font_color", Color("#8a8f96"))
		row.add_child(l)
		var btn := _button(row, "Craft", func(): _do_craft(sid))
		btn.disabled = not req["ok"]


func _do_craft(sid: String) -> void:
	if _busy():
		return
	var r := Crafting.craft(_crafter, sid, _packs(), world.resonance_at(_crafter.tile))
	for line in r["lines"]:
		Events.post(line)
	if int(r.get("self_damage", 0)) > 0:
		_crafter.take_damage(int(r["self_damage"]))
	refresh.call_deferred()


# ---------------------------------------------------------------- trades

func _fill_trades() -> void:
	var k: CraftingKnowledge = _crafter.crafting
	for did in DB.disciplines:
		var d: Dictionary = DB.disciplines[did]
		var row := HBoxContainer.new()
		_list.add_child(row)
		var l := Label.new()
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.mouse_filter = Control.MOUSE_FILTER_PASS
		l.tooltip_text = "%s (%s pool, %s skill)" % [d.get("desc", ""), d.get("pool", "neutral"), d.get("skill", "")]
		row.add_child(l)
		if not d.get("tiered", true):
			var n := 0
			for sid in k.known:
				if DB.get_schematic(sid).get("discipline", "") == did:
					n += 1
			l.text = "%s   recipes known: %d   (learned from smiths and slates, no tiers)" % [d["name"], n]
			l.add_theme_color_override("font_color", Color("#ffd84d"))
			continue
		var t := SkillHooks.tier(_crafter, did)
		l.text = "%s   tier %d of 5" % [d["name"], t]
		l.add_theme_color_override("font_color", Color("#ffd84d"))
		if t < CraftingKnowledge.MAX_TIER:
			_button(row, "Buy tier %d (1 point)" % (t + 1), func():
				var r := Crafting.buy_tier(_crafter, did)
				Events.post(r["msg"] if r["msg"] != "" else "Tier bought.")
				refresh.call_deferred())
		for tier_i in range(1, t + 1):
			var offered: Array = d.get("tiers", {}).get(str(tier_i), [])
			var left := SkillHooks.picks_left(_crafter, did, tier_i)
			var line := HBoxContainer.new()
			_list.add_child(line)
			var tl := Label.new()
			tl.text = "      Tier %d: %s" % [tier_i, "pick %d" % left if left > 0 else "done"]
			tl.custom_minimum_size = Vector2(140, 0)
			line.add_child(tl)
			for sid in offered:
				var s: Dictionary = DB.get_schematic(sid)
				if k.knows(sid):
					var kl := Label.new()
					kl.text = " %s (known) " % s.get("name", sid)
					kl.add_theme_color_override("font_color", Color("#9fe07f"))
					line.add_child(kl)
				elif left > 0:
					var b := _button(line, "Pick: " + str(s.get("name", sid)), func():
						var r := Crafting.pick(_crafter, did, tier_i, sid)
						Events.post(r["msg"])
						refresh.call_deferred())
					b.tooltip_text = _schematic_tip(s)
				else:
					var ul := Label.new()
					ul.text = " %s " % s.get("name", sid)
					ul.add_theme_color_override("font_color", Color("#6d737a"))
					ul.tooltip_text = "Not picked. Find or buy the schematic to learn it anyway."
					ul.mouse_filter = Control.MOUSE_FILTER_PASS
					line.add_child(ul)
	var patents: PackedStringArray = []
	for sid in DB.schematics:
		var s: Dictionary = DB.schematics[sid]
		if s.get("patent", false):
			var req: PackedStringArray = []
			for dd in s.get("requires_tiers", {}):
				req.append("%s %d" % [DB.get_discipline(dd).get("name", dd), int(s["requires_tiers"][dd])])
			patents.append("%s (%s)%s" % [s.get("name", sid), " + ".join(req), " known" if k.knows(sid) else ""])
	if not patents.is_empty():
		_header("Cross-trade patents: " + ";  ".join(patents))


func _schematic_tip(s: Dictionary) -> String:
	if s.has("enchantment"):
		var en := DB.get_enchantment(str(s["enchantment"]))
		return "%s: %s Essences: %s." % [en.get("name", "?"), en.get("desc", ""), _ess_text(en)]
	var ins: PackedStringArray = []
	for key in s.get("inputs", {}):
		ins.append("%d %s" % [int(s["inputs"][key]), Crafting.input_label(key)])
	var out: Dictionary = DB.get_item(str(s.get("output", {}).get("item", "")))
	return "%s\nNeeds: %s. DC %d." % [out.get("desc", ""), ", ".join(ins), int(s.get("dc", 10))]


func _ess_text(en: Dictionary) -> String:
	var bits: PackedStringArray = []
	var ess: Dictionary = en.get("essences", {})
	for key in ess:
		bits.append("%d %s" % [int(ess[key]), Crafting.input_label(key)])
	return ", ".join(bits) if not bits.is_empty() else "none"


# ---------------------------------------------------------------- enchant

func _fill_enchant(res: int) -> void:
	var known: Array = Enchanting.known_enchantments(_crafter)
	if known.is_empty():
		_note("%s knows no enchantment formulae. Iska starts with Frost Edge and Warding Glyph; switch the crafter to her." % _crafter.display_name)
		return
	_header("1. Choose an item (anyone's pack)")
	var flow := HFlowContainer.new()
	_list.add_child(flow)
	for a in world.party_all():
		for e in a.inventory.entries:
			if ItemStats.enchant_slots(e) <= 0 and ItemStats.enchant_ids(e).is_empty():
				continue
			var label := "%s%s  [%d/%d]" % ["> " if e == _target_entry else "", DB.entry_name(e), maxi(0, ItemStats.free_slots(e)), ItemStats.enchant_slots(e)]
			var b := _button(flow, label, func(): _target_entry = e; refresh())
			b.tooltip_text = "%s's pack\n%s" % [a.display_name, DB.describe(e)]
	if _target_entry == null:
		return
	var packs := _packs()
	_header("2. Bind an enchantment onto %s" % DB.entry_name(_target_entry))
	var qc := Enchanting.quirk_chance(_target_entry)
	if qc > 0.0:
		_note("This is a machine. Each binding risks a quirk (%d%%) and adds %d%% misfire. Magic and machinery don't sit well together." % [roundi(qc * 100), roundi(ItemStats.GEAR_ENCHANT_MISFIRE * 100)])
	for eid in known:
		var en: Dictionary = DB.get_enchantment(eid)
		var req: Dictionary = Enchanting.requirements(_crafter, _target_entry, eid, packs)
		var b: Dictionary = Enchanting.check_bonus(_crafter, en, res)
		var dc := Enchanting.dc(_target_entry, en)
		var row := HBoxContainer.new()
		_list.add_child(row)
		var l := Label.new()
		l.text = "%s   %s   essences: %s   %d%% to bind, %d%% to botch" % [en.get("name", eid), en.get("desc", ""), _ess_text(en),
			roundi(Crafting.chance(int(b["total"]), dc) * 100), roundi((1.0 - Crafting.chance(int(b["total"]), dc, -9)) * 100)]
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.clip_text = true
		l.mouse_filter = Control.MOUSE_FILTER_PASS
		var tip: PackedStringArray = ["DC %d. Bonus %+d: %s." % [dc, int(b["total"]), Crafting.bonus_text(b)]]
		for p in req["problems"]:
			tip.append("! " + p)
		l.tooltip_text = "\n".join(tip)
		if not req["ok"]:
			l.add_theme_color_override("font_color", Color("#8a8f96"))
		row.add_child(l)
		var btn := _button(row, "Bind", func():
			if _busy():
				return
			var r := Enchanting.enchant(_crafter, _target_entry, eid, _packs(), world.resonance_at(_crafter.tile))
			for line in r["lines"]:
				Events.post(line)
			refresh.call_deferred())
		btn.disabled = not req["ok"]


# ---------------------------------------------------------------- helpers

func _header(text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", Color("#ffd84d"))
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_list.add_child(l)


func _note(text: String) -> void:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(860, 0)
	l.add_theme_color_override("font_color", Color("#9aa7b3"))
	_list.add_child(l)


func _button(parent: Control, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	parent.add_child(b)
	return b
