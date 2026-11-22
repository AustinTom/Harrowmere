#!/usr/bin/env python3
"""Generates data/character/abilities.json and data/character/summons.json.

Names, flavour and the shape of each ability are authored here, one line each.
Numbers (dice, AP, range, durations, area) come from the template and the tier,
so the whole set stays balanced and can be retuned in one place.

Run from the repo root:  python3 tools/gen_abilities.py
"""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DISC = json.loads((ROOT / "data/character/disciplines.json").read_text())

# ----------------------------------------------------------------- authored rows
# (tier, name, template, params, flavour)
# Templates are documented in docs/character-system.md ("Ability templates").

ROWS = {
  "evocation": [
    (1, "Arcane Bolt", "bolt", {"type": "force"}, "A bolt of raw arcane force."),
    (1, "Kindle", "dot", {"type": "fire", "status": "burning"}, "Sets a target alight."),
    (2, "Frost Lance", "lance", {"type": "cold", "status": "chilled"}, "A spear of ice that numbs as it strikes."),
    (2, "Thunderclap", "blast", {"type": "force"}, "A crack of force that knocks the breath out of everyone nearby."),
    (3, "Fireball", "blast", {"type": "fire"}, "The classic. Mind your friends."),
    (3, "Chain Spark", "bolt", {"type": "lightning", "hits": 2}, "Lightning that leaps to a second target."),
    (4, "Ice Storm", "blast", {"type": "cold", "status": "slowed"}, "Hail and frost over a wide circle."),
    (4, "Searing Ray", "lance", {"type": "fire", "status": "burning"}, "A white-hot beam."),
    (5, "Meteor Fall", "blast", {"type": "fire", "big": True}, "Calls burning stone down from the sky."),
    (5, "Starfire Lance", "lance", {"type": "force", "big": True}, "Pure arcane force, enough to punch through a wall."),
  ],
  "abjuration": [
    (1, "Ward", "boon", {"status": "shielded"}, "A shimmering shield around an ally."),
    (1, "Dispel", "cleanse", {}, "Strips hostile magic and ailments from an ally."),
    (2, "Warded Mind", "passive", {"mods": [{"target": "save:magic", "add": 2}]}, "Practised defences against hostile spells."),
    (2, "Barrier", "boon", {"status": "warded"}, "Turns aside spells and blows alike."),
    (3, "Repel", "push", {"type": "force", "tiles": 2}, "Hurls an enemy away."),
    (3, "Null Field", "control", {"status": "silenced", "save": "wis", "area": True}, "A circle where no spell can be cast."),
    (4, "Greater Ward", "boon", {"status": "shielded", "long": True}, "A lasting shield."),
    (4, "Banishing Word", "lance", {"type": "force", "status": "stunned"}, "A word that tears at anything that doesn't belong."),
    (5, "Aegis", "mass_boon", {"status": "shielded"}, "Shields the whole party."),
    (5, "Unmaking", "control", {"status": "stunned", "save": "con", "damage": True}, "Unpicks the target's own magic and leaves them reeling."),
  ],
  "conjuration": [
    (1, "Acid Splash", "dot", {"type": "acid", "status": "corroded"}, "A gout of conjured acid."),
    (1, "Summon Familiar", "summon", {"creature": "familiar"}, "A small spirit-beast that fights at your side."),
    (2, "Grasping Mist", "control", {"status": "rooted", "save": "str", "area": True}, "A clinging fog that holds feet in place."),
    (2, "Summon Hound", "summon", {"creature": "spectral_hound"}, "A spectral hound with real teeth."),
    (3, "Acid Rain", "blast", {"type": "acid", "status": "corroded"}, "A brief, very bad shower."),
    (3, "Summon Ember Spirit", "summon", {"creature": "ember_spirit"}, "A spirit of living flame."),
    (4, "Blink Strike", "touch", {"type": "force", "big": True}, "Step through nothing and strike from behind."),
    (4, "Summon Meltwater Spirit", "summon", {"creature": "meltwater_spirit"}, "A spirit from the thawing rivers."),
    (5, "Grasping Deep", "control", {"status": "rooted", "save": "str", "area": True, "damage": True}, "Black hands from below drag at everything."),
    (5, "Summon Gate Beast", "summon", {"creature": "gate_beast"}, "Something large, from somewhere else."),
  ],
  "divination": [
    (1, "Detect Magic", "utility", {"effect": "detect_magic"}, "Shows enchanted items and magic nearby."),
    (1, "Glimpse Ahead", "self_boon", {"status": "focused"}, "A moment's foresight."),
    (2, "Identify", "utility", {"effect": "identify"}, "Learn what an unknown item really is."),
    (2, "True Strike", "boon", {"status": "focused"}, "Shows an ally exactly where to strike."),
    (3, "Third Eye", "passive", {"mods": [{"target": "skill:perception", "add": 2}, {"target": "attack", "add": 1}]}, "You see a little of what's coming."),
    (3, "Expose Weakness", "curse", {"status": "exposed"}, "Shows everyone where the target is weakest."),
    (4, "Scry", "utility", {"effect": "reveal"}, "Reveals hidden sites and enemies in the area."),
    (4, "Precognition", "passive", {"mods": [{"target": "ac", "add": 2}]}, "You already know where the blow will land."),
    (5, "Fate Thread", "mass_boon", {"status": "focused"}, "The whole party sees the next few seconds."),
    (5, "Doom Sight", "curse", {"status": "exposed", "area": True}, "Shows every enemy's death, and their weak points."),
  ],
  "enchantment": [
    (1, "Daze", "control", {"status": "stunned", "save": "wis"}, "Scrambles the target's thoughts for a moment."),
    (1, "Charm", "control", {"status": "charmed", "save": "wis"}, "Makes an enemy reluctant to hurt you."),
    (2, "Fear", "control", {"status": "frightened", "save": "wis", "area": True}, "A wave of dread."),
    (2, "Inspire", "boon", {"status": "inspired"}, "Fills an ally with confidence."),
    (3, "Slumber", "control", {"status": "stunned", "save": "wis", "area": True}, "Puts a group to sleep, briefly."),
    (3, "Sap Will", "curse", {"status": "weakened"}, "Drains the target's will to fight."),
    (4, "Dominate", "control", {"status": "charmed", "save": "wis", "long": True}, "Takes the fight out of an enemy entirely."),
    (4, "Mind Spike", "bolt", {"type": "psychic"}, "A needle of thought."),
    (5, "Mass Terror", "control", {"status": "frightened", "save": "wis", "area": True, "long": True}, "Panic spreads through the enemy."),
    (5, "Psychic Scream", "blast", {"type": "psychic", "status": "stunned"}, "A shriek inside every skull nearby."),
  ],
  "illusion": [
    (1, "Glare", "control", {"status": "blinded", "save": "con"}, "A flash of false light."),
    (1, "Blur", "self_boon", {"status": "veiled"}, "Your outline wavers."),
    (2, "Phantom Blade", "bolt", {"type": "psychic"}, "A blade that isn't there, and still cuts."),
    (2, "Mirror Images", "self_boon", {"status": "shielded", "long": True}, "Copies of you take the blows."),
    (3, "Veil the Party", "mass_boon", {"status": "veiled"}, "The whole party fades from sight."),
    (3, "Phantasmal Terror", "control", {"status": "frightened", "save": "wis", "damage": True}, "Shows the target what it fears most."),
    (4, "Colour Burst", "blast", {"type": "radiant", "status": "blinded"}, "A blinding explosion of colour."),
    (4, "Vanish", "self_boon", {"status": "veiled", "long": True}, "Gone, for a while."),
    (5, "Waking Nightmare", "dot", {"type": "psychic", "status": "frightened", "big": True}, "The target can't stop seeing it."),
    (5, "Grand Mirage", "control", {"status": "blinded", "save": "wis", "area": True, "long": True}, "Replaces the whole battlefield with a lie."),
  ],
  "necromancy": [
    (1, "Chill Touch", "touch", {"type": "necrotic"}, "A grave-cold hand."),
    (1, "Life Leech", "drain", {"type": "necrotic"}, "Steals a little life to mend your own."),
    (2, "Rot", "dot", {"type": "necrotic", "status": "poisoned"}, "Flesh sickens and sloughs."),
    (2, "Raise Bones", "summon", {"creature": "risen_bones"}, "A skeleton claws its way up to serve."),
    (3, "Wither", "curse", {"status": "weakened", "area": True}, "Saps the strength of everyone nearby."),
    (3, "Vampiric Grasp", "drain", {"type": "necrotic", "big": True}, "Drinks deeply."),
    (4, "Plague Cloud", "blast", {"type": "poison", "status": "poisoned"}, "A cloud of grave-sickness."),
    (4, "Raise Ghoul", "summon", {"creature": "ghoul"}, "A hungry dead thing that obeys, mostly."),
    (5, "Death Knell", "lance", {"type": "necrotic", "big": True}, "Stops a heart."),
    (5, "Barrow Legion", "summon", {"creature": "barrow_wight", "count": 2}, "Calls the old dead out of the barrows."),
  ],
  "transmutation": [
    (1, "Iron Skin", "boon", {"status": "shielded"}, "Skin hard as plate, briefly."),
    (1, "Quicken", "boon", {"status": "hasted"}, "Speeds an ally up."),
    (2, "Mire", "control", {"status": "rooted", "save": "str", "area": True}, "Turns the ground to mud."),
    (2, "Ox Strength", "boon", {"status": "strengthened"}, "The strength of a draught ox."),
    (3, "Quickening Wave", "mass_boon", {"status": "hasted"}, "Speeds the whole party."),
    (3, "Slow", "control", {"status": "slowed", "save": "wis", "area": True}, "Thickens the air around the enemy."),
    (4, "Stone Grip", "control", {"status": "stunned", "save": "con", "long": True}, "Turns the target's limbs briefly to stone."),
    (4, "Rust Touch", "touch", {"type": "acid", "status": "jammed"}, "Corrodes metal at a touch. Machines hate it."),
    (5, "Flesh to Stone", "control", {"status": "stunned", "save": "con", "long": True, "damage": True}, "Petrifies the target."),
    (5, "Shatter", "blast", {"type": "physical", "big": True}, "Makes everything nearby brittle, then breaks it."),
  ],

  "lantern": [
    (1, "Mend Wounds", "heal", {}, "A short prayer that closes wounds."),
    (1, "Lantern Light", "utility", {"effect": "light"}, "A warm light that the dead avoid."),
    (2, "Cleansing Flame", "cleanse", {}, "Burns away poison and curses."),
    (2, "Radiant Rebuke", "bolt", {"type": "radiant"}, "A flash of holy light."),
    (3, "Healing Circle", "mass_heal", {}, "Heals everyone near the priest."),
    (3, "Hearthward", "boon", {"status": "warded"}, "The Mother's protection."),
    (4, "Renewal", "regen", {}, "Wounds keep closing for a while."),
    (4, "Sunburst", "blast", {"type": "radiant", "status": "blinded"}, "A burst of noon-bright light."),
    (5, "Restoration", "heal", {"big": True}, "Mends almost anything."),
    (5, "Mother's Embrace", "mass_heal", {"big": True}, "The Lantern Mother's own warmth."),
  ],
  "harvest": [
    (1, "Entangle", "control", {"status": "rooted", "save": "str", "area": True}, "Roots and creepers grab at feet."),
    (1, "Sower's Blessing", "regen", {}, "Slow, steady healing."),
    (2, "Thornlash", "dot", {"type": "physical", "status": "bleeding"}, "A whip of thorns."),
    (2, "Barkskin", "boon", {"status": "shielded"}, "Skin like oak bark."),
    (3, "Locust Swarm", "blast", {"type": "physical", "status": "blinded"}, "A biting, buzzing cloud."),
    (3, "Bounty", "mass_heal", {}, "The harvest feeds everyone."),
    (4, "Blight", "dot", {"type": "poison", "status": "poisoned", "big": True}, "Withers the living like a failed crop."),
    (4, "Oakheart", "passive", {"mods": [{"target": "hp_max", "add": 10}]}, "Sturdy as an old oak."),
    (5, "Wrath of the Field", "blast", {"type": "physical", "status": "rooted", "big": True}, "The ground itself rises up."),
    (5, "Greenwake", "mass_boon", {"status": "regenerating"}, "Spring comes to the whole party."),
  ],
  "iron_oath": [
    (1, "Bless", "boon", {"status": "blessed"}, "The Oathwarden's favour."),
    (1, "Shield of Faith", "boon", {"status": "shielded"}, "Faith made solid."),
    (2, "Smite", "touch", {"type": "radiant"}, "A holy blow."),
    (2, "Oath of Courage", "passive", {"mods": [{"target": "save:all", "add": 1}]}, "You swore not to run."),
    (3, "Battle Hymn", "mass_boon", {"status": "blessed"}, "A hymn the whole party fights to."),
    (3, "Holy Brand", "dot", {"type": "radiant", "status": "burning"}, "Burns the Oath's mark into an enemy."),
    (4, "Righteous Fury", "self_boon", {"status": "strengthened", "long": True}, "Holy anger."),
    (4, "Sacred Shield", "mass_boon", {"status": "shielded"}, "Shields the faithful."),
    (5, "Judgement", "lance", {"type": "radiant", "big": True}, "The Oathwarden's verdict."),
    (5, "Unbreakable Line", "mass_boon", {"status": "warded", "long": True}, "Nobody gets through."),
  ],
  "grave": [
    (1, "Toll the Dead", "bolt", {"type": "necrotic"}, "A bell only the target hears."),
    (1, "Speak with the Dead", "utility", {"effect": "speak_dead"}, "A corpse answers three questions."),
    (2, "Turn the Dead", "control", {"status": "frightened", "save": "wis", "area": True}, "The dead remember they should be resting."),
    (2, "Last Rites", "heal", {}, "Pulls the dying back from the edge."),
    (3, "Ferryman's Toll", "drain", {"type": "necrotic"}, "The Ferryman takes his fee from your enemy."),
    (3, "Grave Ward", "boon", {"status": "warded"}, "Death looks the other way."),
    (4, "Soul Cage", "control", {"status": "stunned", "save": "wis"}, "Holds the target's soul still."),
    (4, "Pale Lantern", "blast", {"type": "radiant"}, "A cold light that burns the unquiet."),
    (5, "Final Rest", "lance", {"type": "necrotic", "big": True}, "Sends the target to the Ferryman."),
    (5, "Death Ward", "passive", {"mods": [{"flag": "relentless"}]}, "Once per fight, a killing blow leaves you at 1 HP."),
  ],
  "storm": [
    (1, "Gust", "push", {"type": "physical", "tiles": 2}, "A blast of wind."),
    (1, "Shocking Grasp", "touch", {"type": "lightning"}, "Lightning in the palm."),
    (2, "Call Lightning", "bolt", {"type": "lightning"}, "A bolt from a clear sky."),
    (2, "Tailwind", "boon", {"status": "hasted"}, "The wind at an ally's back."),
    (3, "Thunderwave", "blast", {"type": "lightning", "status": "stunned"}, "A wall of thunder."),
    (3, "Squall", "control", {"status": "blinded", "save": "con", "area": True}, "Rain so hard nobody can see."),
    (4, "Storm Lash", "lance", {"type": "lightning"}, "A whip of lightning."),
    (4, "Eye of the Storm", "self_boon", {"status": "warded", "long": True}, "Calm at the centre."),
    (5, "Tempest", "blast", {"type": "lightning", "big": True}, "The full storm."),
    (5, "Gale King's Wrath", "lance", {"type": "lightning", "status": "stunned", "big": True}, "The god's own thunderbolt."),
  ],
  "veil": [
    (1, "Shadow Cloak", "self_boon", {"status": "veiled"}, "The Sister hides you."),
    (1, "Whispered Doubt", "curse", {"status": "frightened"}, "A voice in the ear: you're going to lose."),
    (2, "Luck of the Draw", "boon", {"status": "focused"}, "The dice roll your way."),
    (2, "Smuggler's Prayer", "passive", {"mods": [{"target": "skill:lockpicking", "add": 2}, {"target": "skill:pickpocket", "add": 2}]}, "Locks and pockets open more easily."),
    (3, "Veiled Strike", "touch", {"type": "psychic"}, "A blow nobody sees coming."),
    (3, "Cloak the Party", "mass_boon", {"status": "veiled"}, "Hides the whole party."),
    (4, "Twist Fate", "curse", {"status": "exposed", "long": True}, "The target's luck runs out."),
    (4, "Gambler's Grace", "passive", {"mods": [{"target": "ac", "add": 2}]}, "You're never quite where they aimed."),
    (5, "Mass Confusion", "control", {"status": "charmed", "save": "wis", "area": True}, "Nobody is sure whose side they're on."),
    (5, "Sister's Kiss", "drain", {"type": "psychic", "big": True}, "Takes something the target won't miss until later."),
  ],

  "ballistics": [
    (1, "Aimed Shot", "weapon", {"to_hit": 3, "ap": 1}, "Take your time."),
    (1, "Quick Draw", "passive", {"mods": [{"target": "initiative", "add": 3}]}, "Gun out first."),
    (2, "Leg Shot", "weapon", {"status": "slowed", "ap": 1}, "Slows the target down."),
    (2, "Rapid Fire", "weapon", {"hits": 2, "to_hit": -2, "ap": 2}, "Two shots, fast."),
    (3, "Piercing Round", "weapon", {"to_hit": 2, "extra": "2d6", "ap": 1}, "A hardened round that punches through armour."),
    (3, "Gunslinger", "passive", {"mods": [{"target": "attack:firearms", "add": 1}, {"target": "damage:firearms", "add": 1}]}, "Practice."),
    (4, "Suppressing Fire", "weapon", {"area": 10, "status": "frightened", "ap": 2}, "Keeps heads down."),
    (4, "Deadeye", "passive", {"mods": [{"target": "crit_range", "add": 1}]}, "Crits on 19-20."),
    (5, "Fan the Hammer", "weapon", {"hits": 3, "to_hit": -3, "ap": 3}, "Empties the cylinder."),
    (5, "Killshot", "weapon", {"to_hit": 3, "extra": "6d6", "ap": 3}, "One shot, one kill."),
  ],
  "steamworks": [
    (1, "Scald Jet", "device", {"tpl": "dot", "type": "fire", "status": "burning", "range": 15}, "A jet of boiling steam from a hand pump."),
    (1, "Pressure Gauge", "passive", {"mods": [{"target": "misfire", "add": -0.02}]}, "You watch the needle. Devices misfire 2% less."),
    (2, "Steam Cloud", "device", {"tpl": "control", "status": "blinded", "save": "con", "area": True}, "A scalding white cloud."),
    (2, "Piston Punch", "weapon", {"push": 2, "extra": "1d6", "ap": 1}, "Drives the target back."),
    (3, "Boiler Vent", "device", {"tpl": "blast", "type": "fire"}, "Dumps a boiler's worth of steam."),
    (3, "Iron Plating", "passive", {"mods": [{"target": "ac", "add": 2}]}, "Riveted plates under the coat."),
    (4, "Overpressure", "weapon", {"extra": "4d6", "ap": 2, "misfire": 0.04}, "Past the red line."),
    (4, "Steam Shroud", "self_boon", {"status": "veiled"}, "Wreathed in steam."),
    (5, "Furnace Heart", "passive", {"mods": [{"target": "ap_max", "add": 1}, {"target": "resist:fire", "add": 25}]}, "A pocket boiler that never goes out."),
    (5, "Piston Hammerblow", "weapon", {"extra": "6d6", "status": "stunned", "ap": 3, "misfire": 0.05}, "Everything the boiler has, in one blow."),
  ],
  "galvanics": [
    (1, "Spark Gap", "device", {"tpl": "bolt", "type": "lightning", "range": 40}, "A crackling arc from a hand coil."),
    (1, "Static Coat", "self_boon", {"status": "shielded"}, "A charged field that pushes blows aside."),
    (2, "Shock Baton", "device", {"tpl": "touch", "type": "lightning", "status": "stunned"}, "A charged rod."),
    (2, "Galvanic Stimulus", "heal", {"construct_ok": True}, "A jolt that restarts the heart, or the engine."),
    (3, "Arc Chain", "device", {"tpl": "blast", "type": "lightning"}, "Lightning that jumps between targets."),
    (3, "Capacitor Bank", "passive", {"mods": [{"target": "ap_max", "add": 1}]}, "Stored charge for when you need it."),
    (4, "Coil Cage", "device", {"tpl": "control", "status": "stunned", "save": "con", "area": True}, "A cage of arcs."),
    (4, "Overload", "device", {"tpl": "lance", "type": "lightning"}, "Dumps the whole cell at once."),
    (5, "Storm Engine", "device", {"tpl": "blast", "type": "lightning", "big": True}, "A backpack generator, fully open."),
    (5, "Lightning Rod", "passive", {"mods": [{"target": "resist:lightning", "add": 50}, {"target": "attack:gear", "add": 2}]}, "Grounded."),
  ],
  "optics": [
    (1, "Spotting Scope", "self_boon", {"status": "focused"}, "Sight in and fire."),
    (1, "Flash Lamp", "device", {"tpl": "control", "status": "blinded", "save": "con"}, "Magnesium in the eyes."),
    (2, "Rangefinder", "passive", {"mods": [{"target": "attack:ranged", "add": 1}]}, "You know exactly how far it is."),
    (2, "Mark Target", "curse", {"status": "exposed"}, "A mirror flash shows everyone where to shoot."),
    (3, "Magnesium Flare", "device", {"tpl": "blast", "type": "radiant", "status": "blinded"}, "A blinding white burst."),
    (3, "Assay Lens", "utility", {"effect": "identify"}, "Reads an item's properties through the lens. Can miss curses."),
    (4, "Long Glass", "passive", {"mods": [{"target": "attack:ranged", "add": 2}]}, "A brass telescope sight."),
    (4, "Heliograph Burn", "device", {"tpl": "lance", "type": "fire"}, "Focused sunlight, or lamp light, through a great lens."),
    (5, "Prism Cannon", "device", {"tpl": "lance", "type": "radiant", "big": True}, "A beam of focused light that cuts steel."),
    (5, "Total Clarity", "mass_boon", {"status": "focused"}, "The whole party sees through your lenses."),
  ],
  "demolition": [
    (1, "Powder Bomb", "device", {"tpl": "blast", "type": "fire"}, "Black powder in a tin."),
    (1, "Smoke Pot", "device", {"tpl": "control", "status": "blinded", "save": "con", "area": True}, "Thick choking smoke."),
    (2, "Acid Flask", "device", {"tpl": "dot", "type": "acid", "status": "corroded"}, "Glass, cork, acid."),
    (2, "Caltrops", "device", {"tpl": "control", "status": "slowed", "save": "dex", "area": True}, "Spikes underfoot."),
    (3, "Dynamite Bundle", "device", {"tpl": "blast", "type": "fire", "big": True}, "Three sticks and a short fuse."),
    (3, "Shrapnel Charge", "device", {"tpl": "blast", "type": "physical", "status": "bleeding"}, "Nails and bolts packed round the charge."),
    (4, "Sticky Bomb", "device", {"tpl": "dot", "type": "fire", "status": "burning", "big": True}, "Tar and powder that clings."),
    (4, "Blasting Expert", "passive", {"mods": [{"target": "damage:fire", "add": 2}, {"target": "resist:fire", "add": 25}]}, "You know how to stand."),
    (5, "Demolition Charge", "device", {"tpl": "blast", "type": "fire", "big": True, "radius": 20}, "Brings the building down."),
    (5, "Firestorm Barrage", "device", {"tpl": "blast", "type": "fire", "status": "burning", "big": True}, "A string of incendiaries."),
  ],
  "automata": [
    (1, "Clockwork Beetle", "summon", {"creature": "clockwork_beetle"}, "A wind-up beetle with a nasty bite."),
    (1, "Field Repair", "repair", {}, "Patches up a Wrought or automaton."),
    (2, "Tune-up", "boon", {"status": "steady"}, "Adjusts an ally's devices."),
    (2, "Spring Turret", "summon", {"creature": "spring_turret"}, "A clockwork crossbow on a tripod."),
    (3, "Overclock", "boon", {"status": "hasted"}, "Pushes a machine (or a person) past spec."),
    (3, "Brass Hound", "summon", {"creature": "brass_hound"}, "A steam-driven guard dog."),
    (4, "Iron Bulwark", "summon", {"creature": "iron_bulwark"}, "A walking wall of riveted iron."),
    (4, "Master Mechanic", "passive", {"mods": [{"target": "skill:mechanics", "add": 2}, {"target": "misfire", "add": -0.03}]}, "Nothing you own breaks."),
    (5, "Steam Colossus", "summon", {"creature": "steam_colossus"}, "A war engine twice your height."),
    (5, "Ossuan Override", "control", {"status": "charmed", "save": "int", "long": True}, "Old command codes that some machines still obey."),
  ],

  "blade": [
    (1, "Feint", "weapon", {"to_hit": 3, "ap": 0}, "A false opening."),
    (1, "Bleeding Cut", "weapon", {"status": "bleeding", "ap": 1}, "A cut that won't close."),
    (2, "Riposte", "passive", {"mods": [{"target": "ac", "add": 1}]}, "Parry, then answer."),
    (2, "Twin Cut", "weapon", {"hits": 2, "to_hit": -2, "ap": 2}, "Two quick cuts."),
    (3, "Disarming Strike", "weapon", {"status": "weakened", "ap": 1}, "Knocks the weapon arm aside."),
    (3, "Blade Dancer", "passive", {"mods": [{"target": "attack:blades", "add": 1}, {"target": "ac", "add": 1}]}, "Steel and footwork."),
    (4, "Whirlwind", "weapon", {"cleave": True, "ap": 2}, "Cuts everyone around you."),
    (4, "Vital Strike", "weapon", {"extra": "3d6", "ap": 2}, "Finds the gap in the armour."),
    (5, "Thousand Cuts", "weapon", {"hits": 3, "to_hit": -2, "ap": 3}, "Too fast to follow."),
    (5, "Masterstroke", "weapon", {"to_hit": 4, "extra": "5d6", "ap": 3}, "The perfect cut."),
  ],
  "heavy_arms": [
    (1, "Crushing Blow", "weapon", {"extra": "1d8", "ap": 1}, "Put your weight behind it."),
    (1, "Brace", "self_boon", {"status": "shielded"}, "Plant your feet."),
    (2, "Sweep", "weapon", {"cleave": True, "ap": 2}, "A wide arc."),
    (2, "Knockdown", "weapon", {"status": "stunned", "save": "str", "ap": 2}, "Puts them on the ground."),
    (3, "Sunder", "weapon", {"status": "exposed", "ap": 1}, "Breaks their guard, and their armour."),
    (3, "Iron Grip", "passive", {"mods": [{"target": "damage:melee", "add": 1}]}, "Harder hits."),
    (4, "Earthshaker", "weapon", {"cleave": True, "status": "stunned", "save": "str", "ap": 3}, "Hits the ground hard enough to floor everyone."),
    (4, "Juggernaut", "passive", {"mods": [{"target": "hp_max", "add": 10}]}, "Hard to put down."),
    (5, "Titan's Swing", "weapon", {"cleave": True, "extra": "3d8", "ap": 3}, "Nothing stands in the arc."),
    (5, "Unstoppable", "self_boon", {"status": "warded", "long": True}, "Shrug it off."),
  ],
  "archery": [
    (1, "Aimed Arrow", "weapon", {"to_hit": 3, "ap": 1}, "Draw, breathe, loose."),
    (1, "Pinning Shot", "weapon", {"status": "rooted", "ap": 1}, "Pins a foot or a sleeve."),
    (2, "Double Shot", "weapon", {"hits": 2, "to_hit": -2, "ap": 2}, "Two arrows on the string."),
    (2, "Hawkeye", "passive", {"mods": [{"target": "attack:ranged", "add": 1}]}, "Sharp eyes."),
    (3, "Barbed Arrow", "weapon", {"status": "bleeding", "extra": "1d6", "ap": 1}, "Hard to pull out."),
    (3, "Volley", "weapon", {"area": 10, "ap": 2}, "A rain of arrows."),
    (4, "Heartseeker", "weapon", {"extra": "3d8", "ap": 2}, "Straight to the heart."),
    (4, "Wind Reader", "passive", {"mods": [{"target": "crit_range", "add": 1}]}, "You read the wind."),
    (5, "Arrow Storm", "weapon", {"area": 15, "extra": "2d6", "ap": 3}, "The sky goes dark."),
    (5, "Perfect Shot", "weapon", {"to_hit": 5, "extra": "6d6", "ap": 3}, "Through the eye."),
  ],
  "pugilism": [
    (1, "Haymaker", "weapon", {"extra": "1d6", "ap": 1}, "A big swing."),
    (1, "Iron Fists", "passive", {"mods": [{"target": "damage:melee", "add": 1}]}, "Knuckles like stones."),
    (2, "Headbutt", "weapon", {"status": "stunned", "save": "con", "ap": 1}, "Crude, effective."),
    (2, "Grapple", "weapon", {"status": "rooted", "save": "str", "ap": 1}, "Holds them in place."),
    (3, "Flurry", "weapon", {"hits": 3, "to_hit": -2, "ap": 2}, "A storm of punches."),
    (3, "Thick Skin", "passive", {"mods": [{"target": "hp_max", "add": 5}]}, "You've taken worse."),
    (4, "Gut Punch", "weapon", {"status": "weakened", "extra": "2d6", "ap": 2}, "Knocks the wind out."),
    (4, "Second Wind", "self_heal", {}, "Shake it off and keep going."),
    (5, "Knockout", "weapon", {"status": "stunned", "save": "con", "long": True, "extra": "3d6", "ap": 3}, "Lights out."),
    (5, "Brawler's Rage", "self_boon", {"status": "strengthened", "long": True}, "Red mist."),
  ],
  "skirmish": [
    (1, "Sidestep", "self_boon", {"status": "shielded"}, "Not where they swung."),
    (1, "Light Feet", "passive", {"mods": [{"target": "ac", "add": 1}]}, "Always moving."),
    (2, "Tumble", "self_boon", {"status": "veiled"}, "Roll out of trouble."),
    (2, "Quick Step", "passive", {"mods": [{"target": "initiative", "add": 2}]}, "First to move."),
    (3, "Hit and Fade", "weapon", {"to_hit": 2, "status_self": "shielded", "ap": 1}, "Strike and get clear."),
    (3, "Evasion", "passive", {"mods": [{"target": "save:dex", "add": 3}]}, "Dive clear of blasts."),
    (4, "Blur of Steel", "weapon", {"hits": 2, "ap": 2}, "Two strikes on the move."),
    (4, "Untouchable", "passive", {"mods": [{"target": "ac", "add": 2}]}, "They can't pin you down."),
    (5, "Windrunner", "passive", {"mods": [{"target": "ap_max", "add": 1}]}, "An extra step every round."),
    (5, "Dance of Blades", "weapon", {"cleave": True, "hits": 2, "ap": 3}, "Through the whole crowd and out the other side."),
  ],
  "shadow": [
    (1, "Backstab", "weapon", {"extra": "2d6", "ap": 1}, "Where it hurts."),
    (1, "Poisoned Blade", "weapon", {"status": "poisoned", "ap": 1}, "A smear of something nasty."),
    (2, "Slip Away", "self_boon", {"status": "veiled"}, "Into the shadows."),
    (2, "Throat Strike", "weapon", {"status": "silenced", "ap": 1}, "No more spells, no more shouting."),
    (3, "Blinding Powder", "control", {"status": "blinded", "save": "con"}, "Pepper and lime."),
    (3, "Cold Blood", "passive", {"mods": [{"target": "crit_range", "add": 1}]}, "Crits on 19-20."),
    (4, "Assassinate", "weapon", {"extra": "4d6", "to_hit": 2, "ap": 2}, "One blow."),
    (4, "Venom Master", "passive", {"mods": [{"target": "damage:poison", "add": 2}, {"target": "resist:poison", "add": 50}]}, "Poisons you know by taste."),
    (5, "Death from the Dark", "weapon", {"extra": "7d6", "to_hit": 3, "ap": 3}, "They never see it."),
    (5, "Ghost", "self_boon", {"status": "veiled", "long": True}, "Gone."),
  ],
  "command": [
    (1, "Rally", "mass_boon", {"status": "inspired"}, "On me!"),
    (1, "Shout Down", "control", {"status": "frightened", "save": "wis"}, "A bellow that rattles the enemy."),
    (2, "Field Orders", "boon", {"status": "hasted"}, "Tells an ally exactly where to go."),
    (2, "Tactician", "passive", {"mods": [{"target": "initiative", "add": 3}]}, "You planned for this."),
    (3, "Hold the Line", "mass_boon", {"status": "shielded"}, "Shields up, together."),
    (3, "Focus Fire", "curse", {"status": "exposed"}, "Everyone, that one."),
    (4, "Battle Cry", "control", {"status": "frightened", "save": "wis", "area": True}, "A roar that breaks nerve."),
    (4, "Veteran", "passive", {"mods": [{"target": "save:all", "add": 2}]}, "Seen it all."),
    (5, "Last Stand", "mass_boon", {"status": "warded", "long": True}, "Nobody falls today."),
    (5, "Inspiring Presence", "passive", {"mods": [{"target": "attack", "add": 1}, {"target": "leadership_aura", "add": 1}]}, "People fight better near you."),
  ],
  "fieldcraft": [
    (1, "Bandage", "heal", {"small": True, "nonmagic": True}, "Clean linen and a steady hand."),
    (1, "Snare", "control", {"status": "rooted", "save": "dex"}, "A quick noose in the grass."),
    (2, "Herbal Poultice", "regen", {"nonmagic": True}, "Moss, honey and yarrow."),
    (2, "Tracker", "passive", {"mods": [{"target": "skill:survival", "add": 2}, {"target": "skill:perception", "add": 1}]}, "Reads the ground."),
    (3, "Splint and Salve", "cleanse", {"nonmagic": True}, "Treats poison and wounds."),
    (3, "Hunter's Mark", "curse", {"status": "exposed"}, "You know where to aim."),
    (4, "Field Surgeon", "heal", {"big": True, "nonmagic": True}, "Saws, needles and nerve."),
    (4, "Weathered", "passive", {"mods": [{"target": "resist:cold", "add": 25}, {"target": "hp_max", "add": 5}]}, "Cold doesn't bother you."),
    (5, "Bear Trap", "control", {"status": "rooted", "save": "dex", "long": True, "damage": True}, "Iron jaws."),
    (5, "Iron Constitution", "passive", {"mods": [{"target": "resist:poison", "add": 50}, {"target": "save:con", "add": 2}]}, "Nothing makes you sick."),
  ],
}

# ----------------------------------------------------------------- summons
# creature: (name, tier, archetype, natural weapon, color, pool)
CREATURES = {
  "familiar": ("Familiar", 1, "beast", {"name": "Bite", "damage": "1d4", "ap": 2, "range": 5}, "#9fe0c0", "arcane"),
  "spectral_hound": ("Spectral Hound", 2, "beast", {"name": "Bite", "damage": "1d8", "ap": 3, "range": 5}, "#9fe0c0", "arcane"),
  "ember_spirit": ("Ember Spirit", 3, "beast", {"name": "Burning Touch", "damage": "2d6", "ap": 3, "range": 5}, "#ff8a3d", "arcane"),
  "meltwater_spirit": ("Meltwater Spirit", 4, "beast", {"name": "Crushing Wave", "damage": "2d8", "ap": 3, "range": 10}, "#7fb2ff", "arcane"),
  "gate_beast": ("Gate Beast", 5, "beast", {"name": "Rending Claws", "damage": "3d8", "ap": 3, "range": 5}, "#6a4a8a", "arcane"),
  "risen_bones": ("Risen Bones", 2, "thug", {"name": "Rusted Blade", "damage": "1d8", "ap": 3, "range": 5}, "#d8d0b8", "arcane"),
  "ghoul": ("Ghoul", 4, "beast", {"name": "Claws", "damage": "2d6", "ap": 3, "range": 5}, "#8a9a7a", "arcane"),
  "barrow_wight": ("Barrow Wight", 5, "soldier", {"name": "Barrow Blade", "damage": "2d8", "ap": 3, "range": 5}, "#a8a8c8", "arcane"),
  "clockwork_beetle": ("Clockwork Beetle", 1, "construct", {"name": "Mandibles", "damage": "1d6", "ap": 3, "range": 5}, "#c79a4a", "gear"),
  "spring_turret": ("Spring Turret", 2, "construct", {"name": "Spring Bolt", "damage": "1d10", "ap": 3, "range": 60, "ranged": True}, "#c79a4a", "gear"),
  "brass_hound": ("Brass Hound", 3, "construct", {"name": "Steel Jaws", "damage": "2d6", "ap": 3, "range": 5}, "#d0a060", "gear"),
  "iron_bulwark": ("Iron Bulwark", 4, "construct", {"name": "Iron Fist", "damage": "2d8", "ap": 3, "range": 5}, "#8a8a8a", "gear"),
  "steam_colossus": ("Steam Colossus", 5, "construct", {"name": "Piston Arm", "damage": "3d10", "ap": 4, "range": 10}, "#b0b0a0", "gear"),
}

# ----------------------------------------------------------------- numbers

def dur(tier, long=False):
    return 2 + tier // 2 + (2 if long else 0)

def ctrl_dur(tier, status, long=False):
    base = 1 if status in ("stunned", "charmed") else 1 + (tier + 1) // 2
    return base + (1 if long else 0)

def dice(n, sides, bonus=0):
    return f"{n}d{sides}" + (f"+{bonus}" if bonus else "")

def radius(tier, big=False, override=None):
    if override:
        return override
    return 10 + (5 if tier >= 3 else 0) + (5 if big else 0)

def ap_for(base, tier):
    return base + (1 if tier >= 4 else 0)


# Which weapon skill a discipline's weapon techniques need (default: the discipline's skill).
WEAPON_SKILL = {"ballistics": ["firearms"], "steamworks": ["heavy_gear"]}


def build(disc_id, tier, name, tpl, p, flavour):
    d = DISC[disc_id]
    pool = d["pool"]
    school = d["school"]
    a = {
        "name": name, "discipline": disc_id, "tier": tier, "pool": pool, "school": school,
        "stat": d["stat"], "color": d.get("color", "#ffffff"), "template": tpl,
    }
    big = p.get("big", False)
    long = p.get("long", False)
    real_tpl = tpl
    if tpl == "device":
        real_tpl = p["tpl"]
        a["device"] = True
        a["misfire"] = 0.03 + 0.01 * tier
    t = real_tpl
    if t in ("bolt", "lance", "touch", "dot", "blast", "drain", "push"):
        a["kind"] = "attack"
        a["target"] = "enemy"
        a["damage_type"] = p["type"]
        if t == "bolt":
            a.update(ap=ap_for(4, tier), range=p.get("range", 60), damage=dice(tier + 1, 6))
        elif t == "lance":
            n = tier + 2 + (1 if big else 0)
            a.update(ap=ap_for(5, tier), range=p.get("range", 40), damage=dice(n, 6, tier if big else 0))
        elif t == "touch":
            a.update(ap=3, range=5, damage=dice(tier + 1 + (1 if big else 0), 8))
        elif t == "dot":
            a.update(ap=ap_for(4, tier), range=p.get("range", 50), damage=dice(tier + (1 if big else 0), 6))
        elif t == "blast":
            a.update(ap=ap_for(5, tier), range=p.get("range", 60), area=radius(tier, big, p.get("radius")),
                     damage=dice(tier + (1 if big else 0), 6, tier if big else 0))
        elif t == "drain":
            a.update(ap=ap_for(4, tier), range=30, damage=dice(tier + (2 if big else 1), 6), drain=0.5)
        elif t == "push":
            a.update(ap=4, range=30, damage=dice(tier, 6), push=p.get("tiles", 2))
        if p.get("hits"):
            a["chain"] = p["hits"] - 1
        if p.get("status"):
            st = p["status"]
            a["effects"] = [{"type": "status", "status": st,
                             "duration": ctrl_dur(tier, st) if st in ("stunned", "charmed", "rooted") else dur(tier, long),
                             "chance": 1.0 if t in ("dot", "lance", "touch") else 0.5}]
        a["save"] = {"stat": "dex", "half": True} if t == "blast" else None
        if a["save"] is None:
            del a["save"]
    elif t in ("control", "curse"):
        st = p["status"]
        a["kind"] = "control" if t == "control" else "curse"
        a["target"] = "enemy"
        a.update(ap=ap_for(4, tier), range=p.get("range", 40))
        if p.get("area"):
            a["area"] = radius(tier, big)
        if t == "control":
            a["save"] = {"stat": p.get("save", "wis")}
            a["effects"] = [{"type": "status", "status": st, "duration": ctrl_dur(tier, st, long)}]
        else:
            a["effects"] = [{"type": "status", "status": st, "duration": dur(tier, long)}]
            a["save"] = {"stat": "wis"}
        if p.get("damage"):
            a["damage"] = dice(tier, 6)
            a["damage_type"] = "force" if pool != "gear" else "physical"
    elif t in ("boon", "self_boon", "mass_boon", "regen"):
        a["kind"] = "boon"
        st = "regenerating" if t == "regen" else p["status"]
        a["target"] = "self" if t == "self_boon" else "ally"
        a["ap"] = 2 if t == "self_boon" else 3
        a["range"] = 0 if t == "self_boon" else 30
        if t == "mass_boon":
            a["ap"] = ap_for(4, tier)
            a["area"] = 20
            a["target"] = "allies"
        a["effects"] = [{"type": "status", "status": st, "duration": dur(tier, long) + (1 if t == "regen" else 0)}]
    elif t in ("heal", "mass_heal", "self_heal", "repair"):
        a["kind"] = "heal"
        a["target"] = {"heal": "ally", "mass_heal": "allies", "self_heal": "self", "repair": "ally"}[t]
        if t == "heal":
            n = tier + 1 + (2 if big else 0) - (1 if p.get("small") else 0)
            a.update(ap=4, range=30, heal=dice(max(1, n), 6, tier if big else 0))
        elif t == "mass_heal":
            a.update(ap=ap_for(5, tier), range=0, area=20, heal=dice(tier + (2 if big else 0), 6))
        elif t == "self_heal":
            a.update(ap=2, range=0, heal=dice(tier + 1, 8))
        elif t == "repair":
            a.update(ap=4, range=5, heal=dice(tier + 2, 6), construct_only=True)
        if p.get("construct_ok"):
            a["construct_ok"] = True
    elif t == "cleanse":
        a.update(kind="cleanse", target="ally", ap=3, range=30, heal=dice(tier, 4))
        a["effects"] = [{"type": "cleanse", "kind": "harm"}]
    elif t == "summon":
        c = p["creature"]
        a.update(kind="summon", target="tile", ap=6, range=20, summon=c, count=p.get("count", 1),
                 duration=4 + tier)
    elif t == "passive":
        a.update(kind="passive", target="self", ap=0, modifiers=p["mods"])
    elif t == "utility":
        a.update(kind="utility", target="self", ap=4, range=0, effect=p["effect"])
    elif t == "weapon":
        a["kind"] = "weapon"
        a["target"] = "enemy"
        a["weapon_skill"] = WEAPON_SKILL.get(disc_id) or (d["skill"] if isinstance(d["skill"], list) else [d["skill"]])
        if disc_id in ("skirmish", "shadow", "command", "fieldcraft"):
            a["weapon_skill"] = []  # any weapon
        a["ap_delta"] = p.get("ap", 0)
        for k_src, k_dst in (("to_hit", "to_hit"), ("extra", "extra_damage"), ("hits", "hits"),
                             ("area", "area"), ("cleave", "cleave"), ("push", "push"), ("misfire", "misfire_add"),
                             ("status_self", "self_status")):
            if k_src in p:
                a[k_dst] = p[k_src]
        if "status" in p:
            st = p["status"]
            eff = {"type": "status", "status": st,
                   "duration": ctrl_dur(tier, st, long) if st in ("stunned", "charmed", "rooted") else dur(tier, long)}
            if "save" in p:
                a["save"] = {"stat": p["save"]}
            a["effects"] = [eff]
        if pool == "neutral":
            a["school"] = "neutral"
    else:
        raise ValueError(f"unknown template {tpl}")
    if p.get("nonmagic"):
        a["school"] = "neutral"
        a["nonmagic"] = True
    a["desc"] = flavour
    return a


def slug(name):
    return re.sub(r"[^a-z0-9]+", "_", name.lower().replace("'", "")).strip("_")


def main():
    out = {}
    for disc_id, rows in ROWS.items():
        assert disc_id in DISC, disc_id
        assert len(rows) == 10, (disc_id, len(rows))
        for tier, name, tpl, p, flavour in rows:
            aid = slug(name)
            if aid in out:
                aid = f"{disc_id}_{aid}"
            assert aid not in out, aid
            out[aid] = build(disc_id, tier, name, tpl, p, flavour)
    summons = {}
    for cid, (name, tier, arch, weapon, color, pool) in CREATURES.items():
        w = dict(weapon)
        w.update(type="weapon", pool=pool)
        summons[cid] = {
            "name": name, "faction": "ally", "color": color, "summoned": True, "grade": "minion",
            "gen": {"archetype": arch, "level": tier * 3, "race": "", "seed": tier * 7919},
            "natural_weapon": w,
        }
    for a in out.values():
        if a.get("kind") == "summon":
            assert a["summon"] in summons, a["summon"]
    (ROOT / "data/character/abilities.json").write_text(json.dumps(out, indent=1) + "\n")
    (ROOT / "data/character/summons.json").write_text(json.dumps(summons, indent=1) + "\n")
    kinds = {}
    for a in out.values():
        kinds[a["kind"]] = kinds.get(a["kind"], 0) + 1
    print(f"{len(out)} abilities, {len(summons)} summons", kinds)


if __name__ == "__main__":
    main()
