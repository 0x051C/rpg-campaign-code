#!/usr/bin/env python3
"""Converts Heroes of Newerth / NoH props (K2 .model + .mdf + .material + PNG textures) to glTF.

    python3 tools/noh/k2_to_gltf.py <HoN game folder> <output folder> [subfolder ...]

e.g.  python3 tools/noh/k2_to_gltf.py "/path/noh/Heroes of Newerth/game" assets/environment/hon \
          world/props world/cliffs world/river buildings

Every .mdf under the subfolders (default: world/props) becomes <output>/<subfolder path>/<name>.glb (without the
leading world/: world/props/x -> props/x), with its textures copied next to it. Static geometry only: the high-detail model, base color (and alpha test) from the
material's "color" phase; bones, animations, collision surfaces and normal maps are left out.

The K2 format follows NoH's reader (src/k2/c_k2model.cpp, c_k2model.h): "SMDL", then blocks of a 4-letter
name, a uint32 length and the data. Vertices are in model space, Z up, in K2 units (48 per meter, as this
game converts all of NoH's distances); K2 turns models 180 degrees around Z when loading them, so they face
the same way here.
"""
import json
import os
import re
import shutil
import struct
import sys
import xml.etree.ElementTree as ET

UNITS_PER_METER = 48.0
# K2's built-in textures ("$black" for tar): a plain color instead of an image
BUILT_IN_COLORS = {"$black": [0.02, 0.02, 0.02], "$white": [1.0, 1.0, 1.0], "$gray": [0.5, 0.5, 0.5], "$grey": [0.5, 0.5, 0.5]}


def resolve(path):
    """`path`, or the file whose path differs only in case: HoN was made on Windows, so its files
    say "/world/cliffs/Legion/color.tga" where the disk has world/cliffs/legion/color.png."""
    if os.path.exists(path):
        return path
    folder, name = os.path.split(path)
    if not folder or folder == path:
        return path
    folder = resolve(folder)
    if os.path.isdir(folder):
        for entry in os.listdir(folder):
            if entry.lower() == name.lower():
                return os.path.join(folder, entry)
    return os.path.join(folder, name)


def read_blocks(data):
    if data[:4] != b"SMDL":
        raise ValueError("not a K2 model")
    blocks, at = [], 4
    while at + 8 <= len(data):
        name = data[at:at + 4].decode("ascii", "replace")
        length = struct.unpack_from("<I", data, at + 4)[0]
        blocks.append((name, data[at + 8:at + 8 + length]))
        at += 8 + length
    return blocks


def read_model(path):
    """[{name, material, positions, normals, uvs, indices}] for the visible meshes."""
    meshes = {}
    for name, block in read_blocks(open(path, "rb").read()):
        if name == "mesh":
            index, mode, count = struct.unpack_from("<iii", block, 0)
            name_len, shader_len = block[40], block[41]
            mesh_name = block[42:42 + name_len].decode("latin-1")
            shader = block[43 + name_len:43 + name_len + shader_len].decode("latin-1")
            meshes[index] = {"name": mesh_name, "material": shader, "count": count}
        elif name in ("vrts", "nrml"):
            index = struct.unpack_from("<i", block, 0)[0]
            mesh = meshes[index]
            values = struct.unpack_from("<%df" % (mesh["count"] * 3), block, 4)
            # K2: rotate 180 degrees around Z (-x, -y), then Z up -> Y up: (x, y, z) -> (x, z, -y)
            points = [(-values[i], values[i + 2], values[i + 1]) for i in range(0, len(values), 3)]
            mesh["positions" if name == "vrts" else "normals"] = points
        elif name == "texc":
            index, channel = struct.unpack_from("<ii", block, 0)
            mesh = meshes[index]
            if channel == 0:
                values = struct.unpack_from("<%df" % (mesh["count"] * 2), block, 8)
                # K2 stores V bottom-up (OpenGL); glTF counts from the top
                mesh["uvs"] = [(values[i], 1.0 - values[i + 1]) for i in range(0, len(values), 2)]
        elif name == "face":
            index, faces, size = struct.unpack_from("<iib", block, 0)
            fmt = {1: "B", 2: "H", 4: "I"}[size]
            values = struct.unpack_from("<%d%s" % (faces * 3, fmt), block, 9)
            # Already counter-clockwise like glTF (checked against the stored normals)
            meshes[index]["indices"] = list(values)
    visible = []
    for index in sorted(meshes):
        mesh = meshes[index]
        if any(tag in mesh["name"] for tag in ("_invis", "_trisurf")) or "positions" not in mesh or "indices" not in mesh:
            continue
        visible.append(mesh)
    return visible


def read_material(path):
    """{texture, alpha_test, translucent, double_sided} from the .material's color phase."""
    info = {"texture": None, "alpha_test": False, "translucent": False, "double_sided": False}
    path = resolve(path)
    if not os.path.isfile(path):
        return info
    root = ET.parse(path).getroot()
    for phase in root.iter("phase"):
        if phase.get("name") != "color":
            continue
        info["alpha_test"] = phase.get("alphatest") == "true"
        info["translucent"] = phase.get("translucent") == "true"
        info["double_sided"] = phase.get("cull") == "CULL_NONE"
        for sampler in phase.iter("sampler"):
            if sampler.get("name") == "diffuse":
                texture = sampler.get("texture") or ""
                if texture.lower() in BUILT_IN_COLORS:
                    info["color"] = BUILT_IN_COLORS[texture.lower()]
                else:
                    info["texture"] = texture
    return info


def find_texture(game, folder, texture):
    """The file a material's texture name points at: relative to the material, or to the game folder when
    it starts with /; HoN ships .png files where materials say .tga."""
    base = os.path.join(game, texture.lstrip("/")) if texture.startswith("/") else os.path.join(folder, texture)
    stem = os.path.splitext(base)[0]
    for candidate in (base, stem + ".png", stem + ".jpg"):
        candidate = resolve(candidate)
        if os.path.isfile(candidate):
            return candidate
    return None


def write_glb(meshes, materials, textures, path):
    """One glTF node and mesh, a primitive per K2 mesh, materials by name."""
    buffer = bytearray()
    views, accessors = [], []

    def add(data, target, component, kind, count, minmax=None):
        while len(buffer) % 4:
            buffer.append(0)
        views.append({"buffer": 0, "byteOffset": len(buffer), "byteLength": len(data), "target": target})
        buffer.extend(data)
        accessor = {"bufferView": len(views) - 1, "componentType": component, "count": count, "type": kind}
        if minmax:
            accessor["min"], accessor["max"] = minmax
        accessors.append(accessor)
        return len(accessors) - 1

    primitives = []
    for mesh in meshes:
        positions = mesh["positions"]
        lo = [min(p[i] for p in positions) for i in range(3)]
        hi = [max(p[i] for p in positions) for i in range(3)]
        attributes = {"POSITION": add(struct.pack("<%df" % (len(positions) * 3), *[c for p in positions for c in p]),
                                      34962, 5126, "VEC3", len(positions), (lo, hi))}
        if "normals" in mesh:
            normals = mesh["normals"]
            attributes["NORMAL"] = add(struct.pack("<%df" % (len(normals) * 3), *[c for n in normals for c in n]),
                                       34962, 5126, "VEC3", len(normals))
        if "uvs" in mesh:
            uvs = mesh["uvs"]
            attributes["TEXCOORD_0"] = add(struct.pack("<%df" % (len(uvs) * 2), *[c for uv in uvs for c in uv]),
                                           34962, 5126, "VEC2", len(uvs))
        indices = mesh["indices"]
        primitive = {"attributes": attributes,
                     "indices": add(struct.pack("<%dI" % len(indices), *indices), 34963, 5125, "SCALAR", len(indices))}
        if mesh["material"] in materials:
            primitive["material"] = materials[mesh["material"]]["index"]
        primitives.append(primitive)

    gltf_materials, images, gltf_textures = [], [], []
    for name, info in sorted(materials.items(), key=lambda item: item[1]["index"]):
        material = {"name": name, "pbrMetallicRoughness": {"metallicFactor": 0.0, "roughnessFactor": 0.9}}
        if info.get("image"):
            if info["image"] not in images:
                images.append(info["image"])
                gltf_textures.append({"source": len(images) - 1})
            material["pbrMetallicRoughness"]["baseColorTexture"] = {"index": images.index(info["image"])}
        elif info.get("color"):
            material["pbrMetallicRoughness"]["baseColorFactor"] = info["color"] + [1.0]
        if info["alpha_test"]:
            material["alphaMode"], material["alphaCutoff"] = "MASK", 0.5
        elif info["translucent"]:
            material["alphaMode"] = "BLEND"
        if info["double_sided"]:
            material["doubleSided"] = True
        gltf_materials.append(material)

    name = os.path.splitext(os.path.basename(path))[0]
    gltf = {
        "asset": {"version": "2.0", "generator": "k2_to_gltf.py"},
        "scene": 0, "scenes": [{"nodes": [0]}],
        "nodes": [{"name": name, "mesh": 0, "scale": [1.0 / UNITS_PER_METER] * 3}],
        "meshes": [{"name": name, "primitives": primitives}],
        "materials": gltf_materials,
        "buffers": [{"byteLength": len(buffer)}],
        "bufferViews": views, "accessors": accessors,
    }
    if images:
        gltf["images"] = [{"uri": image} for image in images]
        gltf["textures"] = gltf_textures
    payload = json.dumps(gltf, separators=(",", ":")).encode()
    payload += b" " * ((4 - len(payload) % 4) % 4)
    while len(buffer) % 4:
        buffer.append(0)
    body = struct.pack("<I", len(payload)) + b"JSON" + payload + struct.pack("<I", len(buffer)) + b"BIN\x00" + bytes(buffer)
    with open(path, "wb") as out:
        out.write(b"glTF" + struct.pack("<II", 2, 12 + len(body)) + body)


def convert(game, mdf, out_folder):
    folder = os.path.dirname(mdf)
    root = ET.parse(mdf).getroot()
    model_file = root.get("high") or root.get("file")
    model_path = resolve(os.path.join(folder, model_file))
    meshes = read_model(model_path)
    if not meshes:
        return None
    materials = {}
    for mesh in meshes:
        name = mesh["material"]
        if name in materials:
            continue
        info = read_material(os.path.join(folder, name + ".material"))
        info["index"] = len(materials)
        source = find_texture(game, folder, info["texture"]) if info["texture"] else None
        if source:
            image = os.path.basename(source)
            os.makedirs(out_folder, exist_ok=True)
            shutil.copyfile(source, os.path.join(out_folder, image))
            info["image"] = image
        materials[name] = info
    stem = os.path.splitext(os.path.basename(mdf))[0]
    stem = re.sub(r"_high$", "", stem)
    name = os.path.basename(folder) if stem == "model" else stem
    os.makedirs(out_folder, exist_ok=True)
    out_path = os.path.join(out_folder, name + ".glb")
    write_glb(meshes, materials, None, out_path)
    return out_path


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    game, output = sys.argv[1], sys.argv[2]
    subfolders = sys.argv[3:] or ["world/props"]
    done, failed = 0, []
    for sub in subfolders:
        for dirpath, _, files in os.walk(os.path.join(game, sub)):
            for file in sorted(files):
                if not file.endswith(".mdf"):
                    continue
                mdf = os.path.join(dirpath, file)
                # world/props/x -> props/x, like the map importer (noh_map.gd) looks them up
                relative = re.sub(r"^world[/\\]", "", os.path.relpath(dirpath, game))
                try:
                    if convert(game, mdf, os.path.join(output, relative)):
                        done += 1
                except Exception as error:  # a malformed file shouldn't stop the batch
                    failed.append("%s: %s" % (os.path.relpath(mdf, game), error))
    print("converted %d models" % done)
    for line in failed:
        print("  skipped " + line)


if __name__ == "__main__":
    main()
