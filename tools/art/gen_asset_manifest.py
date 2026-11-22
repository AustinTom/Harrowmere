#!/usr/bin/env python3
"""Generates data/art/asset_manifest.csv: every model, kit piece, animation set
and texture Harrowmere needs, by priority tier.

Edit the tables below and re-run:  python3 tools/art/gen_asset_manifest.py
The CSV is the source the art pipeline binds from; docs/asset_list.md is the
human summary (its numbers come from `--summary`).

Ids follow the art pipeline rules (docs/art_pipeline.md): lowercase snake_case,
no category prefix, and the same id as the game data wherever one exists, so a
.glb dropped at `path` replaces the placeholder with no registry entry.

Tiers
  0  prototype swap   what is on screen in the prototype today (Fennick's Landing)
  1  first slice      the Meltlands corner: 1 city district + 2 towns + road + camp,
                      ~10 weapons per pool, a small ruin, a cave
  2  core world       every region playable with its common people, buildings,
                      creatures, item families and dungeon kits
  3  full content     rarer item families, bosses, city landmarks, wrecks
  4  signature/polish uniques, companions' unique looks, cosmetic variants
"""
import csv
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "data" / "art" / "asset_manifest.csv"

COLUMNS = [
    "id", "tier", "category", "subcategory", "kind", "name", "path", "binds_to",
    "shared_base", "count", "covers_items", "rig", "tri_budget", "texture",
    "maps", "placeholder", "status", "notes",
]

rows = []
_ids = set()


def add(id, tier, category, subcategory, kind, name, path, binds_to="",
        shared_base="", count=1, covers_items=0, rig="", tri_budget="",
        texture="palette_main", maps="", placeholder="generated primitive",
        notes=""):
    if id in _ids:
        raise SystemExit(f"duplicate id: {id}")
    _ids.add(id)
    rows.append(dict(
        id=id, tier=tier, category=category, subcategory=subcategory, kind=kind,
        name=name, path=path, binds_to=binds_to, shared_base=shared_base,
        count=count, covers_items=covers_items, rig=rig, tri_budget=tri_budget,
        texture=texture, maps=maps, placeholder=placeholder,
        status="placeholder", notes=notes,
    ))


def nice(s):
    return s.replace("_", " ").capitalize()


# =============================================================================
# 0. Shared textures and materials (made first: everything else points at them)
# =============================================================================
SHARED_TEX = [
    # id, tier, name, maps, notes
    ("palette_main", 0, "Main colour palette atlas (256x256)", "albedo",
     "Flat-colour swatch atlas for low-poly props, items and clothes. UV islands sit on swatches, so one texture covers most of the game. Recolour variants = swap the atlas, not the mesh."),
    ("palette_metal", 0, "Metal palette with roughness/metal (256x256)", "albedo,orm",
     "Iron, steel, bronze, brass, copper, blackened, silver, gold, Ossuan glass-steel swatches. Item material variants are a swatch swap."),
    ("palette_skin_hair", 1, "Skin, eye and hair swatches per race", "albedo",
     "Rows per race. Generated residents pick a swatch, so no per-resident textures."),
    ("palette_faction", 2, "Faction and guild colour swatches", "albedo",
     "Combine soot-black/brass, Spire Compact white/blue, Meridian grey/gold, minor factions. Uniforms recolour from this."),
    ("palette_resonance_lush", 1, "Lush variant of palette_main for high Resonance", "albedo",
     "Optional: shader lerps palette_main toward this by local Resonance, matching the prototype's ground tint."),
    ("palette_resonance_dead", 1, "Sooted variant of palette_main for low Resonance", "albedo",
     "Desaturated, soot-darkened swatches for factory quarters."),
    ("trim_wood", 1, "Wood trim sheet (1024)", "albedo,normal,orm", "Planks, beams, shingles, carved trim strips."),
    ("trim_stone_brick", 1, "Stone and brick trim sheet (1024)", "albedo,normal,orm", "Brick, ashlar, rubble, cornices, sills."),
    ("trim_metal_industrial", 1, "Industrial metal trim sheet (1024)", "albedo,normal,orm", "Riveted plate, pipes, grilles, corrugated sheet."),
    ("trim_cloth_leather", 1, "Cloth and leather trim sheet (1024)", "albedo,normal,orm", "Stitching, straps, buckles, folds for clothes and armour."),
    ("trim_ossuan", 2, "Ossuan ruin trim sheet (1024)", "albedo,normal,orm,emission", "Glass-steel, carved glyph bands, frost-etched stone. Emission for glowing glyphs."),
    ("trim_firstfolk", 2, "Firstfolk barrow trim sheet (1024)", "albedo,normal,orm", "Rough-carved standing stone, spiral reliefs, turf."),
    ("trim_temple", 2, "Temple and tower trim sheet (1024)", "albedo,normal,orm", "Marble, gilded mouldings, painted panels for Spiremarch temples."),
    ("decal_soot", 1, "Soot and grime decals", "albedo", "Low-Resonance / industrial overlay."),
    ("decal_moss_frost", 1, "Moss and frost decals", "albedo", "Thawed-land overlay; frost for the Shelf."),
    ("decal_damage", 2, "Cracks, scorch, bullet and claw marks", "albedo,normal", "Ruins and battle sites."),
    ("decal_glyphs", 1, "Arcane glyph and holy sigil decals", "albedo,emission", "Enchanted items share this: an enchanted item = base mesh + glyph decal + glow, no new model."),
    ("decal_posters_signs", 2, "Posters, notices, shop signs", "albedo", "Combine recruitment posters, wanted notices, shop sign blanks. Text generated."),
    ("book_covers_atlas", 2, "Book cover and spine atlas (2048)", "albedo",
     "~60 cover designs on one atlas. 1,000 lore books reuse 6 book meshes and pick a cover swatch."),
    ("vfx_smoke_steam", 1, "Smoke, steam and soot flipbook", "albedo", "Chimneys, boilers, steam weapons."),
    ("vfx_fire_spark", 1, "Fire, ember, muzzle flash and spark flipbook", "albedo,emission", "Guns, forges, fire spells."),
    ("vfx_magic", 1, "Arcane bolt, glyph circle and frost flipbook", "albedo,emission", "Spells and Resonance shimmer."),
    ("vfx_divine", 2, "Holy light, halo and blessing flipbook", "albedo,emission", "Prayers."),
    ("vfx_galvanic", 2, "Lightning arc and coil glow flipbook", "albedo,emission", "Galvanic tech."),
    ("vfx_water_ice", 2, "Splash, ripple, ice shard and snow flipbook", "albedo", "Drowned Vale and the Shelf."),
    ("selection_rings", 0, "Selection ring, target and AoE decals", "albedo", "UI markers drawn on the ground in combat."),
]
for id, tier, name, maps, notes in SHARED_TEX:
    kind = "decal" if id.startswith("decal") else ("vfx" if id.startswith(("vfx", "selection")) else "texture")
    add(id, tier, "textures", "shared", kind, name, f"assets/textures/{id}.png",
        texture="", maps=maps, placeholder="flat colours in code", notes=notes)

# Terrain: tileable ground materials
TERRAIN = [
    # id, tier, region, notes
    ("meltlands_grass", 0, "meltlands", "Prototype ground. Lush/dead blend by Resonance."),
    ("meltlands_mud", 0, "meltlands", "Wet thawed mud."),
    ("dirt_path", 0, "shared", "Roads and town paths."),
    ("yard_gravel_coal", 0, "shared", "Pumphouse yard: gravel with coal dust."),
    ("shrine_green", 0, "shared", "Bright, flowered grass for high-Resonance spots."),
    ("frozen_ground", 0, "shared", "Out-of-bounds frozen ground around maps."),
    ("farmland_furrows", 1, "meltlands", "Ploughed fields."),
    ("cobblestone", 1, "shared", "Town squares and city streets."),
    ("plank_boardwalk", 1, "shared", "Boardwalks, docks, stilt-town decks."),
    ("marsh_reeds_ground", 1, "meltlands", "Fen edges."),
    ("shallow_water", 1, "shared", "Animated: fords, puddles, flooded streets."),
    ("brick_paving", 2, "old_shires", "City streets in Aldermoot and Brannock."),
    ("canal_stone", 2, "old_shires", "Canal walls and towpaths."),
    ("shires_meadow", 2, "old_shires", "Old settled grassland."),
    ("slag_ash", 2, "furnace_coast", "Foundry waste ground."),
    ("black_shingle_beach", 2, "furnace_coast", "Cold coal-streaked beach."),
    ("coal_seam_rock", 2, "furnace_coast", "Mine floors and open cuts."),
    ("mountain_rock", 2, "spiremarch", "Bare rock slopes."),
    ("alpine_turf", 2, "spiremarch", "High pasture."),
    ("temple_flagstone", 2, "spiremarch", "Temple courtyards."),
    ("snow", 2, "shelf", "Fresh snow."),
    ("glacier_ice", 2, "shelf", "Blue ice with cracks; emissive veins optional."),
    ("tundra_moss", 2, "shelf", "Newly exposed ground at the ice edge."),
    ("silt_mudflat", 2, "drowned_vale", "Exposed flood silt."),
    ("deep_water", 2, "drowned_vale", "Animated, darker; diving areas."),
    ("ossuan_floor_tiles", 2, "ruins", "Glass-steel tiled floor for Ossuan ruins."),
    ("cave_rock_floor", 1, "dungeons", "Cave and cavern floor."),
    ("cave_ice_floor", 2, "dungeons", "Ice caves."),
    ("barrow_earth_floor", 2, "dungeons", "Firstfolk barrows."),
    ("sewer_stone", 3, "dungeons", "City undercroft and sewers."),
    ("mine_timbered_floor", 2, "dungeons", "Mine galleries."),
    ("battlefield_churned", 3, "shared", "Old battlefields landmark."),
    ("hot_spring_crust", 3, "shared", "Mineral crust around geysers."),
]
TERRAIN_BINDS = {
    "meltlands_grass": "area ground default (fennicks_landing)",
    "shrine_green": "location shrine_green",
    "yard_gravel_coal": "location pumphouse_yard",
    "frozen_ground": "out-of-bounds plane",
}
for id, tier, region, notes in TERRAIN:
    add(id, tier, "terrain", region, "texture", nice(id) + " ground (tileable 1024)",
        f"assets/textures/terrain/{id}.png", binds_to=TERRAIN_BINDS.get(id, f"terrain material {id}"),
        texture="", maps="albedo,normal,orm", placeholder="flat tint in World._build_ground()",
        notes=notes)

# =============================================================================
# 1. Animation sets (one clip library per skeleton)
# =============================================================================
BASE_CLIPS = "idle,walk,run,attack_melee,attack_ranged,cast,hit,death,talk"
HUMANOID_EXTRA = ("attack_melee_2h,attack_thrust,attack_bow,attack_gun,reload,throw,block,dodge,"
                  "pray,channel,use_item,drink,pick_up,lockpick,crouch_walk,sit,sleep,carry,"
                  "work_hammer,work_dig,work_farm,work_counter,cheer,cower,swim,climb")
RIGS = [
    ("humanoid", 0, "Humans, elves, Wrought", BASE_CLIPS + "," + HUMANOID_EXTRA),
    ("humanoid_short", 0, "Dwarves", BASE_CLIPS + "," + HUMANOID_EXTRA),
    ("humanoid_small", 0, "Halflings, gnomes", BASE_CLIPS + "," + HUMANOID_EXTRA),
    ("humanoid_large", 1, "Orcs, golems, large guardians", BASE_CLIPS + "," + HUMANOID_EXTRA),
    ("quadruped_canine", 1, "Dogs, wolves, foxes, clockwork hounds", BASE_CLIPS + ",bite,pounce,howl,sleep"),
    ("quadruped_ungulate", 1, "Horses, mules, oxen, elk, goats, sheep", BASE_CLIPS + ",graze,kick,rear,pull_cart"),
    ("quadruped_heavy", 2, "Bears, boars, mammoths, trolls on all fours", BASE_CLIPS + ",maul,charge,roar"),
    ("small_critter", 1, "Rats, cats, chickens, frogs (ambient)", "idle,walk,run,attack_melee,hit,death,peck_sniff"),
    ("bird", 2, "Crows, gulls, eagles", "idle,walk,fly,glide,take_off,land,attack_melee,hit,death"),
    ("arachnid", 2, "Spiders, crabs, Ossuan crawlers", BASE_CLIPS + ",leap,web_or_spark"),
    ("serpent", 2, "Eels, worms, wyrms", BASE_CLIPS + ",coil,burrow,emerge"),
    ("winged_large", 3, "Drakes, wyverns, great eagles", BASE_CLIPS + ",fly,glide,breath,land,take_off"),
    ("floating", 2, "Wisps, drones, spirits (no legs)", "idle,move,attack_ranged,cast,hit,death"),
]
for rig, tier, users, clips in RIGS:
    add(f"anim_{rig}", tier, "animations", rig, "anim_set", f"{nice(rig)} clip library",
        f"assets/animations/{rig}/{rig}.glb", binds_to=f"rig {rig}",
        rig=rig, texture="", placeholder="tweened primitives in Actor",
        notes=f"Used by {users}. Clips: {clips}. Pipeline-required names: {BASE_CLIPS}.")
add("skeleton_humanoid_master", 0, "animations", "humanoid", "rig", "Master humanoid skeleton + weapon sockets",
    "assets/animations/humanoid/humanoid_skeleton.glb", rig="humanoid", texture="",
    placeholder="none", notes="Bones plus sockets: hand_r, hand_l, back, hip_l, hip_r, head. "
    "humanoid_short/_small/_large are this skeleton re-proportioned so clips retarget and every item/armour fits every race.")

# =============================================================================
# 2. Characters: race bodies, heads, hair, clothing kit, prototype actors
# =============================================================================
RACES = [
    # race, rig, tier, heads per sex, notes
    ("human", "humanoid", 0, 6, "Lowlander and Godtouched heritages share the body; Godtouched add god-mark decal + eye glow."),
    ("elf", "humanoid", 0, 4, "The Tideless. Slimmer proportions via shape key, long ears on head meshes."),
    ("dwarf", "humanoid_short", 0, 4, "Broad, short. Beards from the shared beard kit."),
    ("halfling", "humanoid_small", 0, 4, "Small farming folk; bare feet option."),
    ("gnome", "humanoid_small", 1, 4, "Same small body as halflings with a gnome shape key; big-nosed heads."),
    ("orc", "humanoid_large", 1, 4, "Large body, tusked heads; green-grey skin swatches."),
]
for race, rig, tier, heads, notes in RACES:
    add(race, tier, "characters", "race_default", "model", f"{race.capitalize()} default resident",
        f"assets/characters/races/{race}.glb", binds_to=f"race {race} (data/models.json race_defaults)",
        rig=rig, tri_budget="3000-5000", texture="palette_main,palette_skin_hair",
        placeholder="capsule + sphere in Actor._build_visual()",
        notes="Assembled from the body, head, hair and outfit kit rows below. " + notes)
    for sex in ("male", "female"):
        add(f"{race}_{sex}_body", tier, "characters", "body_kit", "kit_piece", f"{race.capitalize()} {sex} base body",
            f"assets/kits/characters/{race}_{sex}_body.glb", shared_base=f"skeleton_humanoid_master",
            rig=rig, tri_budget="2000", texture="palette_skin_hair",
            notes="Underwear-level body, split at neck/wrists/ankles so clothing hides seams. Shape keys: thin, heavy, old, muscular.")
        add(f"{race}_{sex}_head_*", max(tier, 1), "characters", "head_kit", "kit_piece",
            f"{race.capitalize()} {sex} heads ({heads})", f"assets/kits/characters/{race}_{sex}_head_NN.glb",
            count=heads, rig=rig, tri_budget="600", texture="palette_skin_hair",
            notes="Faces vary by shape keys (jaw, nose, brow, age) so heads x keys x swatches = thousands of residents. Tier 0 needs 1 per sex.")
    # resident variants named per the pipeline (human_a, human_b ...)
    add(f"{race}_variants_*", 2, "characters", "race_default", "model",
        f"{race.capitalize()} prebuilt resident variants (a-h)", f"assets/characters/races/{race}_<a-h>.glb",
        binds_to=f"race_defaults.{race}", count=8, rig=rig, tri_budget="3000-5000",
        texture="palette_main,palette_skin_hair", shared_base=race,
        notes="Optional until runtime assembly from kit parts exists: pre-baked mixes the pipeline can pick from randomly.")

# Wrought (automaton race): own chassis kit
add("wrought", 2, "characters", "race_default", "model", "Wrought default (Ossuan automaton)",
    "assets/characters/races/wrought.glb", binds_to="race wrought", rig="humanoid", tri_budget="4000",
    texture="palette_metal,trim_ossuan", placeholder="capsule", notes="Playable original race. Mechanical: no clothing kit, uses its own plating set.")
add("wrought_chassis_*", 2, "characters", "body_kit", "kit_piece", "Wrought chassis variants (3)",
    "assets/kits/characters/wrought_chassis_NN.glb", count=3, rig="humanoid", tri_budget="3000",
    texture="palette_metal,trim_ossuan", notes="Sentinel, labourer, scholar frames. Plates swap per upgrade schematic.")
add("wrought_head_*", 2, "characters", "head_kit", "kit_piece", "Wrought faceplates (6)",
    "assets/kits/characters/wrought_head_NN.glb", count=6, rig="humanoid", tri_budget="500",
    texture="palette_metal,trim_ossuan", notes="Emissive eye slots.")
add("wrought_upgrade_parts_*", 3, "characters", "body_kit", "kit_piece", "Wrought upgrade plating (12)",
    "assets/kits/characters/wrought_upgrade_NN.glb", count=12, rig="humanoid", tri_budget="400",
    texture="palette_metal", notes="Visible upgrades from schematics: armour plates, boiler back, galvanic coils, extra optics.")

add("hair_*", 1, "characters", "hair_kit", "kit_piece", "Hair styles (16)", "assets/kits/characters/hair_NN.glb",
    count=16, rig="humanoid", tri_budget="300-800", texture="palette_skin_hair",
    notes="Shared by all organic races; scaled per head socket. Tier 1 needs 6.")
add("beard_*", 1, "characters", "hair_kit", "kit_piece", "Beards and moustaches (10)", "assets/kits/characters/beard_NN.glb",
    count=10, rig="humanoid", tri_budget="200-600", texture="palette_skin_hair", notes="Dwarves use the long ones.")

# Civilian clothing kit: shared across races, recoloured by palette for region/class
CLOTHES = [
    # id, tier, name, notes
    ("shirt_tunic", 1, "Shirt / tunic", ""),
    ("shirt_rolled_sleeves", 1, "Work shirt, rolled sleeves", "Labourers, smiths."),
    ("vest_waistcoat", 1, "Waistcoat", ""),
    ("coat_long", 1, "Long coat", "Merchants, travellers, the player."),
    ("coat_frock", 2, "Frock coat", "City gentry."),
    ("coat_oilskin", 1, "Oilskin coat", "Meltlands rain gear."),
    ("coat_fur_parka", 2, "Fur parka", "Shelf."),
    ("jacket_work", 1, "Work jacket", "Coal haulers, dockers."),
    ("robe_simple", 1, "Simple robe", "Shrine keepers, hedge mages."),
    ("dress_work", 1, "Work dress", ""),
    ("dress_fine", 2, "Fine dress", ""),
    ("skirt_layered", 2, "Layered skirt", ""),
    ("trousers", 1, "Trousers", ""),
    ("trousers_breeches", 2, "Breeches", ""),
    ("overalls", 1, "Overalls / dungarees", "Factory and farm."),
    ("apron_leather", 1, "Leather apron", "Smiths, butchers, engineers."),
    ("apron_cloth", 1, "Cloth apron", "Cooks, shopkeepers."),
    ("shawl_cloak", 1, "Shawl / short cloak", ""),
    ("boots_work", 1, "Work boots", ""),
    ("boots_tall", 2, "Tall riding boots", ""),
    ("shoes", 1, "Shoes / clogs", ""),
    ("hat_flat_cap", 1, "Flat cap", ""),
    ("hat_wide_brim", 1, "Wide-brim hat", "Farmers, Freeholders."),
    ("hat_top", 2, "Top hat", "Combine managers, city gentry."),
    ("hat_bowler", 2, "Bowler", "Clerks, Assay Office."),
    ("hat_hood", 1, "Hood", ""),
    ("hat_fur", 2, "Fur hat", "Shelf."),
    ("gloves_work", 1, "Work gloves", ""),
    ("scarf_mask", 2, "Scarf / soot mask", "Furnace Coast smog."),
    ("goggles_brass", 1, "Brass goggles (head/neck)", "Engineers; also an item."),
    ("bag_satchel", 1, "Satchel", ""),
    ("backpack_porter", 2, "Porter's pack frame", "Hireling porters (carry more)."),
    ("belt_pouches", 1, "Belt with pouches", ""),
    ("spectacles", 2, "Spectacles", "Scholars, clerks."),
    ("jewellery_set", 3, "Earrings, necklaces, brooches", "Wealth cue for generated residents."),
]
for id, tier, name, notes in CLOTHES:
    add(id, tier, "characters", "clothing_kit", "kit_piece", name, f"assets/kits/characters/clothing/{id}.glb",
        rig="humanoid", tri_budget="300-1200", texture="palette_main,trim_cloth_leather",
        notes=("Skinned to the master skeleton with fit shape keys for short/small/large bodies. Recolours by region and class from the palette. " + notes).strip())

UNIFORMS = [
    ("uniform_combine_rifleman", 2, "Combine rifleman"), ("uniform_combine_foreman", 2, "Combine foreman"),
    ("uniform_combine_railguard", 2, "Combine rail guard"), ("uniform_compact_battlemage", 2, "Compact battlemage"),
    ("uniform_compact_templeguard", 2, "Compact temple guard"), ("uniform_compact_priest", 2, "Compact high-temple priest"),
    ("uniform_meridian_warden", 2, "Meridian warden"), ("uniform_meridian_envoy", 3, "Meridian envoy"),
    ("uniform_assay_clerk", 2, "Assay Office clerk"), ("uniform_constable", 1, "Town constable / warden"),
    ("uniform_freeholder_militia", 2, "Freeholders' League militia"), ("uniform_tideless_keeper", 2, "Tideless memory keeper"),
    ("uniform_engineers_guild", 3, "Engineers' Guild"), ("uniform_enchanters_circle", 3, "Enchanters' Circle"),
    ("uniform_smugglers", 3, "Smugglers' ring"), ("uniform_merchant_house", 3, "Merchant house livery"),
    ("uniform_union_orc", 2, "Furnace Coast union (orc cut)"), ("uniform_hearthfolk", 2, "Hearthfolk shrine keeper"),
]
for id, tier, name in UNIFORMS:
    add(id, tier, "characters", "faction_outfit", "kit_piece", name + " outfit", f"assets/kits/characters/outfits/{id}.glb",
        rig="humanoid", tri_budget="1500-2500", texture="palette_faction,trim_cloth_leather",
        notes="Multi-piece outfit; reuses clothing kit pieces where possible plus faction insignia. Shown when a town changes hands.")

# Prototype actors (exact actors.json keys)
PROTO_ACTORS = [
    ("player", "human", "humanoid", "The Wayfarer. Uses the human male/female kit with the player's choices; tier 0 needs one default look."),
    ("iska", "elf", "humanoid", "Iska Vell, elf hedge-wizard follower. Robe, satchel, staff socket."),
    ("osk_brannel", "dwarf", "humanoid_short", "Warden at the well. Constable outfit, beard."),
    ("hesta_lowe", "human", "humanoid", "Shrine keeper (Lantern Mother). Robe, shawl."),
    ("tam_fairweather", "halfling", "humanoid_small", "Coal hauler. Work jacket, cap, soot decals."),
    ("scav_boss", "human", "humanoid", "Rook Harl, scavenger leader with carbine. Reuse the scavenger outfit + long coat."),
    ("scav_hook", "human", "humanoid", "Scavenger with hookblade."),
    ("scav_brute", "human", "humanoid", "Scavenger brute with boiler lance. No race in actors.json yet: human with the heavy/muscular shape key keeps it on the tier-0 rig (make it an orc once humanoid_large exists)."),
]
for id, race, rig, notes in PROTO_ACTORS:
    add(id, 0, "characters", "actor", "model", nice(id), f"assets/characters/{id}/{id}.glb",
        binds_to=f"actors.json:{id}", shared_base=race, rig=rig, tri_budget="3000-5000",
        texture="palette_main,palette_skin_hair", placeholder="coloured capsule in Actor._build_visual()",
        notes="Build from the kit in Blender and export as one .glb. " + notes)
add("scavenger_outfit", 0, "characters", "faction_outfit", "kit_piece", "Scavenger / claim jumper outfit",
    "assets/kits/characters/outfits/scavenger_outfit.glb", rig="humanoid", tri_budget="1500",
    texture="palette_main,trim_cloth_leather", notes="Patched layers, scarf, scrap armour bits. Reused by bandits everywhere.")
add("companion_*", 4, "characters", "actor", "model", "Written companions (about 30)", "assets/characters/<companion_id>/<companion_id>.glb",
    binds_to="actors.json companion ids", count=30, rig="humanoid", tri_budget="5000-7000",
    texture="palette_main,palette_skin_hair", notes="Unique head + signature outfit each. Ids come from the quest/companion threads.")
add("anchor_npc_unique_parts_*", 4, "characters", "actor", "kit_piece", "Anchor NPC signature pieces (about 120)",
    "assets/kits/characters/anchor/<id>.glb", count=120, rig="humanoid", tri_budget="300-1500",
    notes="~500 anchor NPCs mostly come from the kit; give the important quarter one signature piece (hat, coat, prosthetic, tool).")

# =============================================================================
# 3. Creatures (bound as actor templates)
# =============================================================================
CREATURES = [
    # id, tier, rig, region, name, notes
    ("dog", 1, "quadruped_canine", "shared", "Dog", "Town ambient + guard dogs. 3 coat swatches."),
    ("thaw_wolf", 1, "quadruped_canine", "meltlands", "Thaw wolf", "Common predator. Shares the dog mesh with a shape key."),
    ("fox", 2, "quadruped_canine", "shared", "Fox", "Ambient."),
    ("clockwork_hound", 2, "quadruped_canine", "furnace_coast", "Clockwork hound", "Combine automaton; dog rig, mechanical mesh."),
    ("rat_giant", 1, "small_critter", "shared", "Giant rat", "Cellars and sewers."),
    ("soot_rat_swarm", 2, "small_critter", "furnace_coast", "Soot rat swarm", "Several rat meshes on one actor."),
    ("cat", 1, "small_critter", "shared", "Cat", "Ambient."),
    ("chicken", 1, "small_critter", "shared", "Chicken", "Farm ambient."),
    ("bog_frog_giant", 2, "small_critter", "meltlands", "Giant bog frog", ""),
    ("horse", 1, "quadruped_ungulate", "shared", "Horse", "Carts, coaches, mounts for NPCs."),
    ("mule", 1, "quadruped_ungulate", "shared", "Mule", "Pack-animal follower; saddlebag attachment."),
    ("ox", 1, "quadruped_ungulate", "meltlands", "Ox", "Ploughs and wagons."),
    ("cow", 1, "quadruped_ungulate", "meltlands", "Cow", "Shares ox mesh."),
    ("sheep", 2, "quadruped_ungulate", "shared", "Sheep", ""),
    ("goat_mountain", 2, "quadruped_ungulate", "spiremarch", "Mountain goat", ""),
    ("pig", 1, "quadruped_ungulate", "meltlands", "Pig", ""),
    ("elk", 2, "quadruped_ungulate", "shelf", "Elk", ""),
    ("glassback_elk", 2, "quadruped_ungulate", "shelf", "Glassback elk", "Wild-magic warped elk: elk mesh + crystal growth attachments."),
    ("boar_tusked", 2, "quadruped_heavy", "meltlands", "Tusked boar", ""),
    ("bear", 2, "quadruped_heavy", "spiremarch", "Bear", ""),
    ("ice_bear", 2, "quadruped_heavy", "shelf", "Ice bear", "Bear mesh, white swatch, frost decals."),
    ("mammoth_thawed", 3, "quadruped_heavy", "shelf", "Thawed mammoth", "Woken from the ice. Large."),
    ("troll_frost", 3, "humanoid_large", "shelf", "Frost troll", ""),
    ("mire_horror", 2, "humanoid_large", "meltlands", "Mire horror", "Bog creature of mud and roots."),
    ("slag_golem", 2, "humanoid_large", "furnace_coast", "Slag golem", "Molten-cored foundry waste."),
    ("stone_warden", 3, "humanoid_large", "spiremarch", "Stone warden", "Temple guardian construct."),
    ("crow", 1, "bird", "shared", "Crow", "Ambient flock."),
    ("gull", 2, "bird", "furnace_coast", "Gull", "Ambient."),
    ("great_eagle", 3, "bird", "spiremarch", "Great eagle", "Large bird, lair boss variant."),
    ("spider_cave", 2, "arachnid", "dungeons", "Cave spider", ""),
    ("crab_giant", 2, "arachnid", "drowned_vale", "Giant crab", ""),
    ("ossuan_crawler", 1, "arachnid", "ruins", "Ossuan crawler", "Guardian machine, still running. Needed for the first ruin."),
    ("eel_serpent", 2, "serpent", "drowned_vale", "Eel serpent", ""),
    ("thaw_worm", 3, "serpent", "shelf", "Thaw worm", "Giant burrower; emerge/burrow clips."),
    ("leech_giant", 2, "serpent", "drowned_vale", "Giant leech", ""),
    ("ice_wisp", 1, "floating", "shared", "Ice wisp", "Wild-magic sprite. Mostly VFX, tiny mesh."),
    ("ossuan_drone", 2, "floating", "ruins", "Ossuan orb drone", ""),
    ("barrow_spirit", 2, "floating", "dungeons", "Barrow spirit", "Firstfolk spirit; translucent shader."),
    ("skeleton", 2, "humanoid", "dungeons", "Skeleton", "Uses humanoid rig; carries any weapon."),
    ("drowned_dead", 2, "humanoid", "drowned_vale", "Drowned dead", "Waterlogged undead, weed attachments."),
    ("thawed_corpse", 1, "humanoid", "shelf", "Thawed revenant", "Frozen dead risen in the Thaw; also a ruin enemy in the first slice."),
    ("ossuan_sentinel", 2, "humanoid_large", "ruins", "Ossuan sentinel", "Humanoid guardian machine."),
    ("steam_walker", 3, "humanoid_large", "furnace_coast", "Combine steam walker", "Piloted walker; cockpit + boiler."),
    ("sentry_turret", 2, "", "furnace_coast", "Sentry turret", "Static; yaw/pitch bones only."),
    ("wyvern", 3, "winged_large", "spiremarch", "Wyvern", ""),
    ("glacier_drake", 3, "winged_large", "shelf", "Glacier drake", "Shelf boss creature."),
]
for id, tier, rig, region, name, notes in CREATURES:
    add(id, tier, "creatures", region, "model", name, f"assets/characters/{id}/{id}.glb",
        binds_to=f"actors.json:{id}", rig=rig, tri_budget="800-4000", texture="palette_main",
        placeholder="coloured capsule", notes=notes)
BOSSES = [
    ("ossuan_colossus", "ruins", "Ossuan colossus (major ruin boss)"),
    ("barrow_king", "dungeons", "Barrow king (Firstfolk)"),
    ("mire_mother", "meltlands", "Mire mother (lair boss)"),
    ("foundry_heart", "furnace_coast", "Foundry heart (slag titan)"),
    ("drowned_leviathan", "drowned_vale", "Drowned leviathan"),
    ("frozen_giant_awakened", "shelf", "Awakened frozen giant"),
    ("spire_lich", "spiremarch", "Spire lich"),
    ("cult_avatar", "shared", "Cult avatar"),
]
for id, region, name in BOSSES:
    add(id, 3, "creatures", region, "model", name, f"assets/characters/{id}/{id}.glb", binds_to=f"actors.json:{id}",
        rig="custom", tri_budget="6000-12000", texture="palette_main,own", maps="albedo,emission",
        notes="One of ~50 lair/ruin bosses get unique models; the rest are scaled + recoloured creatures with attachments.")

# =============================================================================
# 4. Items: base meshes, each covering many base items via material swaps,
#    quality, enchant decals and modular parts. Target ~1,500 base items.
# =============================================================================
# Each entry: mesh_id|tier|covers_items|notes
ITEMS = {
    ("neutral", "dagger"): [
        "dagger|1|8", "knife_utility|1|5|Also a tool.", "stiletto|2|5", "hook_knife|2|4", "cleaver|2|4"],
    ("neutral", "sword"): [
        "shortsword|1|7", "arming_sword|2|7", "falchion|2|6", "cutlass|2|6", "longsword|1|8",
        "broadsword|2|6", "sabre|2|6", "greatsword|2|7"],
    ("neutral", "axe"): ["hatchet|1|6", "battle_axe|2|7", "bearded_axe|2|6", "greataxe|2|7", "wood_axe|1|3|Also a tool."],
    ("neutral", "blunt"): ["club|1|5", "mace|2|7", "morningstar|2|5", "warhammer|2|6", "maul|2|6", "flail|3|5"],
    ("neutral", "polearm"): [
        "spear|1|7", "pike|2|5", "glaive|2|5", "halberd|2|6", "trident|3|4", "quarterstaff|1|5", "billhook|2|5"],
    ("neutral", "bow"): ["shortbow|1|6", "longbow|1|7", "recurve_bow|2|6", "sling|1|4"],
    ("neutral", "crossbow"): ["crossbow_light|2|6", "crossbow_heavy|2|6", "crossbow_repeating|3|4"],
    ("neutral", "thrown"): ["throwing_knife|2|4", "javelin|2|4", "throwing_axe|2|4", "bola|3|3", "net|3|2"],
    ("neutral", "ammo"): ["arrow|1|10|One shaft mesh, swappable heads.", "bolt|2|8", "sling_stone|2|3"],
    ("neutral", "shield"): ["buckler|1|5", "round_shield|1|6", "kite_shield|2|6", "tower_shield|2|5", "pavise|3|3"],

    ("gear", "pistol"): [
        "flintlock_pistol|1|8", "pepperbox|2|5", "revolver|2|10", "derringer|2|4", "air_pistol|3|4|Pneumatic."],
    ("gear", "longgun"): [
        "musket|1|6", "rifle|2|10", "carbine|1|7", "blunderbuss|2|5", "longrifle|3|5"],
    ("gear", "heavy_gun"): ["hand_cannon|2|4", "rocket_tube|3|4", "volley_gun|3|4", "steam_cannon|3|4"],
    ("gear", "gun_parts"): [
        "gun_barrel_*|1|12|4 barrels (short, long, rifled, heavy). Modular: guns are assembled from parts.",
        "gun_stock_*|1|10|4 stocks (walnut, ash, brass skeleton, folding).",
        "gun_action_*|1|10|4 actions (flint, percussion, clockwork drum, lever).",
        "gun_sight_*|2|8|3 sights (iron, peep, scope)."],
    ("gear", "steam_melee"): [
        "piston_hammer|2|6", "chainblade|3|5", "steam_gauntlet|2|6", "rivet_driver|2|4"],
    ("gear", "galvanic"): ["shock_baton|2|7", "coil_pistol|3|7", "arc_rifle|3|7", "galvanic_gauntlet|3|6"],
    ("gear", "demolition"): [
        "grenade_frag|2|5", "grenade_smoke|2|3", "grenade_incendiary|2|4", "dynamite_bundle|1|4",
        "plate_mine|3|4", "satchel_charge|3|3"],
    ("gear", "gear_ammo"): [
        "lead_shot|1|4", "paper_cartridge|1|5", "brass_cartridge|2|6", "shell|3|4", "coil_cell|3|4",
        "steam_canister|2|4", "powder_horn|1|3"],
    ("gear", "deployable"): ["tripod_turret|3|3", "clockwork_spider_mine|3|3", "decoy_automaton|3|2"],

    ("arcane", "staff"): ["wizard_staff|1|8", "crook_staff|2|7", "crystal_staff|2|7", "knotted_staff|1|5"],
    ("arcane", "wand"): ["wand_wood|1|6", "wand_bone|2|6", "wand_crystal|2|6", "wand_metal|3|6"],
    ("arcane", "rod"): ["rod|2|6", "sceptre|3|5", "censer|2|5|Divine flail-censer."],
    ("arcane", "focus"): [
        "orb|2|8", "focus_crystal|1|6", "idol|2|8", "holy_symbol_*|1|16|8 gods' symbols, one per pantheon god.",
        "prayer_beads|2|4"],
    ("arcane", "tome"): ["spellbook|1|10|Off-hand tome; cover from book_covers_atlas."],
    ("arcane", "ossuan_blade"): ["glass_sword|2|6", "ice_blade|2|5", "glyph_axe|3|4"],
    ("arcane", "relic"): ["reliquary|3|5", "relic_bone|3|5", "saints_hand|3|3"],
    ("arcane", "scroll"): ["scroll|1|40|One mesh; seal colour = school. 40 spell scrolls."],

    ("shared", "accessory"): [
        "ring|1|20|3 band shapes + gem socket.", "amulet|1|14", "belt|1|8", "bracers|2|8",
        "gas_mask|2|5|Gear.", "goggles|1|6|Gear.", "earring|3|6", "circlet|3|6"],

    ("shared", "tool"): [
        "lockpicks|1|4", "crowbar|1|2", "shovel|1|2", "pickaxe|1|3", "hammer_smith|1|3", "saw|2|2",
        "tongs|2|2", "wrench|1|4", "screwdriver_set|2|3", "lantern_oil|1|3", "lamp_galvanic|2|3", "torch|1|2",
        "rope_coil|1|2", "grappling_hook|2|2", "tinderbox|1|2", "bedroll|2|2", "tent_kit|3|2",
        "fishing_rod|2|3", "sickle|1|2", "scythe|2|2", "pitchfork|1|2", "assayer_lens|0|3|Prototype item.",
        "analyser|2|3", "diving_helmet|2|3", "ice_axe|2|3", "crampons|2|2", "compass|2|2", "spyglass|2|3",
        "map_case|2|2", "medic_kit|1|4", "surgeon_tools|2|3", "alchemy_set|1|4", "mortar_pestle|1|2",
        "scales|2|2", "quill_ink|2|2", "thieves_tools|2|3", "trap_kit|2|4", "fuse_spool|2|2",
        "oil_can|2|2", "soldering_iron|3|2"],

    ("shared", "consumable"): [
        "healing_draught|0|1|Prototype item.",
        "potion_round|1|8|Liquid colour from palette.", "potion_tall|1|8", "potion_flask|2|8",
        "potion_vial|1|8", "potion_jug|2|5", "tincture_dropper|2|6|Gear tonics and stimulants.",
        "bandage|1|3", "salve_tin|1|5", "holy_water|1|4", "pill_box|3|4",
        "bread|1|3", "cheese|1|2", "apple|1|3", "fish|1|3", "meat_cut|1|4", "stew_bowl|1|5",
        "pie|2|3", "mushroom|1|5", "ale_mug|1|4", "wine_bottle|2|5", "tea_tin|2|3", "ration_pack|2|3",
        "coal_briquette|1|3|Fuel for steam gear."],

    ("shared", "component"): [
        "ingot|1|8|One mesh, 8 metal swatches.", "ore_chunk|1|8", "gem_cut_*|1|15|5 cuts x 3 sizes via scale.",
        "gem_rough|2|8", "hide|1|6", "leather_roll|1|5", "cloth_bolt|1|4", "wood_plank|1|5", "wood_billet|1|4",
        "brass_spring|1|3", "gear_cog|1|6", "pipe_section|1|5", "valve|1|4", "rivets|2|2", "boiler_core|2|4",
        "copper_coil|2|5", "lens|1|5", "glass_tube|2|4", "wire_spool|2|4", "powder_keg|1|3", "powder_pouch|1|2",
        "chemical_jar|1|8", "ratchet_housing|1|3", "clockwork_trigger|1|3", "walnut_stock_blank|1|2",
        "rifled_barrel_blank|1|2", "herb_bundle_*|1|20|10 plant meshes x 3 swatches; also grown in home gardens.",
        "creature_part_*|2|28|8 meshes: fang, claw, hide scrap, eye, gland, horn, scale, feather.",
        "essence_vial|1|15|Enchanting essences: one vial, glow colour per essence.",
        "glyph_stone|2|12|Enchanting glyphs: one stone, decal per glyph.",
        "ossuan_fragment|2|8", "bone|2|4", "wax_seal|3|2", "thread_spool|2|3", "salt_sack|3|2"],

    ("shared", "document"): [
        "book_small|1|0|Lore books (1,000) share 6 book meshes + cover atlas; not counted as base items.",
        "book_large|1|0", "book_tome_chained|2|0", "book_open_lectern|2|0", "book_stack|1|0", "book_ledger|1|0",
        "letter|1|3", "schematic_blueprint|1|5|Rolled blueprint; schematics are items you learn.",
        "formula_page|1|4", "map_rolled|1|4", "notice_paper|1|2", "deed|2|3"],

    ("shared", "misc"): [
        "coin|0|3|Prototype item. Copper, silver, gold swatches.", "coin_purse|1|2", "key_*|1|12|6 key shapes x 2 metals.",
        "lockbox|2|3", "trade_goods_crate|2|6|Spices, tea, cloth, tools: one crate + labels.",
        "quest_trinket_*|3|20|10 generic trinket meshes (locket, idol, medal ...) reused by generated quests.",
        "musical_instrument_*|3|6|Fiddle, flute, drum.", "playing_cards|3|2", "dice|3|2", "pipe_tobacco|3|2"],
}

# Prototype items already in data/items.json bind by their exact key.
PROTO_ITEMS = {
    "repeating_carbine": ("gear", "longgun", "Assembled from gun parts (clockwork drum action, rifled barrel, walnut stock)."),
    "boiler_lance": ("gear", "steam_melee", "Pocket boiler + piston head. Charged mode: steam VFX."),
    "fen_hookblade": ("neutral", "polearm", "Hooked blade on a haft."),
    "shelf_longbow": ("neutral", "bow", "Shares the longbow mesh with Freeholder trim."),
    "starglass_staff": ("arcane", "staff", "Crystal staff variant; glow scales with Resonance."),
    "frostvein_dagger": ("arcane", "ossuan_blade", "Ice blade dagger; dormant glow until identified."),
}
PROTO_SHARED = {"shelf_longbow": "longbow", "starglass_staff": "crystal_staff", "frostvein_dagger": "ice_blade",
                "repeating_carbine": "carbine", "fen_hookblade": "billhook"}
for id, (pool, fam, notes) in PROTO_ITEMS.items():
    add(id, 0, "items", f"{pool}/{fam}", "model", nice(id), f"assets/items/{id}/{id}.glb",
        binds_to=f"items.json:{id}", shared_base=PROTO_SHARED.get(id, ""), covers_items=1,
        tri_budget="200-800", texture="palette_main,palette_metal",
        placeholder="grey box weapon in Actor._update_weapon_visual()", notes=notes)

for (pool, fam), entries in ITEMS.items():
    for e in entries:
        parts = e.split("|")
        mesh, tier, covers = parts[0], int(parts[1]), int(parts[2])
        note = parts[3] if len(parts) > 3 else ""
        count = 1
        if mesh.endswith("_*"):
            m = re.search(r"(\d+) ", note)
            count = int(m.group(1)) if m else 1
        proto = mesh in ("assayer_lens", "healing_draught", "coin")
        ttl = nice(mesh.rstrip("_*"))
        is_book = fam == "document" and mesh.startswith("book")
        add(mesh, tier, "items", f"{pool}/{fam}", "model", ttl,
            f"assets/items/{mesh.rstrip('_*')}/{mesh.rstrip('_*')}.glb" if count == 1 else f"assets/items/{mesh.rstrip('_*')}_NN/",
            binds_to=(f"items.json:{mesh}" if proto else f"items with \"model\": \"{mesh.rstrip('_*')}\""),
            count=count, covers_items=covers, tri_budget="50-800",
            texture=("book_covers_atlas" if is_book else "palette_main,palette_metal"),
            placeholder="grey box",
            notes=(note + " " if note else "") + "Variants (material, quality, region trim, enchant glyph decal) reuse this mesh.")

# Armour: modular sets x slots, fitted by shape key to all four body types.
ARMOUR_SLOTS = ["head", "torso", "arms", "legs", "hands", "feet"]
ARMOUR_SETS = [
    # set, tier, pool, covers per slot, notes
    ("padded", 1, "neutral", 2, "Gambeson."),
    ("leather", 1, "neutral", 4, ""),
    ("studded_leather", 2, "neutral", 2, ""),
    ("hide", 2, "neutral", 2, "Shelf and Meltlands hunters."),
    ("chainmail", 1, "neutral", 4, ""),
    ("scale", 2, "neutral", 2, ""),
    ("brigandine", 2, "neutral", 2, ""),
    ("plate", 2, "neutral", 4, ""),
    ("steam_plate", 3, "gear", 3, "Powered plate with back boiler; misfires at high Resonance."),
    ("rubber_diving", 3, "gear", 2, "Diving suit for drowned cities (pairs with diving_helmet)."),
    ("combine_trooper", 2, "gear", 3, "Riveted breastplate, gas mask helmet."),
    ("galvanic_mesh", 3, "gear", 3, "Insulated copper-mesh armour."),
    ("wizard_robes", 1, "arcane", 4, "Robes are armour-slot items for casters."),
    ("priest_vestments", 2, "arcane", 4, ""),
    ("ossuan_glass", 3, "arcane", 3, "Glass-steel scales from vaults; enchant-friendly."),
    ("warded_leather", 2, "arcane", 3, "Glyph-stitched leather."),
]
for s, tier, pool, covers, notes in ARMOUR_SETS:
    for slot in ARMOUR_SLOTS:
        if s in ("wizard_robes", "priest_vestments") and slot == "arms":
            continue
        add(f"{s}_{slot}", tier, "items", f"{pool}/armour", "model", f"{nice(s)} {slot}",
            f"assets/items/{s}_{slot}/{s}_{slot}.glb", binds_to=f"items with \"model\": \"{s}_{slot}\"",
            covers_items=covers, rig="humanoid", tri_budget="300-1500",
            texture="palette_main,palette_metal,trim_cloth_leather", placeholder="none (not drawn yet)",
            notes=("Skinned to the master skeleton; shape keys fit short/small/large bodies. Material and region trim variants reuse it. " + notes).strip())
for id, tier, covers, notes in [
    ("cloak", 1, 8, "Simulated or skinned cloth; recolour per faction."), ("cape_short", 2, 4, ""),
    ("helmet_open", 1, 4, "Generic helms beyond the sets."), ("helmet_great", 2, 4, ""), ("hat_wizard", 2, 4, ""),
    ("mitre_hood", 2, 3, "Divine headgear."), ("shoulder_pauldrons", 2, 4, "")]:
    add(id, tier, "items", "neutral/armour", "model", nice(id), f"assets/items/{id}/{id}.glb",
        binds_to=f"items with \"model\": \"{id}\"", covers_items=covers, rig="humanoid", tri_budget="200-1000",
        texture="palette_main,trim_cloth_leather", placeholder="none", notes=notes)

# =============================================================================
# 5. Buildings: modular kits per architectural style + prefabs bound to
#    area structure kinds (kind_WxD first, then kind).
# =============================================================================
KIT_PIECES = ["wall", "wall_door", "wall_window", "wall_half", "corner_out", "corner_in", "floor", "floor_upper",
              "stairs", "roof_slope", "roof_ridge", "roof_gable_end", "roof_corner", "chimney", "door", "window",
              "shutters", "foundation", "porch", "balcony", "trim_beam", "sign_bracket"]
STYLES = [
    # style, tier, texture, region, extra pieces, notes
    ("meltlands_timber", 0, "trim_wood,trim_stone_brick", "meltlands", ["thatch_roof", "dormer"],
     "Timber-frame and plaster homesteads. Tier 0 needs enough to rebuild the prototype houses."),
    ("meltlands_city", 1, "trim_wood,trim_stone_brick", "meltlands", ["shopfront", "arcade", "gutter"],
     "Fennick's Cross district: 2-3 storey terraces for dense streets."),
    ("shires_brick", 2, "trim_stone_brick", "old_shires", ["shopfront", "bay_window", "mansard_roof", "gaslamp_bracket"],
     "Old-money brick terraces of Aldermoot and Brannock."),
    ("furnace_industrial", 2, "trim_metal_industrial,trim_stone_brick", "furnace_coast",
     ["factory_wall_tall", "sawtooth_roof", "smokestack", "catwalk", "pipe_run", "gantry", "loading_door"],
     "Factories, foundries, company housing."),
    ("company_row", 2, "trim_stone_brick,trim_metal_industrial", "furnace_coast", ["outhouse", "coal_bunker"],
     "Cheap identical company-town rows (ideal for generated density)."),
    ("spiremarch_stone", 2, "trim_temple,trim_stone_brick", "spiremarch",
     ["tower_round", "tower_cap", "buttress", "arch", "colonnade", "rose_window"], "Temples, monasteries, mage towers."),
    ("shelf_boomtown", 2, "trim_wood", "shelf", ["false_front", "canvas_roof", "tent_wall", "log_wall"],
     "Boomtown false fronts, tents, log cabins."),
    ("vale_stilt", 2, "trim_wood", "drowned_vale", ["stilt", "walkway", "rope_bridge", "reed_roof"],
     "Stilt towns over floodwater."),
]
for style, tier, tex, region, extra, notes in STYLES:
    pieces = KIT_PIECES + extra
    add(f"kit_{style}", tier, "buildings", region, "kit", f"{nice(style)} building kit ({len(pieces)} pieces)",
        f"assets/kits/{style}/", count=len(pieces), tri_budget="50-500 per piece", texture=tex,
        maps="albedo,normal,orm", placeholder="boxes in World._build_structure()",
        notes=f"1-tile (1 m) snap grid, 3 m storey height. Pieces: {', '.join(pieces)}. {notes}")

PREFABS = [
    # id(kind or kind_WxD), tier, style, name, notes
    ("house_4x3", 0, "meltlands_timber", "Homestead house 4x3", "Prototype house footprint (2 in Fennick's Landing)."),
    ("house_4x4", 0, "meltlands_timber", "Homestead house 4x4", "Prototype footprint."),
    ("house_5x3", 0, "meltlands_timber", "Homestead house 5x3", "Prototype footprint."),
    ("house", 0, "meltlands_timber", "House (any footprint fallback)", "Fallback when no kind_WxD model exists."),
    ("shrine", 0, "meltlands_timber", "Wayside shrine 2x2", "Prototype. Emissive lantern-crystal; light stays in code."),
    ("well", 0, "meltlands_timber", "Town well 1x1", "Prototype."),
    ("pumphouse", 0, "meltlands_timber", "Pumphouse 6x5 with boiler and chimney", "Prototype. Needs cold and lit states (chimney smoke VFX)."),
    ("coal", 0, "meltlands_timber", "Coal heap 2x2", "Prototype."),
    ("crate", 0, "meltlands_timber", "Crate 1x1", "Prototype."),
    ("fence", 0, "meltlands_timber", "Fence run (tiles along length)", "Prototype; model 1-tile segment, code repeats it."),
    ("barn", 1, "meltlands_timber", "Barn", ""), ("farmhouse", 1, "meltlands_timber", "Farmhouse", ""),
    ("windmill", 1, "meltlands_timber", "Windmill", ""), ("watermill", 2, "meltlands_timber", "Watermill", ""),
    ("tavern", 1, "meltlands_city", "Tavern / inn", "Every town."), ("general_store", 1, "meltlands_city", "General store", ""),
    ("smithy", 1, "meltlands_city", "Smithy", "Crafting station inside."), ("workshop_engineer", 1, "meltlands_city", "Engineer's workshop", ""),
    ("chapel", 1, "meltlands_timber", "Chapel", ""), ("constable_post", 1, "meltlands_city", "Constable post", ""),
    ("townhouse_terrace_*", 1, "meltlands_city", "Terraced townhouses (6 variants)", "Main density filler for the city district."),
    ("tenement", 1, "meltlands_city", "Tenement block", "4 storeys, many residents."),
    ("market_hall", 2, "meltlands_city", "Market hall", ""), ("reading_room", 1, "meltlands_city", "Town reading room", "Small library; books on shelves."),
    ("assay_office", 2, "shires_brick", "Assay Office branch", "Appraisers and patent copies."),
    ("bank", 2, "shires_brick", "Bank / counting house", ""), ("guild_hall", 2, "shires_brick", "Guild hall", "Minor-faction home rooms."),
    ("library_city", 2, "shires_brick", "City library (generic)", "Base for the four signature libraries."),
    ("factory", 2, "furnace_industrial", "Factory", ""), ("foundry", 2, "furnace_industrial", "Foundry", ""),
    ("mine_head", 2, "furnace_industrial", "Mine head and winding tower", ""), ("rail_station", 2, "furnace_industrial", "Rail station", ""),
    ("company_house_*", 2, "company_row", "Company houses (4 variants)", ""),
    ("warehouse", 2, "furnace_industrial", "Warehouse", ""), ("dockside_shed", 2, "furnace_industrial", "Dock shed", ""),
    ("temple", 2, "spiremarch_stone", "Temple", ""), ("monastery", 2, "spiremarch_stone", "Monastery", ""),
    ("mage_tower", 2, "spiremarch_stone", "Mage tower", "Also the 'hermit's tower' home."),
    ("boomtown_saloon", 2, "shelf_boomtown", "Boomtown saloon", ""), ("claim_cabin", 2, "shelf_boomtown", "Claim cabin", "Freeholder home."),
    ("canvas_tent", 1, "shelf_boomtown", "Canvas tent", "Also the road camp in the first slice."),
    ("stilt_house", 2, "vale_stilt", "Stilt house", "Tideless home."), ("houseboat", 3, "vale_stilt", "Houseboat", "Player home (won at cards)."),
    ("camp_road", 1, "shelf_boomtown", "Roadside camp set", "Fire pit, tents, wagon: the first slice's road camp."),
    ("city_wall_*", 2, "shires_brick", "City walls, gates, towers (8 pieces)", ""),
    ("bridge_*", 1, "meltlands_timber", "Bridges (timber, stone, iron; 3)", ""),
    ("dock_*", 2, "furnace_industrial", "Docks and piers (5 pieces)", ""),
    ("rail_track_*", 2, "furnace_industrial", "Rail track kit (straight, curve, switch, buffer, bridge; 5)", ""),
    ("canal_lock", 2, "shires_brick", "Canal lock", ""),
]
for id, tier, style, name, notes in PREFABS:
    count = 1
    if id.endswith("_*"):
        m = re.search(r"(\d+) (?:variants|pieces)|; (\d+)\)", name)
        count = int(next(g for g in m.groups() if g)) if m else 1
    base = id.rstrip("_*")
    proto = tier == 0
    add(id, tier, "buildings", style, "prefab", name,
        f"assets/structures/{base}/{base}.glb" if count == 1 else f"assets/structures/{base}_NN/",
        binds_to=(f"area structure kind \"house\" footprint {id.split('_')[1]}" if re.fullmatch(r"house_\d+x\d+", id) else f"area structure kind \"{base}\""),
        shared_base=f"kit_{style}", count=count, tri_budget="1000-8000", texture="from kit",
        placeholder="boxes in World._build_structure()" if proto else "generated primitive",
        notes=("Built from the kit; export as one .glb. " + notes).strip())

LANDMARKS = [
    ("royal_archive", "old_shires", "The Royal Archive (Aldermoot)"), ("aldermoot_palace", "old_shires", "Crown palace (Aldermoot)"),
    ("brannock_canal_works", "old_shires", "Canal works (Brannock)"), ("combine_patent_hall", "furnace_coast", "Combine Patent Hall (Cinderhythe)"),
    ("cinderhythe_great_foundry", "furnace_coast", "Great foundry (Cinderhythe)"), ("port_gallow_harbour", "furnace_coast", "Harbour cranes (Port Gallow)"),
    ("kettlemouth_pithead", "furnace_coast", "Deep pithead (Kettlemouth)"), ("fennicks_cross_exchange", "meltlands", "Land exchange (Fennick's Cross)"),
    ("hollowbridge_span", "meltlands", "The hollow bridge (Hollowbridge)"), ("collegium_stacks", "spiremarch", "Collegium Stacks (Vaelstrand)"),
    ("vaelstrand_high_temple", "spiremarch", "High temple (Vaelstrand)"), ("highcairn_cairn_gate", "spiremarch", "Cairn gate (Highcairn)"),
    ("lastlight_beacon", "shelf", "The beacon (Lastlight)"), ("frostgate_icewall", "shelf", "Ice wall fort (Frostgate)"),
    ("tideless_memory_houses", "drowned_vale", "Tideless Memory Houses (Saltglass)"), ("murrow_sunken_spire", "drowned_vale", "Sunken spire (Murrow)"),
]
for id, region, name in LANDMARKS:
    add(id, 3, "buildings", region, "prefab", name, f"assets/structures/{id}/{id}.glb", binds_to=f"area structure kind \"{id}\"",
        tri_budget="8000-25000", texture="trims + own", notes="City signature landmark: mostly kit pieces plus unique hero parts.")

# =============================================================================
# 6. Ruins and dungeon kits
# =============================================================================
DUNGEON_KITS = [
    ("ossuan_ruin", 1, "trim_ossuan", ["wall", "wall_broken", "pillar", "pillar_broken", "arch", "floor", "floor_broken",
     "stairs", "door_sealed", "door_open", "glyph_panel", "machine_socket", "vault_door", "rubble_pile", "ice_encased_wall"],
     "~250 ruins: the main kit. First slice needs the small-ruin subset."),
    ("ossuan_vault", 3, "trim_ossuan", ["vault_wall", "relic_plinth", "guardian_alcove", "lift_platform", "energy_conduit", "seal_ring"],
     "Spire vaults."),
    ("ossuan_drowned", 3, "trim_ossuan", ["flooded_wall", "coral_growth", "air_pocket_dome", "collapsed_roof", "seaweed"],
     "Drowned cities: Ossuan kit + water dressing."),
    ("ice_shelf_ruin", 2, "trim_ossuan", ["ice_wall", "ice_floor", "meltwater_channel", "ice_pillar", "half_buried_door"],
     "Ruins melting out of the glacier."),
    ("firstfolk_barrow", 2, "trim_firstfolk", ["barrow_entrance", "passage", "chamber_round", "burial_niche", "standing_stone",
     "spiral_slab", "turf_mound"], "Firstfolk barrows."),
    ("cave_rock", 1, "trim_stone_brick", ["cave_wall", "cave_corner", "cave_floor", "cave_ceiling_edge", "stalagmite",
     "stalactite", "rock_column", "narrow_passage", "chasm_edge"], "~100 caves."),
    ("cave_ice", 2, "trim_ossuan", ["ice_cave_wall", "ice_cave_corner", "icicle", "frozen_pool", "ice_crystal_cluster"], "Ice caves."),
    ("mine_gallery", 2, "trim_wood,trim_metal_industrial", ["timber_frame", "gallery_wall", "ore_vein", "mine_cart",
     "track_short", "lift_cage", "collapsed_shaft"], "Mines and smugglers' tunnels."),
    ("cellar_sewer", 1, "trim_stone_brick", ["cellar_wall", "vault_ceiling", "sewer_channel", "grate", "ladder", "brick_arch"],
     "Small generated ruins (cellars) and city undercrofts."),
]
for kit, tier, tex, pieces, notes in DUNGEON_KITS:
    add(f"kit_{kit}", tier, "dungeons", kit, "kit", f"{nice(kit)} kit ({len(pieces)} pieces)", f"assets/kits/{kit}/",
        count=len(pieces), tri_budget="50-800 per piece", texture=tex, maps="albedo,normal,orm",
        notes=f"Pieces: {', '.join(pieces)}. {notes}")
for id, tier, name, notes in [
    ("loot_vault_chest", 1, "Vault chest (reward chamber)", "Open/closed states."),
    ("loot_chest_common", 1, "Common chest", ""), ("ossuan_terminal", 2, "Ossuan glyph terminal", "Puzzle/translation object."),
    ("trap_pressure_plate", 1, "Pressure plate trap", ""), ("trap_dart_wall", 2, "Dart wall trap", ""),
    ("trap_glyph_ward", 2, "Glyph ward trap", "Decal + VFX."), ("lever_switch", 1, "Lever", ""),
    ("cult_altar", 2, "Cult altar", ""), ("scavenger_camp_dressing", 1, "Scavenger camp dressing set", "Bedrolls, loot piles, campfire."),
    ("bones_remains", 1, "Bones and remains", ""), ("cobweb_set", 2, "Cobwebs", ""),
]:
    add(id, tier, "dungeons", "dressing", "model", name, f"assets/structures/{id}/{id}.glb", binds_to=f"area structure kind \"{id}\"",
        tri_budget="100-1500", notes=notes)

# =============================================================================
# 7. Natural sites and vegetation
# =============================================================================
NATURE = [
    # id, tier, region, name, count, notes
    ("tree_alder", 1, "meltlands", "Alder tree", 3, "3 shapes; lush/bare by Resonance."),
    ("tree_willow", 1, "meltlands", "Willow tree", 2, ""),
    ("tree_oak", 2, "old_shires", "Oak tree", 3, ""),
    ("tree_pine_dead", 2, "furnace_coast", "Soot-killed pine", 3, ""),
    ("tree_fir", 2, "spiremarch", "Fir tree", 3, ""),
    ("tree_birch_dwarf", 2, "shelf", "Dwarf birch", 2, ""),
    ("tree_swamp_cypress", 2, "drowned_vale", "Swamp cypress", 3, ""),
    ("tree_stump_log", 1, "shared", "Stumps and fallen logs", 4, ""),
    ("bush_shrub", 1, "shared", "Bushes and shrubs", 5, ""),
    ("grass_clumps", 0, "shared", "Grass and weed clumps", 4, "Scattered by code over ground."),
    ("reeds_cattails", 1, "meltlands", "Reeds and cattails", 3, ""),
    ("flowers_wild", 0, "shared", "Wildflower patches", 3, "Shrine Green dressing."),
    ("crops_*", 1, "meltlands", "Crops (wheat, barley, cabbage, turnip, potato; 3 growth stages)", 15, ""),
    ("rock_boulder", 1, "shared", "Boulders", 6, ""),
    ("rock_cliff_kit", 2, "shared", "Cliff and slope kit", 8, ""),
    ("ice_chunks", 2, "shelf", "Ice chunks and floes", 5, ""),
    ("glacier_wall_kit", 2, "shelf", "Glacier wall kit", 6, "The retreating ice edge."),
    ("frozen_giant", 3, "shelf", "Frozen giant in the ice (landmark)", 3, "50 landmarks reuse these with poses."),
    ("standing_stones", 2, "shared", "Standing stones", 5, "Firstfolk."),
    ("spring_pool_sacred", 2, "shared", "Sacred spring pool", 3, "60 springs: pool + shrine dressing + glow."),
    ("hot_spring_geyser", 3, "shared", "Hot spring and geyser", 3, "Steam VFX."),
    ("waterfall", 3, "spiremarch", "Waterfall", 2, "Animated shader."),
    ("ore_seam_*", 2, "shared", "Ore seams and deposits", 6, "Iron, coal, copper, silver, crystal, Ossuan glass."),
    ("mushroom_cluster", 1, "dungeons", "Cave mushrooms", 3, "Also alchemy ingredients."),
    ("lookout_rock", 3, "shared", "Lookout outcrop", 2, "Map-reveal landmarks."),
    ("battlefield_dressing", 3, "shared", "Old battlefield dressing", 6, "Broken carts, rusted guns, banners."),
    ("hermit_hut", 2, "shared", "Hermit hut", 2, "Camps, hermits and shrines."),
    ("wayside_shrine_*", 2, "shared", "Wayside shrines (one per god)", 8, ""),
    ("lair_nest_*", 2, "shared", "Monster lair nests", 4, "Bones, nest, den mouth."),
]
for id, tier, region, name, count, notes in NATURE:
    base = id.rstrip("_*")
    add(id if count == 1 or id.endswith("_*") else id + "_*", tier, "nature", region, "model", name,
        f"assets/structures/{base}_NN/" if count > 1 else f"assets/structures/{base}/{base}.glb",
        binds_to=f"area structure kind \"{base}\"", count=count, tri_budget="100-2000",
        texture="palette_main,palette_resonance_lush", notes=notes)

WRECKS = [("wreck_locomotive", "Derailed locomotive"), ("wreck_carriage", "Rail carriage, overturned"),
          ("wreck_steam_engine", "Crashed traction engine"), ("wreck_ship_in_ice", "Ship trapped in ice"),
          ("wreck_airship_gondola", "Fallen balloon gondola"), ("wreck_wagon", "Broken wagon")]
for id, name in WRECKS:
    add(id, 3 if id != "wreck_wagon" else 1, "nature", "wrecks", "model", name, f"assets/structures/{id}/{id}.glb",
        binds_to=f"area structure kind \"{id}\"", tri_budget="2000-8000", texture="palette_metal,trim_metal_industrial",
        notes="40 wreck sites reuse these with salvage props.")

# =============================================================================
# 8. Props: furniture, crafting stations, street dressing, vehicles
# =============================================================================
PROPS = [
    # id, tier, group, notes
    ("bed", 1, "furniture", "Every resident sleeps in one."), ("bed_cot", 1, "furniture", ""), ("table", 1, "furniture", ""),
    ("table_long", 1, "furniture", "Taverns."), ("chair", 1, "furniture", ""), ("stool", 1, "furniture", ""), ("bench", 1, "furniture", ""),
    ("shelf_wall", 1, "furniture", ""), ("bookshelf", 1, "furniture", "Fills with book meshes from the cover atlas."),
    ("chest", 1, "furniture", "Lootable."), ("wardrobe", 1, "furniture", ""), ("desk", 1, "furniture", "Generated documents sit on desks."),
    ("hearth_fireplace", 1, "furniture", ""), ("stove_iron", 1, "furniture", ""), ("cupboard", 1, "furniture", ""),
    ("rug", 1, "furniture", ""), ("cradle", 2, "furniture", ""), ("bar_counter", 1, "furniture", ""),
    ("shop_counter", 1, "furniture", ""), ("display_rack_weapons", 1, "furniture", ""), ("lectern", 2, "furniture", ""),
    ("pew", 2, "furniture", ""), ("altar", 1, "furniture", ""), ("candle_set", 1, "lighting", ""), ("oil_lamp", 1, "lighting", ""),
    ("gas_lamp_post", 2, "lighting", "City streets."), ("lantern_post", 1, "lighting", "Towns."), ("brazier", 1, "lighting", ""),
    ("barrel", 0, "storage", "Prototype yard dressing."), ("sack_pile", 1, "storage", ""), ("crate_stack", 1, "storage", ""),
    ("anvil", 1, "crafting_station", "Smithing."), ("forge", 1, "crafting_station", ""), ("workbench_engineer", 1, "crafting_station", "Gear schematics."),
    ("workbench_wood", 1, "crafting_station", "Fletching and carpentry."), ("tanning_rack", 2, "crafting_station", "Leatherwork."),
    ("alchemy_table", 1, "crafting_station", ""), ("enchanting_table", 1, "crafting_station", "Glow by local Resonance."),
    ("scribe_desk", 2, "crafting_station", "Scrolls."), ("cooking_pot", 1, "crafting_station", ""), ("loom", 2, "crafting_station", ""),
    ("lathe_steam", 2, "crafting_station", ""), ("galvanic_bench", 3, "crafting_station", ""), ("automaton_cradle", 3, "crafting_station", "Automata trade."),
    ("market_stall", 1, "street", ""), ("notice_board", 1, "street", "Quest board."), ("street_sign", 1, "street", ""),
    ("shop_sign_*", 1, "street", "Hanging shop signs (8 trades)"), ("water_pump", 1, "street", ""), ("trough", 1, "street", ""),
    ("hitching_post", 1, "street", ""), ("handcart", 1, "street", ""), ("wagon", 1, "vehicle", "Pulled by ox/horse."),
    ("coach", 2, "vehicle", ""), ("rowboat", 2, "vehicle", ""), ("barge", 2, "vehicle", "Canals."), ("locomotive", 3, "vehicle", "Working train (not a wreck)."),
    ("rail_carriage", 3, "vehicle", ""), ("traction_engine", 3, "vehicle", ""), ("gravestone_*", 1, "street", "Gravestones (4)"),
    ("statue_generic", 2, "street", ""), ("fountain", 2, "street", ""), ("banner_*", 2, "street", "Faction banners and flags (8): swap when towns change hands."),
    ("war_map_table", 2, "furniture", "Faction HQs."), ("boiler_large", 1, "industrial", "Pumphouse/factory boiler; lit/cold states."),
    ("pipe_run_set", 2, "industrial", ""), ("smokestack_free", 2, "industrial", ""), ("crane_dock", 2, "industrial", ""),
    ("coal_cart", 1, "industrial", ""), ("scaffolding", 2, "industrial", ""), ("haybale", 1, "farm", ""), ("plough", 1, "farm", ""),
    ("fence_stone_wall", 1, "farm", ""), ("chicken_coop", 2, "farm", ""), ("beehive", 2, "farm", ""), ("scarecrow", 1, "farm", ""),
    ("campfire", 1, "camp", ""), ("bedroll_placed", 1, "camp", ""), ("tent_small", 1, "camp", ""),
    ("home_upgrade_*", 2, "home", "Player home upgrades: storage, workshop, enchanting nook, garden bed, staff quarters (5)"),
    ("clutter_small_*", 1, "clutter", "Small clutter (24): plates, mugs, tools, papers, bottles"),
]
for id, tier, group, notes in PROPS:
    base = id.rstrip("_*")
    count = 1
    if id.endswith("_*"):
        m = re.search(r"\((\d+)", notes)
        count = int(m.group(1)) if m else 1
    add(id, tier, "props", group, "model", nice(base), f"assets/structures/{base}/{base}.glb" if count == 1 else f"assets/structures/{base}_NN/",
        binds_to=f"area structure kind \"{base}\"", count=count, tri_budget="50-2000",
        texture="palette_main" if group not in ("industrial", "vehicle") else "palette_metal,trim_metal_industrial",
        notes=notes)


# =============================================================================
def _expand_paths():
    """Grouped rows (count > 1) get one id per variant: <base>_01 .. <base>_NN,
    each in its own folder as the pipeline expects. Kits get one file per piece."""
    for r in rows:
        r["id"] = r["id"].replace("_*", "_NN")
        p = r["path"]
        if p.endswith("_NN/"):
            folder = p[:-1]
            base = folder.rsplit("/", 1)[1]
            r["path"] = f"{folder}/{base}.glb"
            r["notes"] = (f"Variant ids {base.replace('_NN', '_01')} to {base.replace('_NN', '_%02d' % int(r['count']))}. " + r["notes"]).strip()
        elif r["kind"] == "kit":
            style = r["id"][len("kit_"):]
            r["path"] = f"{p}{style}_<piece>.glb"


def write():
    _expand_paths()
    OUT.parent.mkdir(parents=True, exist_ok=True)
    rows.sort(key=lambda r: (r["tier"], r["category"], r["subcategory"], r["id"]))
    with OUT.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=COLUMNS)
        w.writeheader()
        w.writerows(rows)


def summary():
    by = defaultdict(lambda: Counter())
    for r in rows:
        by[r["tier"]][r["category"]] += int(r["count"])
    cats = sorted({r["category"] for r in rows})
    print("| Tier | " + " | ".join(cats) + " | Files |")
    print("|---" * (len(cats) + 2) + "|")
    for t in sorted(by):
        print(f"| {t} | " + " | ".join(str(by[t].get(c, 0)) for c in cats) + f" | {sum(by[t].values())} |")
    tot = Counter()
    for t in by:
        tot.update(by[t])
    print("| all | " + " | ".join(str(tot.get(c, 0)) for c in cats) + f" | {sum(tot.values())} |")
    items = [r for r in rows if r["category"] == "items"]
    cov = Counter()
    meshes = Counter()
    for r in items:
        pool = r["subcategory"].split("/")[0]
        cov[pool] += int(r["covers_items"])
        meshes[pool] += int(r["count"])
    print("\nItems by pool: base items covered / model files")
    for p in cov:
        print(f"  {p}: {cov[p]} / {meshes[p]}")
    print(f"  total: {sum(cov.values())} / {sum(meshes.values())}")
    print(f"\nRows: {len(rows)}")


if __name__ == "__main__":
    write()
    if "--summary" in sys.argv:
        summary()
    print(f"wrote {OUT.relative_to(ROOT)} ({len(rows)} rows)")
