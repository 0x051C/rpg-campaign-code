"""Cuts the head (with eyes and brows) out of a Universal Base Character's full body, for outfits.

The Modular Character Outfits bring their own arms, body, legs and feet; worn over the whole base body
they clip, so a character is an outfit + this head + a hairstyle. Keeps the faces of the body whose
vertices all hang mostly from the head or neck bones; the eye and brow meshes stay whole.

    blender -b --factory-startup --python tools/assets/cut_head.py -- <FullBody.gltf> <out.gltf>

The output is glTF with separate files; pack it with gltf_to_glb.py.
"""

import sys

import bmesh
import bpy

KEEP = {"Head", "neck_01"}

args = sys.argv[sys.argv.index("--") + 1:]
source, out = args[0], args[1]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=source)
for obj in bpy.data.objects:
    if obj.type != "MESH" or len(obj.data.vertices) < 2000:
        continue  # eyes and brows are small; the body is the big one
    names = {g.index: g.name for g in obj.vertex_groups}
    keep = set()
    for v in obj.data.vertices:
        if v.groups:
            top = max(v.groups, key=lambda g: g.weight)
            if names.get(top.group) in KEEP:
                keep.add(v.index)
    mesh = bmesh.new()
    mesh.from_mesh(obj.data)
    mesh.verts.ensure_lookup_table()
    gone = [f for f in mesh.faces if not all(v.index in keep for v in f.verts)]
    bmesh.ops.delete(mesh, geom=gone, context="FACES")
    loose = [v for v in mesh.verts if not v.link_faces]
    bmesh.ops.delete(mesh, geom=loose, context="VERTS")
    mesh.to_mesh(obj.data)
    mesh.free()
    obj.name = "HeadMesh"  # not "Head": that is a bone, and glTF importers keep node names unique
    print(f"{obj.name}: {len(obj.data.vertices)} vertices kept")
bpy.ops.export_scene.gltf(filepath=out, export_format="GLTF_SEPARATE", export_animations=False)
print("wrote", out)
