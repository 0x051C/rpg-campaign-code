#!/usr/bin/env python3
"""Converts Heroes of Newerth / NoH units (a skinned K2 .model, its .clip animations, .material and PNG) to glTF.

    python3 -I tools/noh/k2_unit_to_gltf.py <HoN game folder> <output folder> <unit folder> [...]

e.g.  python3 -I tools/noh/k2_unit_to_gltf.py "/path/noh/Heroes of Newerth/game" assets/characters/hon \
          npcs/n_skeleton npcs/n_ogre

Each unit folder's model.mdf becomes <output>/<folder name>/<folder name>.glb, its texture next to it: the
high-detail model, skinned to its bones (up to 4 weights a vertex), and every anim the .mdf lists as a glTF
animation of the same name (idle, walk_1, attack_1, death_1...), at the .mdf's fps; looping anims get the wrap
back to their first frame (a death "loops" on its last frame in K2: it plays once here). Clips the .mdf reuses
under another name come along (stun_1 = the idle's first frame); the ones a unit here never plays don't
(SKIPPED_ANIMS: the portrait, flying, the lane creeps' gib and deny deaths...). Prefabs: make_noh_prefabs.py.

The formats follow NoH's reader (src/k2/c_k2model.cpp, c_clip.cpp, c_skeleton.cpp):
  bones  parent index, invBase and base (3 axis vectors, then the position), the name's length, the name;
  links  per vertex: the weight count, the weights, the bone indices (lnk1/lnk3), or one bone each (lnk2);
  clips  "CLIP", a head (version, motions, frames), then per bone and key kind a "bmtn": bone index, kind
         (x y z pitch roll yaw visibility scalex scaley scalez), key count, bone name; one key or one a frame.
A bone's pose is relative to its parent: translate, then rotate (yaw about Z, of pitch about X, of roll about Y,
in degrees), then scale its axes; posed in the model by its parents, onto the skin through invBase. K2 turns
the vertices 180 degrees about Z when loading, and the root's yaw with them: the same as turning the posed model,
so it's all done here in the file's space and turned once, at the end: made Y up (48 units a meter), facing +Z
like the game's other models (unit.gd). The files face -Y; K2's turn would face them -Z, so it's left out
(the props' converter keeps it: there the maps' placements expect it).
"""
import math
import os
import shutil
import struct
import sys
import xml.etree.ElementTree as ET

sys.dont_write_bytecode = True  # no __pycache__ left in tools/
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from k2_to_gltf import UNITS_PER_METER, find_texture, read_blocks, read_material, resolve  # noqa: E402

KEY_KINDS = ["x", "y", "z", "pitch", "roll", "yaw", "visibility", "scalex", "scaley", "scalez"]
MAX_WEIGHTS = 4
SKIPPED_ANIMS = {"portrait", "fly_1", "defeat_1", "victory_1", "death_gib_1", "death_deny_1", "bored_1"}
SCALE = 1.0 / UNITS_PER_METER


# --- matrices: 4x4 row-major lists, column vectors (K2's axis[i] is column i) ---

def matrix43(values):
    """K2's matrix43_t (axis[0..2], pos) as a 4x4."""
    a = values
    return [[a[0], a[3], a[6], a[9]],
            [a[1], a[4], a[7], a[10]],
            [a[2], a[5], a[8], a[11]],
            [0.0, 0.0, 0.0, 1.0]]


def multiply(a, b):
    return [[sum(a[r][k] * b[k][c] for k in range(4)) for c in range(4)] for r in range(4)]


def inverse(m):
    """An affine 4x4's inverse (its 3x3 part may scale)."""
    a = [row[:3] for row in m[:3]]
    det = (a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1]) - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0])
           + a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0]))
    inv = [[(a[(c + 1) % 3][(r + 1) % 3] * a[(c + 2) % 3][(r + 2) % 3]
             - a[(c + 1) % 3][(r + 2) % 3] * a[(c + 2) % 3][(r + 1) % 3]) / det for c in range(3)] for r in range(3)]
    t = [m[0][3], m[1][3], m[2][3]]
    return [inv[0] + [-sum(inv[0][k] * t[k] for k in range(3))],
            inv[1] + [-sum(inv[1][k] * t[k] for k in range(3))],
            inv[2] + [-sum(inv[2][k] * t[k] for k in range(3))],
            [0.0, 0.0, 0.0, 1.0]]


# The turn into glTF's space: Z up -> Y up, the file's front (-Y) to +Z: (x, y, z) -> (x, z, -y).
TURN = [[1.0, 0.0, 0.0, 0.0], [0.0, 0.0, 1.0, 0.0], [0.0, -1.0, 0.0, 0.0], [0.0, 0.0, 0.0, 1.0]]


def convert_matrix(m):
    """`m` in glTF's space: turned (TURN m TURN^-1), its translation in meters."""
    turned = multiply(multiply(TURN, m), [list(row) for row in zip(*TURN)])
    for r in range(3):
        turned[r][3] *= SCALE
    return turned


def convert_point(p):
    return (p[0] * SCALE, p[2] * SCALE, -p[1] * SCALE)


def convert_direction(n):
    return (n[0], n[2], -n[1])


def convert_quat(q):
    """(x, y, z, w) turned like convert_matrix: the axis turns, the angle stays."""
    return (q[0], q[2], -q[1], q[3])


def decompose(m):
    """translation, rotation (x, y, z, w), scale of an affine 4x4 without shear."""
    columns = [[m[r][c] for r in range(3)] for c in range(3)]
    scale = [math.sqrt(sum(v * v for v in column)) or 1.0 for column in columns]
    det = (columns[0][0] * (columns[1][1] * columns[2][2] - columns[2][1] * columns[1][2])
           - columns[1][0] * (columns[0][1] * columns[2][2] - columns[2][1] * columns[0][2])
           + columns[2][0] * (columns[0][1] * columns[1][2] - columns[1][1] * columns[0][2]))
    if det < 0:
        scale[0] = -scale[0]
    r = [[columns[c][row] / scale[c] for c in range(3)] for row in range(3)]
    return [m[0][3], m[1][3], m[2][3]], matrix_to_quat(r), scale


def matrix_to_quat(r):
    trace = r[0][0] + r[1][1] + r[2][2]
    if trace > 0:
        s = math.sqrt(trace + 1.0) * 2
        q = ((r[2][1] - r[1][2]) / s, (r[0][2] - r[2][0]) / s, (r[1][0] - r[0][1]) / s, 0.25 * s)
    elif r[0][0] > r[1][1] and r[0][0] > r[2][2]:
        s = math.sqrt(1.0 + r[0][0] - r[1][1] - r[2][2]) * 2
        q = (0.25 * s, (r[0][1] + r[1][0]) / s, (r[0][2] + r[2][0]) / s, (r[2][1] - r[1][2]) / s)
    elif r[1][1] > r[2][2]:
        s = math.sqrt(1.0 + r[1][1] - r[0][0] - r[2][2]) * 2
        q = ((r[0][1] + r[1][0]) / s, 0.25 * s, (r[1][2] + r[2][1]) / s, (r[0][2] - r[2][0]) / s)
    else:
        s = math.sqrt(1.0 + r[2][2] - r[0][0] - r[1][1]) * 2
        q = ((r[0][2] + r[2][0]) / s, (r[1][2] + r[2][1]) / s, 0.25 * s, (r[1][0] - r[0][1]) / s)
    length = math.sqrt(sum(v * v for v in q))
    return tuple(v / length for v in q)


def euler_to_quat(pitch, roll, yaw):
    """K2's M_EulerToQuat: Rz(yaw) Rx(pitch) Ry(roll), degrees; (x, y, z, w)."""
    sr, cr = math.sin(math.radians(roll) * 0.5), math.cos(math.radians(roll) * 0.5)
    sp, cp = math.sin(math.radians(pitch) * 0.5), math.cos(math.radians(pitch) * 0.5)
    sy, cy = math.sin(math.radians(yaw) * 0.5), math.cos(math.radians(yaw) * 0.5)
    return (cy * sp * cr - sy * cp * sr, cy * cp * sr + sy * sp * cr, cy * sp * sr + sy * cp * cr,
            cy * cp * cr - sy * sp * sr)


# --- reading ---

def read_unit_model(path):
    """{bones: [{name, parent, inv_base}], meshes: [{name, material, positions, normals, uvs, indices, links}]}"""
    bones, meshes = [], {}
    for name, block in read_blocks(open(path, "rb").read()):
        if name == "bone":
            at = 0
            while at < len(block):
                parent = struct.unpack_from("<i", block, at)[0]
                inv_base = matrix43(struct.unpack_from("<12f", block, at + 4))
                name_len = block[at + 100]
                bone_name = block[at + 101:at + 101 + name_len].decode("latin-1")
                bones.append({"name": bone_name, "parent": parent, "inv_base": inv_base})
                at += 101 + name_len + 1
        elif name == "mesh":
            index, mode, count = struct.unpack_from("<iii", block, 0)
            bone_link = struct.unpack_from("<i", block, 36)[0]
            name_len, shader_len = block[40], block[41]
            meshes[index] = {"name": block[42:42 + name_len].decode("latin-1"), "mode": mode, "count": count,
                             "bone_link": bone_link,
                             "material": block[43 + name_len:43 + name_len + shader_len].decode("latin-1")}
        elif name in ("vrts", "nrml"):
            index = struct.unpack_from("<i", block, 0)[0]
            mesh = meshes[index]
            values = struct.unpack_from("<%df" % (mesh["count"] * 3), block, 4)
            mesh["positions" if name == "vrts" else "normals"] = [values[i:i + 3] for i in range(0, len(values), 3)]
        elif name == "texc":
            index, channel = struct.unpack_from("<ii", block, 0)
            if channel == 0:
                mesh = meshes[index]
                values = struct.unpack_from("<%df" % (mesh["count"] * 2), block, 8)
                mesh["uvs"] = [(values[i], 1.0 - values[i + 1]) for i in range(0, len(values), 2)]
        elif name == "face":
            index, faces, size = struct.unpack_from("<iib", block, 0)
            fmt = {1: "B", 2: "H", 4: "I"}[size]
            meshes[index]["indices"] = list(struct.unpack_from("<%d%s" % (faces * 3, fmt), block, 9))
        elif name in ("lnk1", "lnk3"):
            index, count = struct.unpack_from("<ii", block, 0)
            links, at = [], 8
            for _ in range(count):
                n = struct.unpack_from("<i", block, at)[0]
                weights = struct.unpack_from("<%df" % n, block, at + 4)
                bone_ids = struct.unpack_from("<%di" % n, block, at + 4 + 4 * n)
                at += 4 + 8 * n
                merged = {}
                for weight, bone in zip(weights, bone_ids):
                    merged[bone] = merged.get(bone, 0.0) + weight
                links.append(sorted(merged.items(), key=lambda pair: -pair[1])[:MAX_WEIGHTS])
            meshes[index]["links"] = links
        elif name == "lnk2":
            index, count = struct.unpack_from("<ii", block, 0)
            meshes[index]["links"] = [[(bone, 1.0)] for bone in struct.unpack_from("<%di" % count, block, 8)]
    visible = []
    for index in sorted(meshes):
        mesh = meshes[index]
        if any(tag in mesh["name"] for tag in ("_invis", "_trisurf")) or "positions" not in mesh or "indices" not in mesh:
            continue
        if "links" not in mesh:  # rigid, on its bone (or the root)
            mesh["links"] = [[(max(mesh["bone_link"], 0), 1.0)]] * mesh["count"]
        visible.append(mesh)
    return {"bones": bones, "meshes": visible}


def read_clip(path):
    """(frames, {bone name: {kind: [keys]}})"""
    data = open(path, "rb").read()
    if data[:4] != b"CLIP":
        raise ValueError("not a K2 clip: " + path)
    motions, frames, at = {}, 0, 4
    while at + 8 <= len(data):
        name = data[at:at + 4].decode("ascii", "replace")
        length = struct.unpack_from("<I", data, at + 4)[0]
        block = data[at + 8:at + 8 + length]
        at += 8 + length
        if name == "head":
            frames = struct.unpack_from("<iii", block, 0)[2]
        elif name == "bmtn":
            _bone, kind, count = struct.unpack_from("<iii", block, 0)
            name_len = block[12]
            bone_name = block[13:13 + name_len].decode("latin-1")
            keys_at = 13 + name_len + 1
            if KEY_KINDS[kind] == "visibility":
                keys = list(block[keys_at:keys_at + count])
            else:
                keys = list(struct.unpack_from("<%df" % count, block, keys_at))
            motions.setdefault(bone_name, {})[KEY_KINDS[kind]] = keys
    return frames, motions


def read_anims(mdf):
    """[{name, clip, fps, loop}] in the .mdf's order."""
    anims = []
    for anim in ET.parse(mdf).getroot().iter("anim"):
        name = anim.get("name")
        if name in SKIPPED_ANIMS or not anim.get("clip"):
            continue
        # loopbackframe -1: it holds its last frame (the deaths), which a clip played once does too
        loop = anim.get("loop") == "true" and anim.get("loopbackframe") != "-1" and not name.startswith("death")
        anims.append({"name": name, "clip": anim.get("clip"), "fps": float(anim.get("fps") or 30),
                      "loop": loop, "frames": int(anim.get("numframes") or 0)})
    return anims


# --- posing ---

def bone_pose(motion, frame, rest):
    """A bone's local transform at `frame` (file space): its keys, or its rest pose when the clip lacks it."""
    if not motion or not all(motion.get(k) for k in ("pitch", "roll", "yaw")):
        return rest

    def key(kind, default):
        keys = motion.get(kind)
        return keys[frame % len(keys)] if keys else default

    translation = (key("x", 0.0), key("y", 0.0), key("z", 0.0))
    rotation = euler_to_quat(key("pitch", 0.0), key("roll", 0.0), key("yaw", 0.0))
    scale = (key("scalex", 1.0), key("scaley", 1.0), key("scalez", 1.0))
    return translation, rotation, scale


def to_gltf_pose(pose):
    translation, rotation, scale = pose
    return convert_point(translation), convert_quat(rotation), (scale[0], scale[2], scale[1])


# --- writing ---

class Writer:
    def __init__(self):
        self.buffer = bytearray()
        self.views, self.accessors = [], []

    def add(self, data, component, kind, count, target=None, minmax=None):
        while len(self.buffer) % 4:
            self.buffer.append(0)
        view = {"buffer": 0, "byteOffset": len(self.buffer), "byteLength": len(data)}
        if target:
            view["target"] = target
        self.views.append(view)
        self.buffer.extend(data)
        accessor = {"bufferView": len(self.views) - 1, "componentType": component, "count": count, "type": kind}
        if minmax:
            accessor["min"], accessor["max"] = minmax
        self.accessors.append(accessor)
        return len(self.accessors) - 1

    def floats(self, values, kind, width, target=None, minmax=False):
        flat = [c for v in values for c in v] if width > 1 else list(values)
        extent = None
        if minmax:
            columns = list(zip(*values)) if width > 1 else [values]
            extent = ([min(c) for c in columns], [max(c) for c in columns])
        return self.add(struct.pack("<%df" % len(flat), *flat), 5126, kind, len(values), target, extent)


def write_unit_glb(model, anims, materials, path):
    import json
    writer = Writer()
    bones = model["bones"]
    base = [inverse(bone["inv_base"]) for bone in bones]  # each bone in the model, at rest (file space)
    rest = []  # each bone relative to its parent, at rest (file space)
    for i, bone in enumerate(bones):
        local = base[i] if bone["parent"] < 0 else multiply(inverse(base[bone["parent"]]), base[i])
        rest.append(decompose(local))

    root_name = os.path.splitext(os.path.basename(path))[0]
    nodes = [{"name": root_name, "children": []}]
    joint_nodes = []
    for i, bone in enumerate(bones):
        translation, rotation, scale = to_gltf_pose(rest[i])
        node = {"name": bone["name"], "translation": list(translation), "rotation": list(rotation)}
        if any(abs(s - 1.0) > 1e-4 for s in scale):
            node["scale"] = list(scale)
        joint_nodes.append(len(nodes))
        nodes.append(node)
    for i, bone in enumerate(bones):
        parent = nodes[0] if bone["parent"] < 0 else nodes[joint_nodes[bone["parent"]]]
        parent.setdefault("children", []).append(joint_nodes[i])

    inverse_binds = []
    for bone in bones:
        m = convert_matrix(bone["inv_base"])
        inverse_binds.append([m[r][c] for c in range(4) for r in range(4)])  # column-major
    skin = {"joints": joint_nodes, "skeleton": joint_nodes[next(i for i, b in enumerate(bones) if b["parent"] < 0)],
            "inverseBindMatrices": writer.add(struct.pack("<%df" % (16 * len(bones)), *[v for m in inverse_binds for v in m]),
                                              5126, "MAT4", len(bones))}

    primitives = []
    for mesh in model["meshes"]:
        positions = [convert_point(p) for p in mesh["positions"]]
        attributes = {"POSITION": writer.floats(positions, "VEC3", 3, 34962, True)}
        if "normals" in mesh:
            attributes["NORMAL"] = writer.floats([convert_direction(n) for n in mesh["normals"]], "VEC3", 3, 34962)
        if "uvs" in mesh:
            attributes["TEXCOORD_0"] = writer.floats(mesh["uvs"], "VEC2", 2, 34962)
        joints, weights = [], []
        for link in mesh["links"]:
            total = sum(w for _, w in link) or 1.0
            padded = list(link) + [(0, 0.0)] * (MAX_WEIGHTS - len(link))
            joints.extend(bone for bone, _ in padded)
            weights.append([w / total for _, w in padded])
        attributes["JOINTS_0"] = writer.add(struct.pack("<%dH" % len(joints), *joints), 5123, "VEC4", len(mesh["links"]), 34962)
        attributes["WEIGHTS_0"] = writer.floats(weights, "VEC4", 4, 34962)
        primitive = {"attributes": attributes,
                     "indices": writer.add(struct.pack("<%dI" % len(mesh["indices"]), *mesh["indices"]), 5125, "SCALAR",
                                           len(mesh["indices"]), 34963)}
        if mesh["material"] in materials:
            primitive["material"] = materials[mesh["material"]]["index"]
        primitives.append(primitive)
    nodes.append({"name": "Body", "mesh": 0, "skin": 0})
    nodes[0]["children"].append(len(nodes) - 1)

    animations = []
    for anim in anims:
        frames, motions = anim["frames_total"], anim["motions"]
        count = anim["frames"] or frames
        sequence = list(range(count)) + ([0] if anim["loop"] and count > 1 else [])
        times = writer.floats([i / anim["fps"] for i in range(len(sequence))], "SCALAR", 1, minmax=True)
        single = None  # the one key of a bone that holds still
        samplers, channels = [], []
        for i, bone in enumerate(bones):
            poses = [to_gltf_pose(bone_pose(motions.get(bone["name"]), f, rest[i])) for f in sequence]
            for slot, path_name, kind, width in ((0, "translation", "VEC3", 3), (1, "rotation", "VEC4", 4), (2, "scale", "VEC3", 3)):
                values = [pose[slot] for pose in poses]
                if slot == 1:  # keep neighbouring keys in the same hemisphere, so they blend the short way
                    for k in range(1, len(values)):
                        if sum(a * b for a, b in zip(values[k - 1], values[k])) < 0:
                            values[k] = tuple(-v for v in values[k])
                if all(max(abs(a - b) for a, b in zip(values[0], v)) < 1e-6 for v in values):
                    if slot == 2 and all(abs(s - 1.0) < 1e-6 for s in values[0]):
                        continue  # unscaled throughout: nothing to say
                    if single is None:
                        single = writer.floats([0.0], "SCALAR", 1, minmax=True)
                    samplers.append({"input": single, "output": writer.floats(values[:1], kind, width)})
                else:
                    samplers.append({"input": times, "output": writer.floats(values, kind, width)})
                channels.append({"sampler": len(samplers) - 1, "target": {"node": joint_nodes[i], "path": path_name}})
        animations.append({"name": anim["name"], "samplers": samplers, "channels": channels})

    gltf_materials, images, textures = [], [], []
    for name, info in sorted(materials.items(), key=lambda item: item[1]["index"]):
        material = {"name": name, "pbrMetallicRoughness": {"metallicFactor": 0.0, "roughnessFactor": 0.85}}
        if info.get("image"):
            if info["image"] not in images:
                images.append(info["image"])
                textures.append({"source": len(images) - 1})
            material["pbrMetallicRoughness"]["baseColorTexture"] = {"index": images.index(info["image"])}
        if info["alpha_test"]:
            material["alphaMode"], material["alphaCutoff"] = "MASK", 0.5
        if info["double_sided"]:
            material["doubleSided"] = True
        gltf_materials.append(material)

    gltf = {
        "asset": {"version": "2.0", "generator": "k2_unit_to_gltf.py"},
        "scene": 0, "scenes": [{"nodes": [0]}],
        "nodes": nodes,
        "meshes": [{"name": "Body", "primitives": primitives}],
        "skins": [skin],
        "animations": animations,
        "materials": gltf_materials,
        "buffers": [{"byteLength": len(writer.buffer)}],
        "bufferViews": writer.views, "accessors": writer.accessors,
    }
    if images:
        gltf["images"] = [{"uri": image} for image in images]
        gltf["textures"] = textures
    payload = json.dumps(gltf, separators=(",", ":")).encode()
    payload += b" " * ((4 - len(payload) % 4) % 4)
    buffer = writer.buffer
    while len(buffer) % 4:
        buffer.append(0)
    body = struct.pack("<I", len(payload)) + b"JSON" + payload + struct.pack("<I", len(buffer)) + b"BIN\x00" + bytes(buffer)
    with open(path, "wb") as out:
        out.write(b"glTF" + struct.pack("<II", 2, 12 + len(body)) + body)


def convert(game, folder, out_root):
    mdf = os.path.join(folder, "model.mdf")
    root = ET.parse(mdf).getroot()
    model = read_unit_model(resolve(os.path.join(folder, root.get("high") or root.get("file"))))
    if not model["meshes"] or not model["bones"]:
        return None
    name = os.path.basename(folder.rstrip("/"))
    out_folder = os.path.join(out_root, name)
    os.makedirs(out_folder, exist_ok=True)
    materials = {}
    for mesh in model["meshes"]:
        if mesh["material"] in materials:
            continue
        info = read_material(os.path.join(folder, mesh["material"] + ".material"))
        info["index"] = len(materials)
        source = find_texture(game, folder, info["texture"]) if info["texture"] else None
        if source:
            image = name + "_" + os.path.basename(source)  # one folder may hold several units' "color.png"
            shutil.copyfile(source, os.path.join(out_folder, image))
            info["image"] = image
        materials[mesh["material"]] = info
    anims = []
    for anim in read_anims(mdf):
        clip = resolve(os.path.join(folder, anim["clip"]))
        if not os.path.isfile(clip):
            continue
        anim["frames_total"], anim["motions"] = read_clip(clip)
        anims.append(anim)
    out_path = os.path.join(out_folder, name + ".glb")
    write_unit_glb(model, anims, materials, out_path)
    return out_path


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        sys.exit(1)
    game, output = sys.argv[1], sys.argv[2]
    for unit in sys.argv[3:]:
        folder = os.path.join(game, unit)
        try:
            print(convert(game, folder, output) or "skipped %s: no skinned model" % unit)
        except Exception as error:  # a malformed file shouldn't stop the batch
            print("skipped %s: %s" % (unit, error))


if __name__ == "__main__":
    main()
