# Art pipeline: getting your models into Harrowmere

Short version: model in Blender, export with the Harrowmere add-on, and the
game picks the model up by its id. Anything without a model keeps its
placeholder, so you can replace things one at a time.

## 1. One-time setup

1. **Blender add-on.** Edit > Preferences > Add-ons > dropdown (top right) >
   *Install from Disk*, pick `tools/blender/harrowmere_export.py`, tick it, and
   set **Harrowmere project folder** to the folder with `project.godot`.
   The panel is in the 3D view sidebar (N), tab **Harrowmere**. Works in Blender 4.2 and newer.
2. **Godot plugin.** It's already on (Project > Project Settings > Plugins >
   *Harrowmere Art Pipeline*). It loops idle/walk/run clips on import, strips
   cameras and lights that came from Blender, and adds
   **Project > Tools > Validate Harrowmere Art**.
3. **Your .blend files** go in `art-src/` (Godot ignores that folder). Only the
   exported `.glb` files go in `assets/`. If the repo gets big, put
   `art-src/` and `*.glb` on Git LFS; low-poly files are small, so it isn't needed yet.

## 2. The rules (all from the isometric camera)

| Rule | Why |
|---|---|
| **1 Blender unit = 1 metre = 1 tile.** A human is about 1.7 to 1.8 m. | The map grid is 1 m tiles. |
| **Apply scale** (Ctrl+A > Scale) on meshes and armatures. | Unapplied scale breaks rigs and sizes. |
| **Front faces you in Blender's Front view (Numpad 1)**, i.e. toward -Y. Same for characters, weapons and buildings. | The game turns characters to walk the right way; buildings show their front to the camera. |
| **Characters:** origin between the feet, feet on Z = 0. | Actors stand on the tile centre. |
| **Structures:** origin at the centre of the footprint, floor on Z = 0, footprint the size of its tiles (X = width, Y = depth). | Structures fill their tile rectangle from the area file. |
| **Items:** origin at the grip, pointing toward you in Front view. | It goes straight into the hand socket. |
| **Weapon socket:** an Empty named `socket_hand_r`, parented to the right hand bone (Bone parent), placed in the palm with the same axes as the character (-Y forward, Z up) in rest pose. | Held items attach there. Without it the game uses a bone called hand.R / hand_r / RightHand, then the hip. |
| **Triangle budget** (warnings only, the upper end of the art style budgets): characters 25,000, held items 4,000, structures 60,000. Landmarks may go higher; give them an entry and ignore the warning. | Towns are dense. The art style doc sets the target ranges (resident 8-12k, hero 15-25k, house 20-60k). |
| Ids are **lowercase_with_underscores** and match the game data. | That's how the game finds files without any config. |

Materials: anything glTF supports works (Principled BSDF, image textures,
vertex colours). The art style guide (docs/art/README.md) sets surfaces, texel
density, and the `owner_*` / `glow_*` material slot names the game will drive.
Keep textures next to the model or packed into the .glb.

The game's camera looks down from the south-east (+X, +Z in Godot), so the
front and right side of buildings face the player.

## 3. Where files go

The game looks for these paths. One folder per asset keeps textures next to their model.

| What | Path | Id comes from |
|---|---|---|
| A specific character | `assets/characters/<id>/<id>.glb` | the key in `data/actors.json`, e.g. `iska` |
| Default body for a race | `assets/characters/races/<race>.glb` | `race` in the actor template |
| Item / weapon | `assets/items/<id>/<id>.glb` | the key in `data/items.json`, e.g. `fen_hookblade` |
| Structure for one footprint | `assets/structures/<kind>_<W>x<D>/<kind>_<W>x<D>.glb` | `kind` and `rect` size in `data/areas/*.json`, e.g. `house_4x3` |
| Structure for any footprint | `assets/structures/<kind>/<kind>.glb` | `kind`, e.g. `well` |
| Shared animation set for a rig | `assets/animations/<rig>/<rig>.glb` | named in `data/models.json` |

A flat `assets/<kind>/<id>.glb` works too. `.gltf` and `.blend` are accepted, and
a Godot `.tscn` with the same name wins over the `.glb`, so you can make an
inherited scene to tweak materials or add nodes without re-exporting.

**What gets used, in order:** a `"model"` key on the data entry, then an entry in
`data/models.json`, then the path above, then (characters only) the race
default, and finally the placeholder. On start the game prints which things are
still placeholders.

## 4. Animations

Name Blender actions exactly like this and the game plays them:

| Name | Used when | If missing, uses |
|---|---|---|
| `idle` (loops) | standing | nothing |
| `walk` (loops) | moving a tile | `run` |
| `run` (loops) | not used yet | `walk` |
| `attack_melee` | melee attack | `attack` |
| `attack_ranged` | guns, bows | `shoot`, `attack`, `attack_melee` |
| `cast` | spells | `attack_ranged`, `attack`, `attack_melee` |
| `hit` | taking damage | nothing |
| `death` | dying (holds the last frame) | the placeholder's fall-over |
| `talk` (loops) | not used yet | `idle` |

Case doesn't matter, and `Armature|idle` or `idle-loop` also match. The hit
lands 40% into the attack clip (max 0.5 s); set `"hit_time"` in
`data/models.json` to change that. Give each action a Fake User (the shield
icon) so Blender keeps it when you save; the add-on exports every action.

**Sharing clips across many characters.** Put one armature with all its
actions in `assets/animations/humanoid/humanoid.glb`, then give characters that
use the same rig (same armature object name and bone names)
`"anim_library": "humanoid"` in `data/models.json`, or set it once for all
characters under `"defaults"`. Their own clips still win over the shared ones.

## 5. Daily workflow

1. Model in Blender, put everything for one asset in a collection, and click on that collection.
2. Harrowmere panel: choose **Kind**, type the **Id**, click **Check**, and fix anything red.
3. Click **Export to Harrowmere**. It writes `assets/<kind>/<id>/<id>.glb` with the right settings
   (glTF binary, +Y up, modifiers applied, actions exported, no cameras or lights).
4. Switch to Godot; it re-imports automatically. Open `tools/art/model_viewer.tscn` and press **F6**
   to see it under the game's camera and lighting, next to the placeholder for scale
   (Left/Right model, Up/Down animation, Q/E turn; the red arrow is "forward").
5. Press **F5** to see it in town.

From a terminal (no Blender UI):

```sh
blender -b art-src/iska.blend --python tools/blender/harrowmere_export.py -- \
    --kind characters --id iska --project ~/Harrowmere
godot --headless res://tools/art/validate_art.tscn   # exits 1 if anything is broken
```

## 6. `data/models.json`: only for exceptions

Nothing needs an entry if it follows the paths above. Use it to share or adjust:

```json
{
  "defaults": {"characters": {"anim_library": "humanoid"}},
  "characters": {
    "osk_brannel": {"path": "res://assets/characters/dwarf_warden/dwarf_warden.glb"},
    "hesta_lowe": {"scale": 0.95, "anims": {"attack_melee": "Staff_Swing"}, "hit_time": 0.3}
  },
  "race_defaults": {"human": ["human_a", "human_b", "human_c"], "elf": "elf_a"},
  "items": {"rusty_hookblade": {"path": "res://assets/items/fen_hookblade/fen_hookblade.glb"}},
  "structures": {"house": {"path": "res://assets/structures/house_small/house_small.glb"}},
  "animations": {}
}
```

Every entry can set `path`, `scale` (number or `[x, y, z]`), `rotate_y` (degrees;
characters default to 180, which turns a Front-view model to walk forward),
`offset` (`[x, y, z]` metres), `anims` (game name to clip name), `anim_library`,
`hit_time` and `hand_socket` (if your socket Empty has another name).

`race_defaults` covers generated residents: each one gets one of the listed
models, always the same one for the same character. Data entries can also point at a
model directly: `"model": "human_b"` in an actor template or item, or in an
area structure, along with `"facing": 90/180/270` to turn it (90 and 270
only fit square footprints).

Structure effects stay in the game: a `shrine` gets its light and a
`pumphouse` its chimney smoke. Put Empties named `marker_light` /
`marker_smoke` in the model to place them.

## 7. Checking your work

* **Project > Tools > Validate Harrowmere Art** (or the headless command above)
  checks every model in `assets/`: size, feet/floor at 0, centred, footprint
  matches the name, triangle budget, required clips, weapon socket, stray
  cameras or lights, unapplied scale. It then lists how many actors, items and
  structures still use placeholders.
* `tests/fixtures/assets/` has three tiny reference models (a rigged mannequin, a
  sword, a 4x3 house) built by `tools/blender/make_test_fixtures.py` through the add-on.
  Open them in the model viewer with `-- --root=res://tests/fixtures/assets` to see a
  correct setup. The unit tests use them.

## 8. Troubleshooting

| Symptom | Fix |
|---|---|
| Character walks backwards | It doesn't face -Y in Blender. Turn it, or set `"rotate_y": 0` for it. |
| Floats or sinks | Origin isn't at the feet, or the feet aren't at Z = 0. |
| Weapon at the hip, not in the hand | No `socket_hand_r` Empty and no bone called hand.R / hand_r / RightHand. |
| Weapon points the wrong way | The socket Empty's axes don't match the character's in rest pose; rotate the Empty, not the weapon. |
| Clip doesn't play | Check the name against section 4, or map it with `"anims"`. Check the action has a Fake User. |
| Walk plays once then stops | Re-import (the plugin loops it), or name it `walk_loop`. |
| Model doesn't show at all | Check the path and id against section 3, then run the validator; its last lines list what still uses a placeholder. |
