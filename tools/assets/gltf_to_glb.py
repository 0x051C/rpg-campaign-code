"""Packs .gltf files (JSON + .bin) into .glb, keeping their textures outside in one shared folder.

Asset packs ship glTF with every model pointing at the same few texture atlases (Quaternius' village
kit: one wood atlas for 136 models). Embedding them would give Godot a copy per model; instead each
.glb holds its geometry and refers to `<textures>/<image>` next to it, and the images are copied there
once.

    python3 -I tools/assets/gltf_to_glb.py <out dir> <file.gltf or folder>... [--textures textures]

Run it with -I on downloaded packs (they're untrusted data; this only reads them).
"""

import json
import os
import shutil
import struct
import sys


def pack(gltf_path: str, out_dir: str, textures: str) -> str:
    with open(gltf_path, "rb") as f:
        doc = json.loads(f.read())
    base = os.path.dirname(gltf_path)
    # All buffers (normally one .bin) become the GLB's single binary chunk.
    blob = bytearray()
    offsets = []
    for buffer in doc.get("buffers", []):
        uri = buffer.get("uri", "")
        if uri.startswith("data:"):
            raise ValueError(f"{gltf_path}: embedded data URIs aren't handled")
        offsets.append(len(blob))
        with open(os.path.join(base, uri), "rb") as f:
            data = f.read()
        blob += data
        blob += b"\0" * (-len(blob) % 4)
    for view in doc.get("bufferViews", []):
        view["byteOffset"] = view.get("byteOffset", 0) + offsets[view.get("buffer", 0)]
        view["buffer"] = 0
    doc["buffers"] = [{"byteLength": len(blob)}] if blob else []
    # Images stay files, shared: copied once into the textures folder.
    os.makedirs(os.path.join(out_dir, textures), exist_ok=True)
    for image in doc.get("images", []):
        uri = image.get("uri")
        if not uri or uri.startswith("data:"):
            continue
        source = os.path.join(base, uri)
        if not os.path.exists(source) and uri.endswith("_png.png"):
            source = os.path.join(base, uri[:-len("_png.png")] + ".png")  # an export naming slip in some packs
        if not os.path.exists(source):
            print(f"  {os.path.basename(gltf_path)}: missing image {uri}, left as is", file=sys.stderr)
            continue
        name = os.path.basename(source)
        target = os.path.join(out_dir, textures, name)
        if not os.path.exists(target):
            shutil.copyfile(source, target)
        image["uri"] = f"{textures}/{name}"
    text = json.dumps(doc, separators=(",", ":")).encode("utf-8")
    text += b" " * (-len(text) % 4)
    chunks = struct.pack("<II", len(text), 0x4E4F534A) + text
    if blob:
        chunks += struct.pack("<II", len(blob), 0x004E4942) + bytes(blob)
    out = os.path.join(out_dir, os.path.splitext(os.path.basename(gltf_path))[0] + ".glb")
    with open(out, "wb") as f:
        f.write(struct.pack("<III", 0x46546C67, 2, 12 + len(chunks)) + chunks)
    return out


def main() -> None:
    args = sys.argv[1:]
    textures = "textures"
    if "--textures" in args:
        i = args.index("--textures")
        textures = args[i + 1]
        del args[i:i + 2]
    if len(args) < 2:
        sys.exit(__doc__)
    out_dir, sources = args[0], args[1:]
    os.makedirs(out_dir, exist_ok=True)
    files = []
    for source in sources:
        if os.path.isdir(source):
            files += sorted(os.path.join(source, n) for n in os.listdir(source) if n.endswith(".gltf"))
        else:
            files.append(source)
    for path in files:
        print(pack(path, out_dir, textures))
    print(f"{len(files)} packed into {out_dir}")


if __name__ == "__main__":
    main()
