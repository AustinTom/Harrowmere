# Builds the tiny reference models in tests/fixtures/assets with Blender,
# exported through harrowmere_export.py, so the tests cover the real
# Blender -> glTF -> Godot path. They also show a correctly set up file.
#
#   blender -b --factory-startup --python tools/blender/make_test_fixtures.py
#
# (or, with the bpy module: python tools/blender/make_test_fixtures.py)

import math
import os
import sys

import bpy

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import harrowmere_export as hx  # noqa: E402

OUT = os.path.normpath(os.path.join(HERE, "..", "..", "tests", "fixtures"))


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def box(name, size, loc, color):
    bpy.ops.mesh.primitive_cube_add(size=1, location=loc)
    ob = bpy.context.active_object
    ob.name = name
    ob.scale = size
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    mat = bpy.data.materials.new(name + "_mat")
    mat.diffuse_color = (*color, 1)
    if bpy.app.version < (5, 0, 0):
        mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF") if mat.node_tree else None
    if bsdf:
        bsdf.inputs["Base Color"].default_value = (*color, 1)
    ob.data.materials.append(mat)
    return ob


def key_pose(arm, action_name, frames):
    """frames: list of (frame, {bone: (rx, ry, rz) degrees})."""
    act = bpy.data.actions.new(action_name)
    act.use_fake_user = True
    arm.animation_data_create()
    arm.animation_data.action = act
    for f, pose in frames:
        for bname, rot in pose.items():
            pb = arm.pose.bones[bname]
            pb.rotation_mode = "XYZ"
            pb.rotation_euler = [math.radians(r) for r in rot]
            pb.keyframe_insert("rotation_euler", frame=f)
    return act


def mannequin():
    reset()
    # Armature: root at the feet, spine up the middle, right arm out to the side.
    bpy.ops.object.armature_add(location=(0, 0, 0))
    arm = bpy.context.active_object
    arm.name = "Armature"
    bpy.ops.object.mode_set(mode="EDIT")
    eb = arm.data.edit_bones
    root = eb[0]
    root.name = "root"
    root.head, root.tail = (0, 0, 0), (0, 0, 0.9)
    spine = eb.new("spine")
    spine.head, spine.tail, spine.parent = (0, 0, 0.9), (0, 0, 1.45), root
    hand = eb.new("hand.R")
    # Character's right is -X when it faces you (-Y) in Front view.
    hand.head, hand.tail, hand.parent = (-0.3, 0, 1.3), (-0.3, 0, 0.9), spine
    bpy.ops.object.mode_set(mode="OBJECT")

    parts = [
        box("legs", (0.36, 0.22, 0.9), (0, 0, 0.45), (0.25, 0.22, 0.2)),
        box("torso", (0.46, 0.26, 0.55), (0, 0, 1.175), (0.3, 0.45, 0.7)),
        box("head", (0.24, 0.24, 0.26), (0, 0, 1.6), (0.9, 0.78, 0.66)),
        box("nose", (0.06, 0.08, 0.06), (0, -0.14, 1.6), (0.9, 0.6, 0.5)),  # shows the facing
        box("arm_r", (0.1, 0.1, 0.5), (-0.3, 0, 1.1), (0.3, 0.45, 0.7)),
    ]
    groups = {"legs": "root", "torso": "spine", "head": "spine", "nose": "spine", "arm_r": "hand.R"}
    for p in parts:
        vg = p.vertex_groups.new(name=groups[p.name])
        vg.add(list(range(len(p.data.vertices))), 1.0, "REPLACE")
    bpy.ops.object.select_all(action="DESELECT")
    for p in parts:
        p.select_set(True)
    bpy.context.view_layer.objects.active = parts[1]
    bpy.ops.object.join()
    body = bpy.context.active_object
    body.name = "body"
    body.parent = arm
    mod = body.modifiers.new("Armature", "ARMATURE")
    mod.object = arm

    sock = bpy.data.objects.new("socket_hand_r", None)
    bpy.context.scene.collection.objects.link(sock)
    sock.parent = arm
    sock.parent_type = "BONE"
    sock.parent_bone = "hand.R"
    # Bone-parented children sit at the bone's tail; put the socket in the palm
    # with the empty's axes matching the character (-Y forward, Z up).
    sock.matrix_world = arm.matrix_world @ __import__("mathutils").Matrix.Translation((-0.3, 0, 0.9))

    key_pose(arm, "idle", [(1, {"spine": (0, 0, 0)}), (20, {"spine": (3, 0, 0)}), (40, {"spine": (0, 0, 0)})])
    key_pose(arm, "walk", [(1, {"hand.R": (-25, 0, 0)}), (12, {"hand.R": (25, 0, 0)}), (24, {"hand.R": (-25, 0, 0)})])
    key_pose(arm, "attack_melee", [(1, {"hand.R": (0, 0, 0)}), (6, {"hand.R": (-80, 0, 0)}), (14, {"hand.R": (40, 0, 0)}), (20, {"hand.R": (0, 0, 0)})])
    key_pose(arm, "Armature|death", [(1, {"root": (0, 0, 0)}), (15, {"root": (85, 0, 0)})])
    for pb in arm.pose.bones:
        pb.rotation_euler = (0, 0, 0)
    arm.animation_data.action = bpy.data.actions["idle"]
    if hasattr(arm.animation_data, "action_slot") and bpy.data.actions["idle"].slots:
        arm.animation_data.action_slot = bpy.data.actions["idle"].slots[0]

    for lvl, msg in hx.check("characters", "mannequin"):
        print(" ", lvl, msg)
    print(hx.export("characters", "mannequin", OUT))


def sword():
    reset()
    # Grip at the origin, blade pointing toward you in Front view (-Y).
    box("grip", (0.04, 0.16, 0.04), (0, 0.02, 0), (0.35, 0.22, 0.1))
    box("guard", (0.2, 0.04, 0.04), (0, -0.08, 0), (0.6, 0.6, 0.6))
    box("blade", (0.05, 0.7, 0.02), (0, -0.45, 0), (0.85, 0.88, 0.9))
    for lvl, msg in hx.check("items", "fen_hookblade"):
        print(" ", lvl, msg)
    print(hx.export("items", "fen_hookblade", OUT))


def house():
    reset()
    # 4 x 3 tiles: X is width, Y is depth. Door on the front (-Y) face.
    box("walls", (3.9, 2.9, 1.8), (0, 0, 0.9), (0.6, 0.55, 0.45))
    box("roof", (4.2, 3.2, 0.5), (0, 0, 2.05), (0.45, 0.25, 0.2))
    box("door", (0.6, 0.05, 1.1), (0, -1.47, 0.55), (0.3, 0.2, 0.15))
    for lvl, msg in hx.check("structures", "house_4x3"):
        print(" ", lvl, msg)
    print(hx.export("structures", "house_4x3", OUT))


if __name__ == "__main__":
    mannequin()
    sword()
    house()
