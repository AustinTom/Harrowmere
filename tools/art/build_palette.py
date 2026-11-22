#!/usr/bin/env python3
"""Builds the Harrowmere reference colour swatches (see docs/art/README.md).

These are the approved colours that textures are painted or tinted from, grouped by
material family, faction and glow. Writes to art/palette/:
  harrowmere_swatches.png   256x256 sheet, 16x16 cells of 16 px (sample with a colour picker)
  palette.json              names, hex, suggested roughness/metallic and cell for every swatch,
                            plus the per-owner colours for faction-swappable parts

Edit the tables below and rerun:  python3 tools/art/build_palette.py
"""
import json, os
from PIL import Image

CELL, GRID = 16, 16
OUT = os.path.join(os.path.dirname(__file__), "..", "..", "art", "palette")

# (name, hex, roughness 0-1, metallic 0-1). Rows are material families.
ROWS = [
 ("skin", [("human_1","#f1d0b5"),("human_2","#e4b896"),("human_3","#d9a982"),("human_4","#c68d66"),("human_5","#a8714d"),("human_6","#8a5a3c"),("human_7","#6b4430"),("human_8","#4d3022"),
           ("elf_pale","#e6dccf"),("elf_sea","#cfd6d0"),("orc_moss","#8f9a68"),("orc_green","#7c8f5a"),("orc_dark","#5f6e47"),("orc_slate","#6b6f63"),("dwarf_ruddy","#c9876a"),("gnome_rosy","#e9c1a0")], 0.7, 0),
 ("hair", [("black","#1e1a18"),("dark_brown","#3b2a20"),("brown","#5c3f2a"),("chestnut","#7a4a2c"),("auburn","#8f3f22"),("ginger","#b8642e"),("dirty_blond","#a88a5a"),("blond","#d4b77a"),
           ("ash","#b9b2a5"),("grey","#8d8a86"),("white","#e8e4dc"),("elf_silver","#a7c2bd"),("elf_kelp","#233430"),("dwarf_copper","#9c5a2e"),("orc_black","#151515"),("dye_violet","#5a3a6e")], 0.8, 0),
 ("cloth_warm", [("madder","#8e2f2a"),("rust","#a5502d"),("ochre","#c08a3e"),("mustard","#b39b3b"),("oxblood","#5e1f1f"),("plum","#5c3045"),("tan","#b59a74"),("oatmeal","#d8c8a6"),
           ("burgundy","#6e2433"),("terracotta","#b5653f"),("brown_wool","#6a4d36"),("dun","#8c7a5b"),("umber","#3e2c20"),("saffron","#d2a03c"),("faded_rose","#c99a8f"),("cream","#ece2cb")], 0.95, 0),
 ("cloth_cool", [("navy","#23304d"),("indigo","#2e2a5c"),("lapis","#3f5aa8"),("sky","#7f9fc4"),("teal","#2f6b6b"),("sea_green","#4f8f7f"),("moss","#5b6b3a"),("olive","#6c6a3e"),
           ("forest","#2f4a33"),("slate","#4a5a5e"),("grey","#7a7f82"),("charcoal","#33363a"),("lavender","#8a7fae"),("ice","#b9d3dd"),("black","#1b1c1f"),("linen","#f0ece2")], 0.95, 0),
 ("leather_wood", [("leather_dark","#3d2a1e"),("leather","#6b4a30"),("leather_tan","#9a6e45"),("rawhide","#c9a77a"),("wood_dark","#3f2b1d"),("timber","#5a3d2b"),("wood_mid","#7d5a3c"),("pine_plank","#a8875c"),
           ("birch","#d8d0bf"),("bark","#4b3526"),("driftwood","#9b948a"),("charred","#2b2521"),("rope","#b39a6a"),("thatch","#a88b52"),("wicker","#8f7445"),("cork","#b07f52")], 0.85, 0),
 ("stone", [("limestone","#e3dccb"),("stone","#cfc6b2"),("sandstone","#c4a97f"),("stone_mid","#9a917f"),("granite","#85837e"),("slate_stone","#5d636a"),("basalt","#3b3d40"),("mossy_stone","#7c8466"),
           ("marble","#ece9e2"),("ossuan_bone","#ddd6c4"),("ossuan_dark","#8f8a7d"),("firstfolk","#6f6556"),("cobble","#625c55"),("cinder","#55504a"),("plaster","#e2d6bc"),("plaster_dirty","#bfb196")], 0.9, 0),
 ("brick_roof", [("brick","#8c3b2a"),("brick_light","#a8573c"),("brick_dark","#5e281e"),("brick_soot","#3e2a24"),("clay_tile","#a65a3a"),("slate_roof","#3e4a5c"),("slate_roof_lt","#5a687a"),("lead","#6d7378"),
           ("copper_green","#5f9c8a"),("thatch_dark","#7d6a40"),("shingle","#6b5440"),("tar","#222022"),("whitewash","#efebe1"),("limewash","#e6d59a"),("mortar","#b8ad98"),("chimney_black","#2a2523")], 0.9, 0),
 ("metal", [("iron","#4d5257"),("steel","#8a9096"),("steel_bright","#c3c8cc"),("brass","#b8873a"),("brass_bright","#d9ab55"),("copper","#a86a45"),("bronze","#7d5a32"),("ossuan_bronze","#4a3c2c"),
           ("gilt","#c9a54a"),("silver","#b9bcc0"),("pewter","#8a8a82"),("verdigris","#4f8f7f"),("rust","#8a4a2a"),("blued_steel","#3c4658"),("cast_iron","#2b2d30"),("tin","#a9a9a0")], 0.45, 1),
 ("ground", [("grass","#6f8f4e"),("grass_dark","#4f6e3a"),("grass_dry","#9a9a5a"),("meltland_lush","#5f9a4a"),("moss","#4a6a30"),("pine","#36593f"),("pine_dark","#27432f"),("leaf_autumn","#b0703a"),
           ("lichen","#9aa67a"),("mud","#6b5440"),("wet_mud","#4a3a2c"),("dirt_road","#8a7a63"),("sand","#c9b58a"),("peat","#3a2e24"),("dead_ground","#6e6a62"),("scorched","#3a3430")], 0.95, 0),
 ("water_ice", [("deep_water","#2f5a68"),("water","#4f7f8c"),("shallow","#7fa8a8"),("vale_teal","#3f7a72"),("meltwater","#a3c6cc"),("ice","#cfe4ea"),("ice_deep","#8fb8c8"),("glacier","#6fa0bf"),
           ("snow","#f2f4f5"),("snow_shade","#c7d2dc"),("slush","#a9aeb0"),("foul_water","#5a5a44"),("cold_sea","#3a5866"),("foam","#e0e6e4"),("silt","#8a8670"),("frost","#e8f1f4")], 0.15, 0),
 ("compact", [("indigo","#2e2a5c"),("violet","#3a2550"),("lapis","#3f5aa8"),("pale_lapis","#8fa6d6"),("white_stone","#ece6d6"),("gilt","#c9a54a"),("cream","#efe4c8"),("divine_gold","#d9b357"),
           ("sky","#a9c6e8"),("plum","#4e2f5a"),("star_silver","#cfd4dc"),("ink","#1d1b33"),("temple_red","#8e2f2a"),("sacred_green","#4f7a4a"),("wax","#efe1b8"),("ash_blue","#6b7a99")], 0.8, 0),
 ("combine", [("soot","#2a2523"),("brick","#8c3b2a"),("brass","#b8873a"),("iron","#4d5257"),("oilcloth","#3d3b2c"),("company_red","#a3301f"),("khaki","#8c7f55"),("coal","#1d1c1c"),
           ("smog","#8a8580"),("hazard","#d4a52a"),("rust","#8a4a2a"),("gunmetal","#3a3f45"),("tar","#222022"),("canvas","#b5a888"),("leather","#6b4a30"),("steam_white","#dfe0dc")], 0.75, 0),
 ("meridian", [("slate","#4a5a5e"),("verdigris","#4f8f7f"),("bone","#e6dfcc"),("copper","#a86a45"),("dull_silver","#a9b1b3"),("ash","#7d7f78"),("dusk_teal","#2e4c50"),("pale_clay","#c9b79a"),
           ("ink_grey","#2d3336"),("wheat","#cdb47a"),("oxide","#7a4f3a"),("sage","#8ea08a"),("mist","#d2d8d4"),("brown","#5c4a3a"),("half_brass","#b8873a"),("half_lapis","#3f5aa8")], 0.8, 0),
 ("owner", None, 0.8, 0),   # filled per owner below; default = contested
 ("glow", [("arcane","#7fd4ff"),("divine","#ffe08a"),("furnace","#ff7a2a"),("galvanic","#f4f0a0"),("ossuan","#5ff0d0"),("necrotic","#b36bff"),("poison","#8fd14f"),("frost","#bfefff"),
           ("fire","#ff5a1f"),("gaslamp","#ffc46a"),("lightning","#a8c8ff"),("healing","#9fffb0"),("curse","#c03a6a"),("interference","#ff4fd8"),("oil_lamp","#ffb35a"),("ember","#c2401a")], 1.0, 0),
 ("neutral", [(f"grey_{i:02d}", "#%02x%02x%02x" % ((i*17,)*3)) for i in range(16)], 0.9, 0),
]
OWNER_ROW = 13
GLOW_ROW = 14
# Row 13 lists the colours of faction-swappable parts (banners, guard uniforms, lamp posts, door paint)
# for each possible town owner; the game swaps these when a town changes hands.
OWNER_SLOTS = ["primary","primary_dark","secondary","trim_metal","cloth_light","banner_field","banner_charge","lamp_glow",
               "door_paint","awning","sash","shield_face","seal","reserved_13","reserved_14","reserved_15"]
OWNERS = {
 "contested": ["#7d7f78","#3e3f3b","#b5a888","#8a8a82","#d8c8a6","#6d6862","#e6dfcc","#ffb35a","#5a3d2b","#8c7a5b","#7d7f78","#9a917f","#5c4a3a","#808080","#808080","#808080"],
 "compact":   ["#3f5aa8","#2e2a5c","#ece6d6","#c9a54a","#efe4c8","#2e2a5c","#c9a54a","#7fd4ff","#3a2550","#8fa6d6","#d9b357","#ece6d6","#8e2f2a","#808080","#808080","#808080"],
 "combine":   ["#a3301f","#2a2523","#8c7f55","#b8873a","#b5a888","#a3301f","#1d1c1c","#ffc46a","#3a3f45","#d4a52a","#a3301f","#4d5257","#2a2523","#808080","#808080","#808080"],
 "meridian":  ["#4f8f7f","#2e4c50","#e6dfcc","#a86a45","#d2d8d4","#4a5a5e","#e6dfcc","#ffb35a","#2e4c50","#cdb47a","#4f8f7f","#a9b1b3","#7a4f3a","#808080","#808080","#808080"],
}
# Per-swatch roughness / metal overrides: (row, col): (rough, metal)
ORM_OVERRIDE = {(7,2):(0.3,1),(7,12):(0.85,0.6),(7,14):(0.7,1),(7,4):(0.35,1),(9,8):(0.6,0),(9,9):(0.6,0),(9,10):(0.4,0),
                (5,8):(0.5,0),(8,10):(0.6,0),(11,2):(0.45,1),(11,3):(0.5,1),(11,11):(0.5,1),(10,5):(0.4,1),(10,10):(0.4,1),
                (12,3):(0.5,1),(12,4):(0.45,1),(12,14):(0.45,1),(6,7):(0.5,0.8),(6,8):(0.6,0.7)}
OWNER_ORM = {3:(0.45,1)}

def hexrgb(h): h=h.lstrip('#'); return tuple(int(h[i:i+2],16) for i in (0,2,4))

def build():
    os.makedirs(OUT, exist_ok=True)
    meta = {"cell_px": CELL, "grid": GRID, "owner_row": OWNER_ROW, "glow_row": GLOW_ROW, "rows": []}
    alb = Image.new("RGB",(CELL*GRID,)*2)
    def fill(img,r,c,rgb): img.paste(rgb,(c*CELL,r*CELL,(c+1)*CELL,(r+1)*CELL))
    for r,(family,cells,rough,metal) in enumerate(ROWS):
        if cells is None:
            cells = list(zip(OWNER_SLOTS, OWNERS["contested"]))
        row = {"row": r, "family": family, "cells": []}
        for c,(name,hx) in enumerate(cells):
            fill(alb,r,c,hexrgb(hx))
            ro,me = ORM_OVERRIDE.get((r,c), OWNER_ORM.get(c,(rough,metal)) if r==OWNER_ROW else (rough,metal))
            row["cells"].append({"col":c,"name":name,"hex":hx,"roughness":ro,"metallic":me})
        meta["rows"].append(row)
    meta["owners"] = {k: dict(zip(OWNER_SLOTS,v)) for k,v in OWNERS.items()}
    alb.save(os.path.join(OUT,"harrowmere_swatches.png"))
    with open(os.path.join(OUT,"palette.json"),"w") as f: json.dump(meta,f,indent=1)
    print("wrote", OUT)

if __name__ == "__main__": build()
