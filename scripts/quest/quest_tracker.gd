class_name QuestTracker
extends CanvasLayer

## The running quests and their current objectives, top right. The first Quest of a map
## adds one (ensure()); it lists every quest in the Quest group.

const NODE_NAME := &"QuestTracker"
const UPDATE_TIME := 0.25
const TITLE_COLOR := Color(1.0, 0.85, 0.4)

var _label := RichTextLabel.new()
var _timer := 0.0


## Adds the tracker to `quest`'s map once.
static func ensure(quest: Node) -> void:
	var map := quest.owner if quest.owner != null else quest.get_tree().current_scene
	if map == null or map.has_node(NodePath(NODE_NAME)):
		return
	var tracker := QuestTracker.new()
	tracker.name = NODE_NAME
	map.add_child(tracker)


func _ready() -> void:
	layer = 2
	_label.bbcode_enabled = true
	_label.fit_content = true
	_label.scroll_active = false
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_label.custom_minimum_size = Vector2(360, 0)
	_label.position = Vector2(-376, 16)
	_label.add_theme_constant_override(&"outline_size", 4)
	_label.add_theme_color_override(&"font_outline_color", Color(0, 0, 0, 0.8))
	add_child(_label)


func _process(delta: float) -> void:
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = UPDATE_TIME
	var lines := PackedStringArray()
	for node in get_tree().get_nodes_in_group(Quest.GROUP):
		var quest := node as Quest
		if quest == null or not quest.is_running():
			continue
		lines.append("[right][color=#%s]%s[/color]\n%s[/right]" % [TITLE_COLOR.to_html(false),
				quest.title if not quest.title.is_empty() else str(quest.name), quest.current.tracker_text()])
	_label.text = "\n".join(lines)
	_label.visible = not lines.is_empty()
