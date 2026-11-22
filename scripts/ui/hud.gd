extends CanvasLayer
## All 2D UI, built in code: status, party, hotbar, combat log, turn order,
## hover info, inventory (player + followers) and dialogue.

var world = null
var combat = null
var controller = null

var _info: Label
var _party: Label
var _hotbar: Label
var _turn: Label
var _turn_panel: PanelContainer
var _hover: Label
var _banner: Label
var _log: RichTextLabel
var _inv: PanelContainer
var _inv_row: HBoxContainer
var _dlg: PanelContainer
var _dlg_text: RichTextLabel
var _dlg_opts: VBoxContainer
var _dlg_actor = null
var _dlg_data: Dictionary = {}
var _banner_time := 0.0
var crafting_panel = null
var _pop: PanelContainer
var _pop_text: RichTextLabel
var _pop_opts: VBoxContainer


func _ready() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	var info_panel := _panel(root, false)
	info_panel.position = Vector2(12, 12)
	_info = Label.new()
	info_panel.add_child(_info)

	var party_panel := _panel(root, false)
	var pv := VBoxContainer.new()
	party_panel.add_child(pv)
	_party = Label.new()
	pv.add_child(_party)
	_hotbar = Label.new()
	_hotbar.add_theme_color_override("font_color", Color("#ffd84d"))
	pv.add_child(_hotbar)
	var keys := Label.new()
	keys.text = "Left-click: move / attack / talk   Right-click: examine   1-4: action   T: turn-based <-> real-time   Space: end turn   I: inventory   C: workbench   Wheel: zoom"
	keys.add_theme_color_override("font_color", Color("#9aa7b3"))
	keys.add_theme_font_size_override("font_size", 13)
	pv.add_child(keys)
	party_panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE, 12)
	party_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN

	var log_panel := _panel(root, false)
	log_panel.custom_minimum_size = Vector2(470, 240)
	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.scroll_following = true
	_log.custom_minimum_size = Vector2(450, 220)
	_log.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_log.add_theme_font_size_override("normal_font_size", 13)
	_log.add_theme_font_size_override("bold_font_size", 13)
	log_panel.add_child(_log)
	log_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 12)
	log_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN

	_turn_panel = _panel(root, false)
	_turn = Label.new()
	_turn.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_turn_panel.add_child(_turn)
	_turn_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP, Control.PRESET_MODE_MINSIZE, 12)
	_turn_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH

	_hover = Label.new()
	_hover.add_theme_constant_override("outline_size", 6)
	_hover.add_theme_color_override("font_outline_color", Color.BLACK)
	_hover.add_theme_font_size_override("font_size", 14)
	_hover.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_hover)

	_banner = Label.new()
	_banner.add_theme_font_size_override("font_size", 42)
	_banner.add_theme_constant_override("outline_size", 10)
	_banner.add_theme_color_override("font_outline_color", Color.BLACK)
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_banner)
	_banner.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_banner.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_banner.position.y -= 160
	_banner.visible = false

	_inv = _panel(root, true)
	var iv := VBoxContainer.new()
	_inv.add_child(iv)
	var it := Label.new()
	it.text = "Inventory   (I or Esc to close. Hover an item for details.)"
	iv.add_child(it)
	var inv_scroll := ScrollContainer.new()
	inv_scroll.custom_minimum_size = Vector2(900, 600)
	inv_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	iv.add_child(inv_scroll)
	_inv_row = HBoxContainer.new()
	_inv_row.add_theme_constant_override("separation", 24)
	inv_scroll.add_child(_inv_row)
	_inv.visible = false

	_dlg = _panel(root, true)
	_dlg.custom_minimum_size = Vector2(680, 0)
	var dv := VBoxContainer.new()
	_dlg.add_child(dv)
	_dlg_text = RichTextLabel.new()
	_dlg_text.bbcode_enabled = true
	_dlg_text.fit_content = true
	_dlg_text.custom_minimum_size = Vector2(660, 0)
	dv.add_child(_dlg_text)
	_dlg_opts = VBoxContainer.new()
	dv.add_child(_dlg_opts)
	_dlg.visible = false

	crafting_panel = preload("res://scripts/ui/crafting_panel.gd").new()
	crafting_panel.hud = self
	crafting_panel.world = world
	root.add_child(crafting_panel)

	# Small choice popup: identify methods, appraisal, curse lifting.
	_pop = _panel(root, true)
	_pop.custom_minimum_size = Vector2(620, 0)
	var pv2 := VBoxContainer.new()
	_pop.add_child(pv2)
	_pop_text = RichTextLabel.new()
	_pop_text.bbcode_enabled = true
	_pop_text.fit_content = true
	_pop_text.custom_minimum_size = Vector2(600, 0)
	pv2.add_child(_pop_text)
	_pop_opts = VBoxContainer.new()
	pv2.add_child(_pop_opts)
	_pop.visible = false

	Events.log_message.connect(_on_log)
	Events.inventory_changed.connect(_on_inventory_changed)
	combat.combat_started.connect(_on_combat_started)
	combat.combat_ended.connect(_on_combat_ended)


func _panel(parent: Control, interactive: bool) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.08, 0.1, 0.84)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(10)
	sb.border_color = Color(0.4, 0.45, 0.5, 0.6)
	sb.set_border_width_all(1)
	p.add_theme_stylebox_override("panel", sb)
	p.mouse_filter = Control.MOUSE_FILTER_STOP if interactive else Control.MOUSE_FILTER_IGNORE
	parent.add_child(p)
	return p


func _center(c: Control, y_offset := 0.0) -> void:
	var vs := get_viewport().get_visible_rect().size
	c.reset_size()
	c.position = Vector2((vs.x - c.size.x) / 2.0, (vs.y - c.size.y) / 2.0 + y_offset)


func _process(delta: float) -> void:
	if world == null or world.player == null:
		return
	var p = world.player
	var loc: Dictionary = GameState.location_at(p.tile)
	var res := int(loc.get("resonance", 50))
	var state := "Exploring, fights start %s" % combat.mode_name()
	if combat.active:
		state = "[COMBAT] %s" % combat.mode_name().to_upper()
	_info.text = "%s, %s\n%s   Resonance %d (%s)\n%s   %s" % [
		world.area.get("name", ""), world.area.get("region", ""),
		loc.get("name", "Wilds"), res, GameState.resonance_word(res),
		GameState.time_text(), state]

	var lines: PackedStringArray = []
	for a in world.party_all():
		if a.is_dead:
			lines.append("%s  (down)" % a.display_name)
			continue
		var ap_txt := "%d/%d" % [floori(maxf(a.ap, 0.0)), a.ap_max] if a.in_combat else "-"
		var apt := "balanced" if a.aptitude == 0 else ("Arcane %+d" % a.aptitude if a.aptitude > 0 else "Gear %d" % -a.aptitude)
		lines.append("%s   HP %d/%d   AP %s   %s   [%s]" % [a.display_name, a.hp, a.max_hp, ap_txt, DB.entry_name(a.equipped_entry()) if a.equipped_entry() != null else "Fists", apt])
	_party.text = "\n".join(lines)
	_hotbar.text = controller.hotbar_text() if controller else ""

	_turn_panel.visible = combat.active
	if combat.active:
		if combat.is_turn_based():
			var names: PackedStringArray = []
			var cur = combat.current_actor()
			for a in combat.combatants:
				names.append((">> %s <<" if a == cur else "%s") % a.display_name)
			var who := "Your turn" if cur == p else ("%s's turn" % cur.display_name if cur else "")
			_turn.text = "TURN-BASED   %s\n%s" % [who, "   ".join(names)]
		else:
			_turn.text = "REAL-TIME   AP refills every %.0fs\nPress T to pause into turn-based" % combat.ROUND_SECONDS

	if _banner.visible:
		_banner_time -= delta
		if _banner_time <= 0.0:
			_banner.visible = false
	if _dlg.visible:
		_center(_dlg, 170)
	if _inv.visible:
		_center(_inv)
	if crafting_panel.visible:
		_center(crafting_panel)
	if _pop.visible:
		_center(_pop, -40)


func banner(text: String, c := Color.WHITE, secs := 2.0) -> void:
	_banner.text = text
	_banner.add_theme_color_override("font_color", c)
	_banner.visible = true
	_banner_time = secs
	_banner.reset_size()
	var vs := get_viewport().get_visible_rect().size
	_banner.position = Vector2((vs.x - _banner.size.x) / 2.0, vs.y * 0.3)


func set_hover(text: String, pos: Vector2) -> void:
	_hover.text = text
	_hover.position = pos + Vector2(18, 14)


func _on_log(text: String) -> void:
	_log.append_text(text + "\n")


func _on_combat_started() -> void:
	close_dialogue()
	banner("Combat!", Color("#ff8080"))


func _on_combat_ended(victory: bool) -> void:
	if victory:
		banner("Victory", Color("#80ff9f"))
	else:
		banner("You have fallen. Press R to restart.", Color("#ff8080"), 9999.0)


# ---------------------------------------------------------------- inventory

func toggle_inventory() -> void:
	_inv.visible = not _inv.visible
	if _inv.visible:
		refresh_inventory()


func toggle_crafting() -> void:
	if crafting_panel.visible:
		crafting_panel.visible = false
	else:
		_inv.visible = false
		crafting_panel.open()


func close_panels() -> void:
	_inv.visible = false
	crafting_panel.visible = false
	_pop.visible = false
	close_dialogue()


func is_blocking() -> bool:
	return _dlg.visible or _pop.visible or crafting_panel.visible


func _on_inventory_changed() -> void:
	if _inv.visible:
		refresh_inventory.call_deferred()
	if crafting_panel.visible:
		crafting_panel.refresh.call_deferred()


func refresh_inventory() -> void:
	for c in _inv_row.get_children():
		c.queue_free()
	var members: Array = world.party_all()
	for a in members:
		var col := VBoxContainer.new()
		col.custom_minimum_size = Vector2(430, 0)
		_inv_row.add_child(col)
		var title := Label.new()
		title.text = "%s   HP %d/%d%s" % [a.display_name, a.hp, a.max_hp, "  (down)" if a.is_dead else ""]
		title.add_theme_color_override("font_color", Color("#ffd84d"))
		col.add_child(title)
		for e in a.inventory.entries:
			var item: Dictionary = DB.get_item(e["id"])
			var row := HBoxContainer.new()
			col.add_child(row)
			var l := Label.new()
			l.text = DB.entry_name(e) + (" x%d" % e["qty"] if e["qty"] > 1 else "") + ("   (equipped)" if e["equipped"] else "")
			l.tooltip_text = DB.describe(e)
			l.mouse_filter = Control.MOUSE_FILTER_PASS
			l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			if not e["identified"]:
				l.add_theme_color_override("font_color", Color("#c49bff"))
			row.add_child(l)
			if a.is_dead:
				continue
			if item.get("type") == "weapon" and not e["equipped"]:
				_btn(row, "Equip", func(): combat.do_equip(a, e))
			if item.get("type") == "consumable":
				_btn(row, "Use", func(): combat.do_use_item(a, e))
			if item.get("type") == "schematic":
				_btn(row, "Read", func(): combat.do_read(a, e))
			if not e["identified"]:
				_btn(row, "Identify", func(): open_identify(e))
			if ItemStats.is_stuck(e):
				continue
			for other in members:
				if other != a and not other.is_dead:
					_btn(row, "Give to " + other.display_name.split(" ")[0], func(): _give(a, e, other))


func _give(from, e: Dictionary, to) -> void:
	if ItemStats.is_stuck(e):
		return
	var was_equipped: bool = e["equipped"]
	e["equipped"] = false
	from.inventory.transfer(e, to.inventory)
	Events.post("%s gives %s to %s." % [from.display_name, DB.entry_name(e), to.display_name])
	if was_equipped:
		from.equip_entry(null)


# ---------------------------------------------------------------- popups

func _show_popup(text: String, options: Array) -> void:
	_pop_text.text = text
	for c in _pop_opts.get_children():
		c.queue_free()
	for o in options:
		var b := Button.new()
		b.text = o["text"]
		b.focus_mode = Control.FOCUS_NONE
		b.disabled = o.get("disabled", false)
		b.tooltip_text = o.get("tip", "")
		b.pressed.connect(o["cb"])
		_pop_opts.add_child(b)
	_btn(_pop_opts, "Close", func(): _pop.visible = false)
	_pop.visible = true
	_pop.reset_size()


func _post_all(lines: Array) -> void:
	for l in lines:
		Events.post(l)


## Every identification method the party has for one item.
func open_identify(e: Dictionary) -> void:
	var res: int = world.resonance_at(world.player.tile)
	var opts: Array = []
	for o in Identification.options(e, world.party_all(), res):
		var label := "%s   %d%%   (%s)" % [o["label"], roundi(o["chance"] * 100), o["note"]]
		var cb: Callable
		if o["kind"] == "spell":
			var caster = o["actor"]
			var sid: String = o["skill"]
			cb = func(): _post_all(Identification.by_spell(caster, e, sid, world.resonance_at(caster.tile))["lines"]); open_identify_refresh(e)
		else:
			var user = o["actor"]
			var lens: Dictionary = o["lens"]
			var pack = o["pack"]
			cb = func(): _post_all(Identification.by_lens(user, e, lens, pack, world.resonance_at(user.tile))["lines"]); open_identify_refresh(e)
		opts.append({"text": label, "cb": cb, "disabled": o["chance"] <= 0.0})
	var who = _holder_of(e)
	if who != null and ItemStats.base(e).get("type") == "weapon" and not e["equipped"]:
		opts.append({"text": "%s: equip it and find out (a curse would wake at once)" % who.display_name.split(" ")[0],
			"cb": func(): combat.do_equip(who, e); _pop.visible = false})
	var txt := "[b]%s[/b]\n%s\nDifficulty %d. Resonance here is %d: spells read better where it's high, lenses where it's low. Appraisers in town (Wendle Cobb, Hesta Lowe) will do it for coin." % [
		DB.entry_name(e), ItemStats.base(e).get("hint", ""), Identification.dc(e), res]
	_show_popup(txt, opts)


func open_identify_refresh(e: Dictionary) -> void:
	if e.get("identified", false):
		_pop.visible = false
	else:
		open_identify(e)


func _holder_of(e: Dictionary):
	for a in world.party_all():
		if a.inventory.entries.has(e):
			return a
	return null


## Paid identification by an NPC appraiser.
func open_appraisal(appraiser) -> void:
	var a: Dictionary = DB.get_actor_template(appraiser.template_id).get("appraiser", {})
	var opts: Array = []
	for m in world.party_all():
		for e in m.inventory.entries:
			var unknown_curse: bool = a.get("reveals_curses", false) and e["identified"] and not ItemStats.curse_known(e) and ItemStats.base(e).has("magic")
			if e["identified"] and not unknown_curse:
				continue
			var cost := Identification.fee(a, e)
			opts.append({"text": "%s (%s)   %d coin" % [DB.entry_name(e), m.display_name.split(" ")[0], cost],
				"cb": func(): _post_all(Identification.by_appraiser(appraiser, world.player, e)["lines"]); open_appraisal(appraiser)})
	var txt := "[b]%s[/b] will name your finds for a fee. You have %d coin.%s" % [appraiser.display_name, world.player.inventory.count("coin"),
		"" if a.get("reveals_curses", false) else "\n[color=gray]A lens-and-gauge man. Curses don't show on gauges.[/color]"]
	if opts.is_empty():
		txt += "\nNothing unknown in the party's packs."
	_show_popup(txt, opts)


## Priest service: lift a known curse for coin.
func open_lift_curse(priest) -> void:
	var a: Dictionary = DB.get_actor_template(priest.template_id).get("appraiser", {})
	var fee := int(a.get("lift_curse_fee", 0))
	var opts: Array = []
	if fee > 0:
		for m in world.party_all():
			for e in m.inventory.entries:
				if ItemStats.is_cursed(e) and ItemStats.curse_known(e):
					opts.append({"text": "%s (%s)   %d coin" % [DB.entry_name(e), m.display_name.split(" ")[0], fee], "cb": func():
						if world.player.inventory.count("coin") < fee:
							Events.post("[color=gray]%d coin needed.[/color]" % fee)
							return
						world.player.inventory.remove_id("coin", fee)
						Identification.lift_curse(e)
						m.refresh_stats()
						Events.post("[color=#ffe9a8]%s prays over the %s. The curse lifts.[/color]" % [priest.display_name, DB.entry_name(e)])
						open_lift_curse(priest)})
	var txt := "[b]%s[/b]: %s" % [priest.display_name, "\"Show me what's got its hooks in you.\"" if fee > 0 else "\"That's priest's work, not mine.\""]
	if fee > 0 and opts.is_empty():
		txt += "\nNo known curses in the party's packs. (An unknown curse has to wake first, or be named.)"
	_show_popup(txt, opts)


func _btn(parent: Control, text: String, cb: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	parent.add_child(b)


# ---------------------------------------------------------------- dialogue

func open_dialogue(actor) -> void:
	var dlg: Dictionary = DB.get_dialogue(actor.dialogue_id)
	if dlg.is_empty():
		return
	_dlg_actor = actor
	_dlg_data = dlg
	_show_node(DialogueRunner.entry_node(dlg))


func close_dialogue() -> void:
	_dlg.visible = false
	_dlg_actor = null


func _show_node(id: String) -> void:
	var nodes: Dictionary = _dlg_data.get("nodes", {})
	if id == "" or not nodes.has(id):
		close_dialogue()
		return
	var node: Dictionary = nodes[id]
	DialogueRunner.apply_effects(node.get("effects", []), world.player, _dlg_actor)
	_dlg_text.text = "[b][color=#ffd84d]%s[/color][/b]\n%s" % [_dlg_actor.display_name, node.get("text", "")]
	for c in _dlg_opts.get_children():
		c.queue_free()
	var i := 1
	for o in DialogueRunner.visible_options(node):
		_btn(_dlg_opts, "%d. %s" % [i, o.get("text", "...")], func(): _choose(o))
		i += 1
	_dlg.visible = true


func _choose(o: Dictionary) -> void:
	var speaker = _dlg_actor
	var req := DialogueRunner.apply_effects(o.get("effects", []), world.player, speaker)
	var nxt = o.get("next", "")
	if nxt == null or str(nxt) == "":
		close_dialogue()
	else:
		_show_node(str(nxt))
	if req.has("open_inventory"):
		_inv.visible = true
		refresh_inventory()
	if req.has("open_crafting"):
		crafting_panel.open()
	if req.has("open_appraisal") and speaker != null:
		open_appraisal(speaker)
	if req.has("lift_curse") and speaker != null:
		open_lift_curse(speaker)
