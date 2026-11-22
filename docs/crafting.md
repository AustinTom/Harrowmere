# Crafting, identification and enchanting

All three systems are rules over JSON data. The code lives in `scripts/crafting/`, the
data in `data/crafting/` and `data/items/`. The UI (`scripts/ui/crafting_panel.gd`, popups
in `hud.gd`) only lists things and calls the rules.

## The loop in one paragraph

You learn **schematics** (Gear), **formulae** (arcane and divine) and **recipes** (neutral).
Parts come from the crafter's pack first and then the rest of the party. A check of
d20 + skill + Resonance + aptitude + tier surplus against the schematic's DC sets the
**quality** (crude, standard, fine, masterwork). Quality sets the **enchant slots** (0 to 3).
Enchanters spend **essences** to bind enchantments into those slots. Magic loot drops
**unidentified**, with its enchantments dormant and any curse already working, until
someone identifies it.

## Learning

| Source | How it works |
|---|---|
| Trade tiers | 6 Gear trades (Ballistics, Steamworks, Galvanics, Optics, Demolition, Automata) plus Herbalism, Enchanting and Consecration. Each has 5 tiers of 4 schematics. Buying a tier costs a trade point; you **pick 2 of the 4**. |
| Patents | Tier 5 in the two trades a patent names unlocks it automatically (example: Galvanic Rifle, Ballistics 5 + Galvanics 5). |
| Found or bought sheets | Items with `"type": "schematic"` and `"teaches"`. Reading one teaches it outright, but you still need the tier to build it. |
| Trainers | Dialogue effect `learn_schematic` (Wendle Cobb sells two). |
| Recipes | Untiered disciplines (Smithing) are learned only from trainers and sheets. |

Trade tiers and points belong to the character system. `SkillHooks` calls `actor.tier()`,
`can_buy()`, `buy("tier", id)`, `schematic_picks_left()`, `skill_bonus()` and appends picks
to `actor.sheet.schematics` when the character sheet provides them. Until then a
crafting-owned fallback (`CraftingKnowledge`) keeps tiers and points so this branch runs on
its own.

## Making things

| Margin | Result |
|---|---|
| +10 or natural 20 | Masterwork: +1 hit, +1 damage, half misfires, 3 slots |
| +5 to +9 | Fine: +1 hit, 3/4 misfires, 2 slots |
| 0 to +4 | Standard: 1 slot |
| -1 to -5 | Crude: -1 hit, -1 damage, 1.5x misfires, 0 slots |
| -6 to -9 | Failed: about half the parts are lost |
| -10 or natural 1 | Botched: all parts lost; some Steamworks and Demolition work hurts you |

**Magic vs tech.** Gear checks get +5 at Resonance 0 down to -5 at 100; arcane checks the
reverse; divine checks half as much. Gear-leaning aptitude helps Gear work and the reverse.
The two sides never share inputs: machines eat coal, iron and brass; magic eats herbs and
essences. Galvanic damage (spark baton, galvanic rifle) is strongest where Resonance is dead,
the mirror of arcane damage.

## Identification

| Method | Check | Notes |
|---|---|---|
| Identify spell / Divine Sight prayer | d20 + stat + proficiency + Resonance | Reveals curses. One try per caster per item per day. |
| Assayer's Lens | d20 + Mechanics + 8 + Gear Resonance mod | Used up either way. Spots the curse only on a margin of 5+. |
| Appraiser (NPC) | Template `"appraiser"` block | Fee = value x rate. `honesty` and `reveals_curses` vary per person. Hesta is honest and sees curses; Wendle is cheap and can't. |
| Equip it | None | A curse wakes at once. After `ident_uses` hits (default 5) you know what it is. |

Curses (entries in `enchantments.json` with `"curse": true`) work even while unknown.
A `sticky` curse stops you unequipping or handing the item over. Lantern Water (Consecration)
or a priest (`lift_curse` dialogue effect, `lift_curse_fee`) removes it.

## Enchanting

Needs the formula, the essences, an Etching Stylus (divine blessings need no tool), an
identified uncursed item of the right kind (`applies_to`: weapon, armor, trinket, melee,
ranged, focus, any, or any item tag) and a free slot. DC rises by 2 per enchantment already on
the item. Failure spends the essences; a botch leaves a Flawed Glyph curse. **Machines resist:**
each binding on an item with Gear content risks a quirk (+3% misfire) at
`gear_content x 50%`, and every enchantment on a machine adds 2% misfire regardless.

## Data formats

```jsonc
// data/items/*.json  (any number of files; merged with data/items.json)
"emberglass_knife": {
  "extends": "iron_dagger",                   // inherit fields, override below
  "name": "Emberglass Knife", "value": 180,
  "identify_required": true, "unidentified_name": "A knife warm to the touch",
  "hint": "Warm as a hearthstone.",           // shown while unidentified
  "magic": {"enchants": ["ember_edge"], "curse": ""},  // hidden until identified
  "ident_dc": 12, "ident_uses": 5,            // optional overrides
  "gear_content": 0.8,                        // optional, 0..1 (Gear default 0.7)
  "enchant_slots_bonus": 1, "tags": ["focus"] // material/tag hooks
}

// data/crafting/schematics.json  (or data/crafting/schematics/*.json)
"clockwork_trigger": {
  "name": "Clockwork Trigger", "discipline": "ballistics", "tier": 2,
  "inputs": {"brass_spring": 1, "ratchet_housing": 1},   // or "tag:essence": 1
  "output": {"item": "clockwork_trigger", "qty": 1},
  "dc": 12, "minutes": 40, "tools": ["tinker_tools"], "botch_damage": "1d6"
}
"ench_frost_edge": {"discipline": "enchanting", "tier": 1, "kind": "formula", "enchantment": "frost_edge"}
"galvanic_rifle": {..., "patent": true, "requires_tiers": {"ballistics": 5, "galvanics": 5}}

// data/crafting/enchantments.json
"frost_edge": {"name": "Frost Edge", "short": "frost", "school": "arcane",
  "applies_to": ["weapon"], "essences": {"frost_essence": 2}, "dc": 12,
  "effects": {"extra_damage": [{"dice": "1d6", "type": "cold", "school": "arcane"}]},
  "min_resonance": 0, "tool": "etching_tools", "value": 120}
// effect keys: to_hit, damage_flat, ac_bonus, spell_power, misfire_add, special[], extra_damage[]
```

Inventory entries carry instance data (`quality`, `enchants`, `curse`, `curse_known`,
`quirks`, `uses`). Always read an entry through `ItemStats.resolve(entry)`, not
`DB.get_item()`, for anything that fights, equips or sells.

## Scaling to ~1,500 items

* Split items across `data/items/*.json` by family or trade; use `extends` for material
  variants (iron / steel / starglass versions of one weapon are a few lines each).
* Generated magic loot = base item + rolled `enchants` on the entry (`Inventory.add(id, 1,
  false, {"enchants": [...]})`), so enchantments multiply the base list without new entries.
* The data linter in `tests/crafting_tests.gd` checks every reference (inputs, outputs, tools,
  tags, tier lists, formulae, curses). Run it after any content drop.

## Open hooks for other threads

* Character system: replace the fallback with the sheet API (already wired through
  `SkillHooks`); consider moving enchantment `effects` to its `modifiers` vocabulary.
* Equipment slots: armor and trinkets can be crafted and enchanted, but only the weapon slot
  is equipped today.
* Stations and homes: schematics can take a `"station"` requirement once homes have
  workshops and enchanting tables.
* Shops: dialogue `buy_item` is a stand-in for a real merchant inventory.
