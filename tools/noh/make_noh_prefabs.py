#!/usr/bin/env python3
"""Character prefabs (CharacterModel scenes) for the HoN units k2_unit_to_gltf.py converted.

    python3 -I tools/noh/make_noh_prefabs.py <HoN game folder> [project folder]

For every assets/characters/hon/<unit>/<unit>.glb: scenes/characters/hon/<unit>.tscn, the model with
character_model.gd and its clips mapped to the game's (UnitAnimations.CLIPS): idle, walk_1 to run, death_1,
every attack_N as the attack's variants, the first ability (or the taunt, or the attack) as the cast. Sized
by the unit's own HoN scale (its .entity's preglobalscale) times SIZE, so they keep HoN's proportions to
each other, and a HoN skeleton stands like the KayKit one. Run again after converting more; it rewrites
the prefabs (they're generated: change this, not them).
"""
import json
import os
import re
import struct
import sys

SIZE = 0.5  ## of HoN's scale: its skeleton (2.0) stands 1.5 m, like KayKit's


def glb_animations(path):
    data = open(path, "rb").read()
    length = struct.unpack_from("<I", data, 12)[0]
    gltf = json.loads(data[20:20 + length])
    return [animation["name"] for animation in gltf.get("animations", [])]


def hon_scale(game, unit):
    folder = os.path.join(game, "npcs", unit)
    files = sorted(os.listdir(folder)) if os.path.isdir(folder) else []
    # its own entity first (kongor.entity, not the gadget or the states beside it)
    files.sort(key=lambda file: (os.path.splitext(file)[0] != unit, file))
    for file in files:
        if file.endswith(".entity") and not re.match(r"(gadget|affector|state)", file):
            match = re.search(r'preglobalscale="([0-9.]+)', open(os.path.join(folder, file), encoding="latin-1").read())
            if match:
                return float(match.group(1))
    return 2.0


def clips_for(anims):
    attacks = sorted(a for a in anims if re.fullmatch(r"attack_\d+", a))
    abilities = sorted(a for a in anims if re.fullmatch(r"ability_\d+", a))
    clips = {"general/Idle_A": "idle", "move/Running_A": "walk_1", "general/Death_A": "death_1"}
    if attacks:
        clips["general/Throw"] = " ".join(attacks)
    cast = abilities[0] if abilities else ("taunt_1" if "taunt_1" in anims else (attacks[0] if attacks else ""))
    if cast:
        clips["general/Use_Item"] = cast
    return {key: value for key, value in clips.items() if all(part in anims for part in value.split())}


def prefab(unit, anims, scale):
    node = "".join(part.capitalize() for part in re.sub(r"^n_", "", unit).split("_"))
    lines = [
        "[gd_scene format=3]",
        "",
        '[ext_resource type="PackedScene" path="res://assets/characters/hon/%s/%s.glb" id="1_model"]' % (unit, unit),
        '[ext_resource type="Script" path="res://scripts/rts/character_model.gd" id="2_script"]',
        "",
        '[node name="%s" instance=ExtResource("1_model")]' % node,
        'script = ExtResource("2_script")',
        "clips = Dictionary[StringName, StringName]({",
        ",\n".join('&"%s": &"%s"' % item for item in sorted(clips_for(anims).items())),
        "})",
        "",
        '[node name="%s" parent="."]' % unit,
        "transform = Transform3D(%s, 0, 0, 0, %s, 0, 0, 0, %s, 0, 0, 0)" % ((format(scale, "g"),) * 3),
        "",
    ]
    return "\n".join(lines)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    game = sys.argv[1]
    project = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
    models = os.path.join(project, "assets", "characters", "hon")
    out = os.path.join(project, "scenes", "characters", "hon")
    os.makedirs(out, exist_ok=True)
    for unit in sorted(os.listdir(models)):
        glb = os.path.join(models, unit, unit + ".glb")
        if not os.path.isfile(glb):
            continue
        scale = round(hon_scale(game, unit) * SIZE, 3)
        with open(os.path.join(out, unit + ".tscn"), "w") as file:
            file.write(prefab(unit, glb_animations(glb), scale))
        print("%-24s x%s" % (unit, scale))


if __name__ == "__main__":
    main()
