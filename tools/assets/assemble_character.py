"""Puts a modular character together in Blender: an outfit, a head, hairstyles, all on one skeleton.

The Quaternius parts share the same 65-bone skeleton but each file brings its own copy; Godot would
need every copy animated. This keeps the first part's armature, moves every other part's meshes onto
it, drops the other armatures and writes one model.

    blender -b --factory-startup --python tools/assets/assemble_character.py -- <out.gltf> <part>...

Parts are .glb or .gltf files (the outfit first). The output is glTF with separate files; pack it
with gltf_to_glb.py (make_npcs.sh does both).
"""

import os
import sys

import bpy

args = sys.argv[sys.argv.index("--") + 1:]
out, parts = args[0], args[1:]
bpy.ops.wm.read_factory_settings(use_empty=True)
armature = None
for part in parts:
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=part)
    added = [o for o in bpy.data.objects if o not in before]
    rig = next(o for o in added if o.type == "ARMATURE")
    if armature is None:
        armature = rig
        armature.name = "Armature"
        continue
    for obj in added:
        if obj.type != "MESH":
            continue
        world = obj.matrix_world.copy()
        obj.parent = armature
        obj.matrix_world = world
        for modifier in obj.modifiers:
            if modifier.type == "ARMATURE":
                modifier.object = armature
    for obj in added:
        if obj.type != "MESH":
            bpy.data.objects.remove(obj, do_unlink=True)
os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
bpy.ops.export_scene.gltf(filepath=out, export_format="GLTF_SEPARATE", export_animations=False)
print("wrote", out)
