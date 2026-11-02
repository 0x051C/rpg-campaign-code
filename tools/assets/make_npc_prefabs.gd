extends SceneTree

## Makes a character prefab (CharacterModel) for every townsperson built from the modular parts
## (make_npcs.sh -> assets/characters/modular/npcs/<name>.glb): the model, an AnimationPlayer with the
## baked KayKit clips for its body (bake_modular_animations.gd), the game's clip names mapped onto
## them, and a hair color.
##
##   godot --headless --path . --script res://tools/assets/make_npc_prefabs.gd
##
## Writes scenes/characters/townsfolk/<name>.tscn (a CharacterModel holding the model as "Model"),
## rewriting any that exist: they hold nothing else.

const MODELS := "res://assets/characters/modular/npcs/"
const ANIMATIONS := "res://assets/characters/modular/animations/"
const OUT := "res://scenes/characters/townsfolk/"

## Name -> [body, hair color, attack clip]. The texture's grey is multiplied by the color.
const PEOPLE := {
	"corwin": ["male", Color(0.95, 0.92, 0.88), "Melee_1H_Attack_Chop"],  # gone grey early
	"brann": ["male", Color(0.85, 0.42, 0.2), "Melee_Unarmed_Attack_Punch_A"],  # red, as innkeepers are
	"mags": ["female", Color(0.42, 0.28, 0.18), "Melee_Unarmed_Attack_Punch_A"],
	"jory": ["male", Color(1.0, 0.82, 0.5), "Melee_1H_Attack_Chop"],
	"bede": ["male", Color(0.22, 0.2, 0.2), "Ranged_Magic_Shoot"],
	"fenn": ["male", Color(0.5, 0.36, 0.24), "Melee_1H_Attack_Stab"],
	"hob": ["male", Color(0.55, 0.52, 0.5), "Ranged_Bow_Release"],
	"pedlar": ["female", Color(0.75, 0.3, 0.16), "Melee_1H_Attack_Stab"],
	"warden": ["male", Color(0.2, 0.18, 0.17), "Melee_2H_Attack_Chop"],
	"pitmaster": ["male", Color(0.4, 0.3, 0.22), "Melee_Unarmed_Attack_Punch_A"],
	"villager_man": ["male", Color(0.45, 0.32, 0.2), "Melee_Unarmed_Attack_Punch_A"],
	"villager_woman": ["female", Color(1.0, 0.85, 0.55), "Melee_Unarmed_Attack_Punch_A"],
	"villager_girl": ["female", Color(0.3, 0.2, 0.14), "Melee_Unarmed_Attack_Kick"],
}


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	var made := 0
	for person: String in PEOPLE:
		var path := MODELS + person + ".glb"
		if not ResourceLoader.exists(path):
			print("no model for ", person, " (run tools/assets/make_npcs.sh)")
			continue
		var body: String = PEOPLE[person][0]
		var root := Node3D.new()
		root.name = person.to_pascal_case()
		root.set_script(load("res://scripts/rts/character_model.gd"))
		var model := (load(path) as PackedScene).instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
		model.name = &"Model"
		root.add_child(model)
		model.owner = root  # an instance of the .glb: its insides stay in the .glb
		var clips: Dictionary[StringName, StringName] = {
			UnitAnimations.IDLE: &"Idle_A",
			&"move/Running_A": &"Running_A",
			&"general/Death_A": &"Death_A Death_B",
			&"general/Throw": StringName(PEOPLE[person][2]),
			&"general/Use_Item": &"Use_Item",
			&"general/Interact": &"Interact",
		}
		root.set(&"clips", clips)
		var tints: Dictionary[String, Color] = {"Hair_": PEOPLE[person][1], "Eyebrows": PEOPLE[person][1]}
		root.set(&"tints", tints)
		var player := AnimationPlayer.new()
		player.name = &"AnimationPlayer"
		root.add_child(player)
		player.owner = root
		player.root_node = ^"../Model"  # the baked tracks name Armature/Skeleton3D, inside the model
		player.add_animation_library(&"", load(ANIMATIONS + body + ".res"))
		var packed := PackedScene.new()
		var error := packed.pack(root)
		if error == OK:
			error = ResourceSaver.save(packed, OUT + person + ".tscn")
		print("%s (%s): %s" % [person, body, error_string(error)])
		made += 1 if error == OK else 0
		root.free()
	print("%d prefabs in %s" % [made, OUT])
	quit()
