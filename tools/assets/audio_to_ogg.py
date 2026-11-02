"""Converts the project's .mp3 and .wav sounds to Ogg Vorbis and points everything that used them at the .ogg.

    python3 -I tools/assets/audio_to_ogg.py <project dir> <backup dir> [folder under the project]...

Each sound is encoded with ffmpeg (libvorbis, quality 6: transparent for voice and effects; an mp3
loses a little more as it's encoded twice). The original and its .import file move to <backup dir>
under the same relative path, so nothing is lost. References in .tres, .tscn, .gd and .cfg files
are rewritten (res://...mp3 -> res://...ogg), dropping the old file's uid so Godot finds the new one
by path.
"""

import os
import re
import shutil
import subprocess
import sys

KINDS = (".mp3", ".wav")
TEXT = (".tres", ".tscn", ".gd", ".cfg", ".godot")


def main() -> None:
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    project, backup = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
    roots = [os.path.join(project, f) for f in sys.argv[3:]] or [project]
    renamed = {}
    for root in roots:
        for folder, dirs, files in os.walk(root):
            dirs[:] = [d for d in dirs if d != ".godot"]
            for name in files:
                if not name.lower().endswith(KINDS):
                    continue
                source = os.path.join(folder, name)
                target = os.path.splitext(source)[0] + ".ogg"
                if os.path.exists(target):
                    print("exists, skipped:", target)
                    continue
                subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-i", source, "-c:a", "libvorbis",
                        "-q:a", "6", target], check=True)
                relative = os.path.relpath(source, project)
                for moved in (source, source + ".import"):
                    if os.path.exists(moved):
                        keep = os.path.join(backup, os.path.relpath(moved, project))
                        os.makedirs(os.path.dirname(keep), exist_ok=True)
                        shutil.move(moved, keep)
                renamed["res://" + relative] = "res://" + os.path.splitext(relative)[0] + ".ogg"
    print(f"{len(renamed)} converted")
    # Point the references at the new files.
    changed = 0
    for folder, dirs, files in os.walk(project):
        dirs[:] = [d for d in dirs if d not in (".godot", ".git")]
        for name in files:
            if not name.endswith(TEXT):
                continue
            path = os.path.join(folder, name)
            with open(path, encoding="utf-8", errors="surrogateescape") as f:
                text = f.read()
            new = text
            for old, ogg in renamed.items():
                if old not in new:
                    continue
                # an ext_resource's uid belonged to the old file
                new = re.sub(r'(\[ext_resource [^\]]*?) uid="[^"]*"([^\]]*path="' + re.escape(old) + '")', r"\1\2", new)
                new = new.replace(old, ogg)
            if new != text:
                with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
                    f.write(new)
                changed += 1
                print("references updated:", os.path.relpath(path, project))
    print(f"{changed} files referred to them")


if __name__ == "__main__":
    main()
