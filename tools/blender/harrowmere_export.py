# Harrowmere Export: a Blender add-on that checks a model against the
# Harrowmere art rules and exports it as .glb to the right folder in the
# Godot project, with the right settings. See docs/art_pipeline.md.
#
# Install: Edit > Preferences > Add-ons > (dropdown) Install from Disk,
# pick this file, tick it, and set "Harrowmere project folder" in its
# preferences. The panel is in the 3D view sidebar (N), tab "Harrowmere".
#
# Command line (no UI):
#   blender -b iska.blend --python tools/blender/harrowmere_export.py -- \
#       --kind characters --id iska --project ~/Harrowmere
#
# Works with Blender 4.2 and newer.

bl_info = {
    "name": "Harrowmere Export",
    "author": "Harrowmere",
    "version": (1, 0, 0),
    "blender": (4, 2, 0),
    "location": "3D View > Sidebar > Harrowmere",
    "description": "Check and export models for the Harrowmere Godot project",
    "category": "Import-Export",
}

import os
import re
import sys

import bpy
from mathutils import Vector

KINDS = [
    ("characters", "Character", "A person or creature. Faces you in Front view, feet on the ground at the origin"),
    ("items", "Item", "A weapon or held item. Origin at the grip, pointing toward you in Front view"),
    ("structures", "Structure", "A building or prop. Origin at the centre of its footprint, on the ground"),
    ("animations", "Animation set", "Only an armature and its actions, shared by every character on that rig"),
]

# The animation names the game knows. Others are exported too and can be
# mapped in data/models.json.
CANON_ANIMS = ["idle", "walk", "run", "attack_melee", "attack_ranged", "cast", "hit", "death", "talk"]
REQUIRED_ANIMS = ["idle", "walk"]
HAND_SOCKET = "socket_hand_r"

# Rough low-poly budgets (triangles). Warnings only.
TRI_BUDGET = {"characters": 25000, "items": 4000, "structures": 60000, "animations": 0}  # upper ends of the art style budgets
# Sensible heights in metres (1 Blender unit = 1 m = 1 tile).
HEIGHT_RANGE = {"characters": (0.5, 3.5), "items": (0.05, 3.0), "structures": (0.1, 30.0)}
ID_RE = re.compile(r"^[a-z0-9]+(_[a-z0-9]+)*(_\d+x\d+)?$")


def _norm_anim(name):
    n = name.split("|")[-1].strip().lower().replace(" ", "_").replace("-", "_")
    return n[:-5] if n.endswith("_loop") else n


def _collection_objects(coll):
    return list(coll.all_objects) if coll is not None else list(bpy.context.scene.objects)


def _world_bounds(objs, depsgraph):
    lo = Vector((1e9, 1e9, 1e9))
    hi = Vector((-1e9, -1e9, -1e9))
    tris = 0
    found = False
    for ob in objs:
        if ob.type != "MESH" or ob.hide_render:
            continue
        ev = ob.evaluated_get(depsgraph)
        me = ev.to_mesh()
        try:
            me.calc_loop_triangles()
            tris += len(me.loop_triangles)
            mw = ev.matrix_world
            for v in me.vertices:
                p = mw @ v.co
                lo.x, lo.y, lo.z = min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z)
                hi.x, hi.y, hi.z = max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z)
                found = True
        finally:
            ev.to_mesh_clear()
    return (lo, hi, tris) if found else (None, None, tris)


def _actions_for(objs):
    """Actions that will be exported for the armatures in objs."""
    arms = [o for o in objs if o.type == "ARMATURE"]
    if not arms:
        return []
    names = set()
    for act in bpy.data.actions:
        if act.users == 0 and not act.use_fake_user:
            continue
        names.add(act.name)
    return sorted(names)


def check(kind, asset_id, coll=None):
    """Returns a list of (level, message). level is ERROR, WARN or OK."""
    out = []
    objs = _collection_objects(coll)

    if not asset_id:
        out.append(("ERROR", "Set an asset id (lowercase_with_underscores, e.g. iska or house_4x3)."))
    elif not ID_RE.match(asset_id):
        out.append(("WARN", f"Id '{asset_id}' should be lowercase_with_underscores so the game finds it by name."))

    meshes = [o for o in objs if o.type == "MESH"]
    if kind != "animations" and not meshes:
        out.append(("ERROR", "No mesh objects to export in this collection."))

    for ob in objs:
        if ob.type in {"MESH", "ARMATURE"}:
            s = ob.scale
            if abs(s.x - 1) > 1e-3 or abs(s.y - 1) > 1e-3 or abs(s.z - 1) > 1e-3:
                out.append(("WARN", f"'{ob.name}' has unapplied scale {tuple(round(v, 3) for v in s)}. Apply it (Ctrl+A > Scale)."))
        if ob.type in {"CAMERA", "LIGHT"}:
            out.append(("OK", f"'{ob.name}' ({ob.type.lower()}) is skipped on export."))

    # Measure in rest pose, whatever frame or action is showing.
    arms_all = [o for o in objs if o.type == "ARMATURE"]
    old_pose = [(a, a.data.pose_position) for a in arms_all]
    for a in arms_all:
        a.data.pose_position = "REST"
    bpy.context.view_layer.update()
    try:
        lo, hi, tris = _world_bounds(objs, bpy.context.evaluated_depsgraph_get())
    finally:
        for a, pp in old_pose:
            a.data.pose_position = pp
        bpy.context.view_layer.update()
    if lo is not None and kind in HEIGHT_RANGE:
        size = hi - lo
        h = size.z if kind != "items" else max(size.x, size.y, size.z)
        hmin, hmax = HEIGHT_RANGE[kind]
        if not (hmin <= h <= hmax):
            what = "Longest side" if kind == "items" else "Height"
            out.append(("WARN", f"{what} is {h:.2f} m, expected {hmin} to {hmax} m. 1 unit = 1 m = 1 tile."))
        else:
            out.append(("OK", f"Size {size.x:.2f} x {size.y:.2f} x {size.z:.2f} m (W x D x H)."))
        if kind in ("characters", "structures"):
            if abs(lo.z) > 0.05:
                out.append(("WARN", f"Lowest point is at Z={lo.z:.2f}. Feet / floor should sit on Z=0."))
            cx, cy = (lo.x + hi.x) / 2, (lo.y + hi.y) / 2
            tol = 0.3 if kind == "characters" else 0.25
            if abs(cx) > tol or abs(cy) > tol:
                out.append(("WARN", f"Model is centred at ({cx:.2f}, {cy:.2f}). Centre it on the origin."))
        if kind == "structures":
            m = re.search(r"_(\d+)x(\d+)$", asset_id or "")
            if m:
                fw, fd = int(m.group(1)), int(m.group(2))
                if abs(size.x - fw) > 0.6 or abs(size.y - fd) > 0.6:
                    out.append(("WARN", f"Footprint is {size.x:.1f} x {size.y:.1f} m but the id says {fw}x{fd} tiles (X by Y)."))
    budget = TRI_BUDGET.get(kind, 0)
    if budget and tris > budget:
        out.append(("WARN", f"{tris} triangles, over the {budget} low-poly budget for {kind}."))
    elif tris:
        out.append(("OK", f"{tris} triangles."))

    if kind in ("characters", "animations"):
        arms = [o for o in objs if o.type == "ARMATURE"]
        if not arms:
            if kind == "animations":
                out.append(("ERROR", "An animation set needs an armature."))
            else:
                out.append(("WARN", "No armature: the character will be static (no animations)."))
        else:
            acts = {_norm_anim(a): a for a in _actions_for(objs)}
            for req in REQUIRED_ANIMS:
                if req not in acts:
                    out.append(("WARN", f"No '{req}' action. Name actions: {', '.join(CANON_ANIMS)}."))
            known = [a for a in acts if a in CANON_ANIMS]
            other = [acts[a] for a in acts if a not in CANON_ANIMS]
            if known:
                out.append(("OK", "Actions: " + ", ".join(sorted(known))))
            if other:
                out.append(("WARN", "Actions the game won't use unless mapped in data/models.json: " + ", ".join(other)))
        if kind == "characters":
            sock = [o for o in objs if o.name.lower().replace(".", "_") == HAND_SOCKET]
            if not sock:
                out.append(("WARN", f"No '{HAND_SOCKET}' empty. Add one parented to the right hand bone so weapons attach."))
            else:
                out.append(("OK", f"Weapon socket '{sock[0].name}' found."))
    return out


def export_path(project_dir, kind, asset_id):
    leaf = asset_id.split("/")[-1]
    return os.path.join(os.path.expanduser(project_dir), "assets", kind, asset_id, leaf + ".glb")


def export(kind, asset_id, project_dir, coll=None):
    path = export_path(project_dir, kind, asset_id)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    kwargs = dict(
        filepath=path,
        export_format="GLB",
        export_yup=True,
        export_apply=True,
        export_cameras=False,
        export_lights=False,
        export_extras=True,
        export_animations=kind in ("characters", "animations"),
        export_animation_mode="ACTIONS",
        export_force_sampling=True,
        export_vertex_color="ACTIVE",  # keep vertex-colour palettes (Blender 4.2+)
    )
    view_layer = bpy.context.view_layer
    old_active = view_layer.active_layer_collection
    if coll is not None:
        lc = _find_layer_collection(view_layer.layer_collection, coll)
        if lc is not None:
            view_layer.active_layer_collection = lc
            kwargs["use_active_collection"] = True
            kwargs["use_active_collection_with_nested"] = True
    # Pass only the options this Blender version knows.
    known = {p.identifier for p in bpy.ops.export_scene.gltf.get_rna_type().properties}
    kwargs = {k: v for k, v in kwargs.items() if k in known}
    try:
        bpy.ops.export_scene.gltf(**kwargs)
    finally:
        view_layer.active_layer_collection = old_active
    return path


def _find_layer_collection(lc, coll):
    if lc.collection == coll:
        return lc
    for child in lc.children:
        r = _find_layer_collection(child, coll)
        if r is not None:
            return r
    return None


# ---------------------------------------------------------------- UI

def _prefs(context):
    addon = context.preferences.addons.get(__name__)
    return addon.preferences if addon else None


class HarrowmerePrefs(bpy.types.AddonPreferences):
    bl_idname = __name__
    project_dir: bpy.props.StringProperty(name="Harrowmere project folder", subtype="DIR_PATH",
                                          description="The folder that holds project.godot")

    def draw(self, context):
        self.layout.prop(self, "project_dir")


class HM_OT_check(bpy.types.Operator):
    bl_idname = "harrowmere.check"
    bl_label = "Check"
    bl_description = "Check the active collection against the Harrowmere art rules"

    def execute(self, context):
        sc = context.scene
        res = check(sc.hm_kind, sc.hm_id.strip(), context.collection if context.collection != sc.collection else None)
        sc.hm_report = "\n".join(f"{lvl}: {msg}" for lvl, msg in res)
        errs = sum(1 for l, _ in res if l == "ERROR")
        warns = sum(1 for l, _ in res if l == "WARN")
        self.report({"ERROR" if errs else ("WARNING" if warns else "INFO")}, f"{errs} errors, {warns} warnings")
        return {"FINISHED"}


class HM_OT_export(bpy.types.Operator):
    bl_idname = "harrowmere.export"
    bl_label = "Export to Harrowmere"
    bl_description = "Check, then export the active collection as .glb into the project's assets folder"

    def execute(self, context):
        sc = context.scene
        prefs = _prefs(context)
        project = (prefs.project_dir if prefs else "") or sc.hm_project
        if not project or not os.path.exists(os.path.join(os.path.expanduser(project), "project.godot")):
            self.report({"ERROR"}, "Set the Harrowmere project folder (the one with project.godot) in the add-on preferences.")
            return {"CANCELLED"}
        coll = context.collection if context.collection != sc.collection else None
        res = check(sc.hm_kind, sc.hm_id.strip(), coll)
        sc.hm_report = "\n".join(f"{lvl}: {msg}" for lvl, msg in res)
        if any(l == "ERROR" for l, _ in res):
            self.report({"ERROR"}, "Fix the errors first (see the panel).")
            return {"CANCELLED"}
        path = export(sc.hm_kind, sc.hm_id.strip(), project, coll)
        self.report({"INFO"}, "Exported " + path)
        return {"FINISHED"}


class HM_PT_panel(bpy.types.Panel):
    bl_label = "Harrowmere"
    bl_space_type = "VIEW_3D"
    bl_region_type = "UI"
    bl_category = "Harrowmere"

    def draw(self, context):
        sc = context.scene
        col = self.layout.column()
        col.label(text="Exports the active collection")
        col.prop(sc, "hm_kind", text="Kind")
        col.prop(sc, "hm_id", text="Id")
        if not (_prefs(context) and _prefs(context).project_dir):
            col.prop(sc, "hm_project", text="Project")
        row = col.row()
        row.operator("harrowmere.check")
        row.operator("harrowmere.export", icon="EXPORT")
        for line in sc.hm_report.splitlines():
            icon = {"ERROR": "ERROR", "WARN": "INFO", "OK": "CHECKMARK"}.get(line.split(":")[0], "DOT")
            col.label(text=line.split(": ", 1)[-1], icon=icon)


CLASSES = (HarrowmerePrefs, HM_OT_check, HM_OT_export, HM_PT_panel)


def register():
    for c in CLASSES:
        bpy.utils.register_class(c)
    bpy.types.Scene.hm_kind = bpy.props.EnumProperty(items=KINDS, name="Kind", default="characters")
    bpy.types.Scene.hm_id = bpy.props.StringProperty(name="Id", description="Must match the id in the game data, e.g. iska, fen_hookblade, house_4x3")
    bpy.types.Scene.hm_project = bpy.props.StringProperty(name="Project", subtype="DIR_PATH")
    bpy.types.Scene.hm_report = bpy.props.StringProperty()


def unregister():
    for c in reversed(CLASSES):
        bpy.utils.unregister_class(c)
    for p in ("hm_kind", "hm_id", "hm_project", "hm_report"):
        delattr(bpy.types.Scene, p)


# ---------------------------------------------------------------- CLI

def _cli(argv):
    import argparse
    ap = argparse.ArgumentParser(prog="harrowmere_export")
    ap.add_argument("--kind", required=True, choices=[k[0] for k in KINDS])
    ap.add_argument("--id", required=True)
    ap.add_argument("--project", required=True)
    ap.add_argument("--collection", default="", help="Export only this collection")
    ap.add_argument("--check-only", action="store_true")
    a = ap.parse_args(argv)
    coll = bpy.data.collections.get(a.collection) if a.collection else None
    res = check(a.kind, a.id, coll)
    for lvl, msg in res:
        print(f"{lvl}: {msg}")
    if any(l == "ERROR" for l, _ in res):
        sys.exit(1)
    if not a.check_only:
        print("Exported", export(a.kind, a.id, a.project, coll))


if __name__ == "__main__":
    if "--" in sys.argv:
        _cli(sys.argv[sys.argv.index("--") + 1:])
    else:
        register()
