#!/bin/bash
# Builds the story's townsfolk from the modular character parts (assets/characters/modular):
# each line below is a character = an outfit + a head + hairstyles, merged onto one skeleton
# (assemble_character.py) and packed next to the shared textures (gltf_to_glb.py).
#
#   tools/assets/make_npcs.sh [name...]      all of them, or just these
#
# Then: tools/assets/bake_modular_animations.gd gives them the KayKit clips, and
# tools/assets/make_npc_prefabs.gd the prefabs (scenes/characters/townsfolk/<name>.tscn).
cd "$(dirname "$0")/../.." || exit 1
M=assets/characters/modular
WORK=${WORK:-/tmp/rpg_npcs}

# name            outfit                    head          hairstyles
RECIPES="
corwin           outfits/Male_Peasant      base/Head_Male    hair/Hair_SimpleParted hair/Hair_Beard
brann            outfits/Male_Peasant      base/Head_Male    hair/Hair_Buzzed hair/Hair_Beard
mags             outfits/Female_Peasant    base/Head_Female  hair/Hair_Buns
jory             outfits/Male_Peasant      base/Head_Male    hair/Hair_Long
bede             outfits/Male_Peasant      base/Head_Male    hair/Hair_Buzzed
fenn             outfits/Male_Peasant      base/Head_Male    hair/Hair_SimpleParted
hob              outfits/Male_Ranger       base/Head_Male    hair/Hair_Beard
pedlar           outfits/Female_Ranger     base/Head_Female  hair/Hair_Long
warden           outfits/Male_Ranger       base/Head_Male    hair/Hair_Buzzed hair/Hair_Beard
pitmaster        outfits/Male_Ranger       base/Head_Male    hair/Hair_Buzzed
villager_man     outfits/Male_Peasant      base/Head_Male    hair/Hair_SimpleParted
villager_woman   outfits/Female_Peasant    base/Head_Female  hair/Hair_Long
villager_girl    outfits/Female_Peasant    base/Head_Female  hair/Hair_BuzzedFemale
"

mkdir -p "$WORK" "$M/npcs"
echo "$RECIPES" | while read -r name parts; do
	[ -z "$name" ] && continue
	if [ $# -gt 0 ] && [[ ! " $* " =~ " $name " ]]; then continue; fi
	files=()
	for part in $parts; do files+=("$PWD/$M/$part.glb"); done
	blender -b --factory-startup --python tools/assets/assemble_character.py -- "$WORK/$name/$name.gltf" "${files[@]}" \
		2>&1 | grep -E '^wrote|Error' || exit 1
	python3 -I tools/assets/gltf_to_glb.py "$M/npcs" --textures ../textures "$WORK/$name/$name.gltf" | tail -1
done
