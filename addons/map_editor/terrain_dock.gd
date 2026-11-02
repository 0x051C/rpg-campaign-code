@tool
extends ScrollContainer

## The Map Editor's Terrain dock: brush tools, brush size and strength, the tile palette,
## hill generation, heightmap import/export, and a heightmap file the terrain follows (paint
## it in an image editor) for the edited scene's terrain.

const TerrainTools := preload("res://addons/map_editor/terrain_tools.gd")
const HINT := "Left mouse: apply · Ctrl: invert raise/lower, or pick the tile under the cursor when painting · Shift: smooth"

var tools: TerrainTools

var _body := VBoxContainer.new()
var _missing := VBoxContainer.new()
var _editing := VBoxContainer.new()
var _tool_buttons: Dictionary[int, Button] = {}
var _size := HSlider.new()
var _size_label := Label.new()
var _strength := HSlider.new()
var _strength_label := Label.new()
var _tiles := ItemList.new()
var _cells := SpinBox.new()
var _seed := SpinBox.new()
var _height := SpinBox.new()
var _feature := SpinBox.new()
var _octaves := SpinBox.new()
var _flat_center := SpinBox.new()
var _import_low := SpinBox.new()
var _import_high := SpinBox.new()
var _status := Label.new()
var _file_dialog: EditorFileDialog
var _exporting := false
var _link_dialog: EditorFileDialog
var _link_label := Label.new()
var _unlink_button: Button
var _range_button: Button


func _init() -> void:
	name = "Terrain"
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_body)
	_body.add_child(_missing)
	_body.add_child(_editing)

	# No terrain yet
	_missing.add_child(_label("This scene has no terrain."))
	_missing.add_child(_row("Size (m)", _spin(_cells, 16, 512, 16, 64)))
	_missing.add_child(_button("Add Terrain", _on_add))

	# Brushes
	var flow := HFlowContainer.new()
	var group := ButtonGroup.new()
	group.allow_unpress = true
	for value in TerrainTools.TOOL_NAMES:
		var button := Button.new()
		button.text = TerrainTools.TOOL_NAMES[value]
		button.toggle_mode = true
		button.button_group = group
		button.toggled.connect(_on_tool_toggled.bind(value))
		flow.add_child(button)
		_tool_buttons[value] = button
	_editing.add_child(_section("Brush"))
	_editing.add_child(flow)
	_slider(_size, 0.5, 40.0, 0.5, 4.0, _on_size_changed)
	_slider(_strength, 0.02, 1.0, 0.02, 0.5, _on_strength_changed)
	_editing.add_child(_row("Size", _size, _size_label))
	_editing.add_child(_row("Strength", _strength, _strength_label))
	var hint := _label(HINT)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_color_override(&"font_color", Color(1, 1, 1, 0.55))
	_editing.add_child(hint)

	# Tiles
	_editing.add_child(_section("Tiles"))
	_tiles.icon_mode = ItemList.ICON_MODE_TOP
	_tiles.fixed_icon_size = Vector2i(56, 56)
	_tiles.max_columns = 0
	_tiles.same_column_width = true
	_tiles.auto_height = true
	_tiles.item_selected.connect(_on_tile_selected)
	_editing.add_child(_tiles)

	# Generation
	_editing.add_child(_section("Generate Hills"))
	_editing.add_child(_row("Seed", _spin(_seed, 0, 99999, 1, 1)))
	_editing.add_child(_row("Height (m)", _spin(_height, 0.5, 100.0, 0.5, 6.0)))
	_editing.add_child(_row("Hill size (m)", _spin(_feature, 2.0, 500.0, 1.0, 24.0)))
	_editing.add_child(_row("Detail", _spin(_octaves, 1, 8, 1, 4)))
	_editing.add_child(_row("Flat middle", _spin(_flat_center, 0.0, 1.0, 0.05, 0.0)))
	_editing.add_child(_button("Generate (replaces heights)", _on_generate))

	# Heightmap files
	_editing.add_child(_section("Heightmap"))
	_editing.add_child(_row("Black (m)", _spin(_import_low, -100.0, 100.0, 0.5, 0.0)))
	_editing.add_child(_row("White (m)", _spin(_import_high, -100.0, 200.0, 0.5, 10.0)))
	var files := HBoxContainer.new()
	files.add_child(_button("Import…", _on_import))
	files.add_child(_button("Export…", _on_export))
	_editing.add_child(files)
	_link_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_editing.add_child(_link_label)
	var link := HBoxContainer.new()
	link.add_child(_button("Link file…", _on_link))
	_unlink_button = _button("Unlink", _on_unlink)
	link.add_child(_unlink_button)
	_range_button = _button("Apply black/white", _on_apply_range)
	link.add_child(_range_button)
	_editing.add_child(link)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_editing.add_child(_status)


func _ready() -> void:
	_file_dialog = EditorFileDialog.new()
	_file_dialog.access = EditorFileDialog.ACCESS_FILESYSTEM
	_file_dialog.file_selected.connect(_on_file_selected)
	add_child(_file_dialog)
	_link_dialog = EditorFileDialog.new()
	_link_dialog.access = EditorFileDialog.ACCESS_RESOURCES
	_link_dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
	_link_dialog.filters = PackedStringArray(["*.png ; 16-bit grayscale PNG", "*.exr ; Heights in meters"])
	_link_dialog.title = "Heightmap file to link (an existing one is read, a new one is written)"
	_link_dialog.file_selected.connect(_on_link_selected)
	add_child(_link_dialog)
	tools.tile_picked.connect(_on_tile_picked)
	tools.heightmap_synced.connect(_on_heightmap_synced)
	_on_size_changed(_size.value)
	_on_strength_changed(_strength.value)
	refresh()


## Shows the controls for the edited scene: its terrain's tiles, or the Add button.
func refresh() -> void:
	if tools == null:
		return
	var terrain := tools.find_terrain()
	_missing.visible = terrain == null
	_editing.visible = terrain != null
	_tiles.clear()
	if terrain == null:
		_select_tool(TerrainTools.Tool.NONE)
		return
	if terrain.tileset != null:
		for tile in terrain.tileset.tiles:
			_tiles.add_item(tile.name if tile != null else "?", tile.albedo if tile != null else null)
	if _tiles.item_count > 0:
		tools.tile = clampi(tools.tile, 0, _tiles.item_count - 1)
		_tiles.select(tools.tile)
	_show_link(terrain.data)


func _show_link(data: TerrainData) -> void:
	var linked := data != null and not data.heightmap.is_empty()
	_unlink_button.visible = linked
	_range_button.visible = linked
	if not linked:
		_link_label.text = "Link a file to paint the heights in an image editor."
		return
	_link_label.text = "Follows %s (black %.1f m, white %.1f m): paint it and save; sculpting here writes it back on scene save." % [
			data.heightmap.get_file(), data.heightmap_low, data.heightmap_high]
	_import_low.set_value_no_signal(data.heightmap_low)
	_import_high.set_value_no_signal(data.heightmap_high)


func _select_tool(value: int) -> void:
	for key in _tool_buttons:
		_tool_buttons[key].set_pressed_no_signal(key == value)
	tools.tool = value as TerrainTools.Tool


func _on_tool_toggled(pressed: bool, value: int) -> void:
	if pressed:
		tools.tool = value as TerrainTools.Tool
	elif tools.tool == value:
		tools.tool = TerrainTools.Tool.NONE


func _on_size_changed(value: float) -> void:
	tools.radius = value
	_size_label.text = "%.1f m" % value


func _on_strength_changed(value: float) -> void:
	tools.strength = value
	_strength_label.text = "%d%%" % roundi(value * 100.0)


func _on_tile_selected(index: int) -> void:
	tools.tile = index
	if tools.tool != TerrainTools.Tool.PAINT:
		_select_tool(TerrainTools.Tool.PAINT)


func _on_tile_picked(tile: int) -> void:
	if tile < _tiles.item_count:
		_tiles.select(tile)


func _on_add() -> void:
	var cells := int(_cells.value)
	tools.add_terrain(Vector2i(cells, cells))
	refresh()


func _on_generate() -> void:
	tools.generate(int(_seed.value), _height.value, _feature.value, int(_octaves.value), _flat_center.value)
	_status.text = "Generated. Ctrl+Z undoes it."


func _on_import() -> void:
	_exporting = false
	_file_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.filters = PackedStringArray(["*.png, *.exr, *.jpg, *.webp ; Images"])
	_file_dialog.popup_file_dialog()


func _on_export() -> void:
	_exporting = true
	_file_dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
	_file_dialog.filters = PackedStringArray(["*.exr ; Heights in meters", "*.png ; Grayscale, scaled to its range"])
	_file_dialog.popup_file_dialog()


func _on_link() -> void:
	var terrain := tools.find_terrain()
	var data_path := terrain.data.resource_path if terrain != null and terrain.data != null else ""
	if not data_path.is_empty() and not data_path.contains("::"):
		_link_dialog.current_path = "%s/%s_heights.png" % [data_path.get_base_dir(), data_path.get_file().get_basename()]
	_link_dialog.popup_file_dialog()


func _on_link_selected(path: String) -> void:
	_status.text = tools.link_heightmap(path, _import_low.value, _import_high.value)
	refresh()


func _on_unlink() -> void:
	tools.unlink_heightmap()
	_status.text = "Unlinked; the file stays where it is."
	refresh()


func _on_apply_range() -> void:
	_status.text = tools.set_heightmap_range(_import_low.value, _import_high.value)
	refresh()


func _on_heightmap_synced(message: String) -> void:
	_status.text = message


func _on_file_selected(path: String) -> void:
	var error := tools.export_heightmap(path) if _exporting else tools.import_heightmap(path, _import_low.value, _import_high.value)
	_status.text = error if not error.is_empty() else ("Exported %s" % path.get_file() if _exporting else "Imported %s. Ctrl+Z undoes it." % path.get_file())


# --- Building blocks -----------------------------------------------------------

static func _label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	return label


static func _section(text: String) -> Label:
	var label := _label(text)
	label.add_theme_font_override(&"font", EditorInterface.get_editor_theme().get_font(&"bold", &"EditorFonts"))
	return label


static func _row(text: String, control: Control, value_label: Label = null) -> HBoxContainer:
	var row := HBoxContainer.new()
	var label := _label(text)
	label.custom_minimum_size.x = 90
	row.add_child(label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	if value_label != null:
		value_label.custom_minimum_size.x = 52
		row.add_child(value_label)
	return row


static func _spin(spin: SpinBox, low: float, high: float, step: float, value: float) -> SpinBox:
	spin.min_value = low
	spin.max_value = high
	spin.step = step
	spin.value = value
	return spin


static func _slider(slider: HSlider, low: float, high: float, step: float, value: float, on_changed: Callable) -> void:
	slider.min_value = low
	slider.max_value = high
	slider.step = step
	slider.value = value
	slider.value_changed.connect(on_changed)


static func _button(text: String, on_pressed: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(on_pressed)
	return button
