extends ItemPower

## Tidecaller's Pearl: Maren's Pearl of the Deep shines {extra} seconds longer and draws the entranced
## in {pull} times as hard.


func on_cast(_unit: Unit, ability: AbilityDefinition, spell: SpellCast) -> void:
	var pearl: Node = spell.data.get("pearl")
	if ability.id() != &"maren_pearl_of_the_deep" or not is_instance_valid(pearl):
		return
	pearl.call(&"extend", value(&"extra"))
	pearl.set(&"pull", value(&"pull"))
