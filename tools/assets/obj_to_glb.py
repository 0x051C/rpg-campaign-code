"""Converts a folder of .obj models (with their .mtl colors) to .glb, one each, with Blender.

    blender -b --factory-startup --python tools/assets/obj_to_glb.py -- <obj folder> <out dir>

Quaternius' modular dungeon: flat colored materials, no textures; each model keeps its own name.
"""

import os
import sys

import bpy

args = sys.argv[sys.argv.index("--") + 1:]
source, out_dir = args[0], args[1]
os.makedirs(out_dir, exist_ok=True)
count = 0
for name in sorted(os.listdir(source)):
    if not name.lower().endswith(".obj"):
        continue
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.wm.obj_import(filepath=os.path.join(source, name))
    out = os.path.join(out_dir, os.path.splitext(name)[0] + ".glb")
    bpy.ops.export_scene.gltf(filepath=out, export_format="GLB", export_apply=True, export_yup=True)
    count += 1
    print("wrote", out)
print(f"{count} converted into {out_dir}")
