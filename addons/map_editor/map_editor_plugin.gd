@tool
extends EditorPlugin

## Map editing in the 3D view:
## - RTS View: the 3D view handles like the game camera instead of a fly-around
##   camera (wheel zoom, middle-drag pan, right-drag turn, arrows, F to center).
## - Props: drag a prefab scene (scenes/props, scenes/items, scenes/markers) or a raw
##   model file into the scene. Raw models become MapProps that block movement
##   (untick Blocks Movement for decorations). Props move as one piece with their
##   collision, stay on the ground, and a prop dropped onto a selected prop is put
##   beside it rather than inside it. The Map menu's Add list places the prefabs too.
## - Navigation preview: after every edit the navigation mesh the game will bake is
##   shown on the ground, unreachable pockets in red, creep lanes drawn.
## - Terrain dock: sculpt and paint the scene's Terrain with brushes, generate hills,
##   import/export heightmaps. The terrain data is saved with the scene.

const NavPreview := preload("res://addons/map_editor/nav_preview.gd")
const PropGizmo := preload("res://addons/map_editor/prop_gizmo.gd")
const RtsView := preload("res://addons/map_editor/rts_view.gd")
const TerrainTools := preload("res://addons/map_editor/terrain_tools.gd")
const TerrainDock := preload("res://addons/map_editor/terrain_dock.gd")
const REFRESH_DELAY := 0.3
const PREFAB_FOLDERS: Array[String] = ["res://scenes/props", "res://scenes/items", "res://scenes/markers"]
const MODEL_EXTENSIONS: Array[String] = ["glb", "gltf", "fbx", "blend", "obj", "dae"]
const VIEW_COUNT := 4  ## the 3D editor's split views

enum MenuId { SHOW_PREVIEW, REBAKE, RTS_VIEW, ADD_FIRST = 100 }

var _gizmo := PropGizmo.new()
var _toolbar := HBoxContainer.new()
var _menu := MenuButton.new()
var _add_menu := PopupMenu.new()
var _rts_button := Button.new()
var _status := Label.new()
var _timer := Timer.new()
var _show_preview := true
var _prefabs: Array[String] = []
var _views: Dictionary[Camera3D, RtsView] = {}
var _saved_view: Dictionary = {}  ## the RTS view of the scene being opened
var _dropped: Array[Node] = []
var _terrain_tools: TerrainTools
var _terrain_dock: TerrainDock


func _get_plugin_name() -> String:
	return "MapEditor"


func _enter_tree() -> void:
	add_node_3d_gizmo_plugin(_gizmo)
	set_input_event_forwarding_always_enabled()

	_menu.text = "Map"
	_menu.tooltip_text = "Map props and navigation preview"
	var popup := _menu.get_popup()
	_add_menu.name = &"Add"
	_add_menu.id_pressed.connect(_on_add)
	popup.add_child(_add_menu)
	popup.add_submenu_node_item("Add", _add_menu)
	popup.add_separator()
	popup.add_check_item("Show Navigation Preview", MenuId.SHOW_PREVIEW)
	popup.set_item_checked(popup.get_item_index(MenuId.SHOW_PREVIEW), _show_preview)
	popup.add_item("Rebake Preview", MenuId.REBAKE)
	popup.id_pressed.connect(_on_menu)
	popup.about_to_popup.connect(_fill_add_menu)

	_rts_button.text = "RTS View"
	_rts_button.toggle_mode = true
	_rts_button.button_pressed = true
	_rts_button.flat = true
	_rts_button.tooltip_text = "Game-style camera: wheel zoom, middle-drag pan, right-drag turn, arrows pan, F centers on the selection"
	_rts_button.toggled.connect(_on_rts_toggled)

	_toolbar.add_child(_menu)
	_toolbar.add_child(_rts_button)
	_toolbar.add_child(_status)
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _toolbar)

	_terrain_tools = TerrainTools.new(self)
	_terrain_dock = TerrainDock.new()
	_terrain_dock.tools = _terrain_tools
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _terrain_dock)

	_timer.one_shot = true
	_timer.wait_time = REFRESH_DELAY
	_timer.timeout.connect(refresh)
	add_child(_timer)
	get_undo_redo().version_changed.connect(_schedule)
	scene_changed.connect(_on_scene_changed)
	get_tree().node_added.connect(_on_node_added)
	_schedule()


func _exit_tree() -> void:
	remove_node_3d_gizmo_plugin(_gizmo)
	remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _toolbar)
	_toolbar.queue_free()
	remove_control_from_docks(_terrain_dock)
	_terrain_dock.queue_free()
	_terrain_tools.cleanup()
	get_undo_redo().version_changed.disconnect(_schedule)
	scene_changed.disconnect(_on_scene_changed)
	get_tree().node_added.disconnect(_on_node_added)
	for root in EditorInterface.get_open_scene_roots():
		var preview := _find_preview(root)
		if preview != null:
			preview.queue_free()


# --- RTS view ------------------------------------------------------------------

func _process(delta: float) -> void:
	_terrain_tools.process(delta)
	if not _rts_button.button_pressed:
		return
	for i in VIEW_COUNT:
		var viewport := EditorInterface.get_editor_viewport_3d(i)
		var container := viewport.get_parent() as Control
		if container == null or not container.is_visible_in_tree():
			continue
		var camera := viewport.get_camera_3d()
		var view := _view_for(camera)
		view.process(camera, delta)
		view.apply(camera)  # the editor's own camera moves are overridden


func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
	if _terrain_tools.handle(camera, event):
		return AFTER_GUI_INPUT_STOP
	if not _rts_button.button_pressed:
		return AFTER_GUI_INPUT_PASS
	var view := _view_for(camera)
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_F \
			and not (event.ctrl_pressed or event.alt_pressed or event.shift_pressed or event.meta_pressed):
		var center := _selection_center()
		if center != Vector3.INF:
			view.center_on(center, camera)
			return AFTER_GUI_INPUT_STOP
	return AFTER_GUI_INPUT_STOP if view.handle(camera, event) else AFTER_GUI_INPUT_PASS


## The terrain data lives in its own file; save it with the scene.
func _save_external_data() -> void:
	_terrain_tools.save_data()


## Remembered per scene by the editor, like its own camera.
func _get_state() -> Dictionary:
	var camera := EditorInterface.get_editor_viewport_3d(0).get_camera_3d()
	return _views[camera].get_state() if _views.has(camera) else {}


func _set_state(state: Dictionary) -> void:
	_saved_view = state
	var camera := EditorInterface.get_editor_viewport_3d(0).get_camera_3d()
	if _views.has(camera) and not state.is_empty():
		_views[camera].set_state(state)


func _view_for(camera: Camera3D) -> RtsView:
	if not _views.has(camera):
		var view := RtsView.new()
		view.take_over(camera)
		if camera == EditorInterface.get_editor_viewport_3d(0).get_camera_3d() and not _saved_view.is_empty():
			view.set_state(_saved_view)
		_views[camera] = view
	return _views[camera]


func _on_rts_toggled(enabled: bool) -> void:
	if enabled:
		_views.clear()  # pick up from wherever the editor camera is now


func _selection_center() -> Vector3:
	var total := Vector3.ZERO
	var count := 0
	for node in EditorInterface.get_selection().get_selected_nodes():
		if node is Node3D:
			total += (node as Node3D).global_position
			count += 1
	return total / count if count > 0 else Vector3.INF


# --- Props -------------------------------------------------------------------

## Instances a prefab scene at the center of the 3D view and selects it. Undoable.
func add_prefab(path: String) -> Node3D:
	var root := EditorInterface.get_edited_scene_root()
	var packed := load(path) as PackedScene
	if root == null or packed == null:
		return null
	var node := packed.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE) as Node3D
	if node == null:
		return null
	node.scene_file_path = path
	node.name = _unique_name(root, path.get_file().get_basename().to_pascal_case())
	node.position = _view_center_on_ground()

	var undo := get_undo_redo()
	undo.create_action("Add %s" % node.name)
	undo.add_do_method(root, &"add_child", node, true)
	undo.add_do_method(node, &"set_owner", root)
	undo.add_do_reference(node)
	undo.add_undo_method(root, &"remove_child", node)
	undo.commit_action()

	var selection := EditorInterface.get_selection()
	selection.clear()
	selection.add_node(node)
	return node


## Nodes appear while the editor commits a drop, paste or add; the scene they belong
## to is only known once the action is done.
func _on_node_added(node: Node) -> void:
	if not node is Node3D or node.scene_file_path.is_empty() or not get_undo_redo().is_committing_action():
		return
	if node is MapProp or (_is_model(node.scene_file_path) and node.get_script() == null):
		if _dropped.is_empty():
			_settle_drops.call_deferred()
		_dropped.append(node)


func _settle_drops() -> void:
	var root := EditorInterface.get_edited_scene_root()
	var dropped := _dropped
	_dropped = []
	for node in dropped:
		if not is_instance_valid(node) or not node.is_inside_tree() or node.owner != root:
			continue  # part of a prefab, or already gone again
		if node.get_script() == null:
			node.set_script(MapProp)
			(node as MapProp).refresh()
		var host := _prop_ancestor(node)
		if host != null:
			var undo := get_undo_redo()
			undo.create_action("Place %s beside %s" % [node.name, host.name])
			undo.add_do_method(node, &"reparent", host.get_parent(), true)
			undo.add_undo_method(node, &"reparent", node.get_parent(), true)
			undo.commit_action()


func _fill_add_menu() -> void:
	_add_menu.clear()
	_prefabs.clear()
	for folder in PREFAB_FOLDERS:
		for path in _scenes_in(folder):
			_add_menu.add_item(path.trim_prefix("res://scenes/").trim_suffix(".tscn"), MenuId.ADD_FIRST + _prefabs.size())
			_prefabs.append(path)


func _on_add(id: int) -> void:
	var index := id - MenuId.ADD_FIRST
	if index >= 0 and index < _prefabs.size():
		add_prefab(_prefabs[index])


static func _scenes_in(folder: String) -> Array[String]:
	var found: Array[String] = []
	var directory := DirAccess.open(folder)
	if directory == null:
		return found
	for file in directory.get_files():
		if file.get_extension() == "tscn":
			found.append(folder.path_join(file))
	for sub in directory.get_directories():
		found.append_array(_scenes_in(folder.path_join(sub)))
	return found


static func _is_model(path: String) -> bool:
	return path.get_extension().to_lower() in MODEL_EXTENSIONS


static func _prop_ancestor(node: Node) -> MapProp:
	var parent := node.get_parent()
	while parent != null:
		if parent is MapProp:
			return parent
		parent = parent.get_parent()
	return null


# --- Navigation preview --------------------------------------------------------

## Rebakes the preview of the edited scene now.
func refresh() -> void:
	_terrain_dock.refresh()
	var root := EditorInterface.get_edited_scene_root()
	if root == null or not root is Node3D:
		_status.text = ""
		return
	var preview := _find_preview(root)
	if not _show_preview:
		if preview != null:
			preview.queue_free()
		_status.text = ""
		return
	var region := _find_region(root)
	if preview == null:
		preview = NavPreview.new()
		preview.baked.connect(_on_baked.bind(preview))
		root.add_child(preview)  # not owned by the scene, so never saved
	preview.refresh(region, root)
	if region == null:
		_status.text = ""


func _schedule() -> void:
	_timer.start()


func _on_scene_changed(_root: Node) -> void:
	_schedule()


func _on_baked(preview: NavPreview) -> void:
	var islands := preview.outline.island_count
	if islands == 0:
		_status.text = "Navigation OK"
		_status.add_theme_color_override(&"font_color", Color(0.55, 0.95, 0.6))
	else:
		_status.text = "%d unreachable area%s (red)" % [islands, "" if islands == 1 else "s"]
		_status.add_theme_color_override(&"font_color", Color(1.0, 0.45, 0.4))


func _on_menu(id: int) -> void:
	match id:
		MenuId.SHOW_PREVIEW:
			_show_preview = not _show_preview
			var popup := _menu.get_popup()
			popup.set_item_checked(popup.get_item_index(MenuId.SHOW_PREVIEW), _show_preview)
			refresh()
		MenuId.REBAKE:
			refresh()


func _view_center_on_ground() -> Vector3:
	var camera := EditorInterface.get_editor_viewport_3d(0).get_camera_3d()
	if camera == null:
		return Vector3.ZERO
	var center := camera.get_viewport().get_visible_rect().size * 0.5
	var from := camera.project_ray_origin(center)
	var direction := camera.project_ray_normal(center)
	var hit := Terrain.trace(from, direction)  # the drawn ground, on terrain maps
	return Vector3(hit.x, MapProp.GROUND_HEIGHT, hit.z) if hit != Vector3.INF else Vector3.ZERO


static func _unique_name(parent: Node, base: String) -> String:
	var index := 1
	while parent.has_node(NodePath(base + str(index))):
		index += 1
	return base + str(index)


static func _find_region(root: Node) -> NavigationRegion3D:
	if root is NavigationRegion3D:
		return root
	var regions := root.find_children("*", "NavigationRegion3D")
	return regions[0] if not regions.is_empty() else null


static func _find_preview(root: Node) -> NavPreview:
	if root == null:
		return null
	return root.get_node_or_null(NodePath(NavPreview.NODE_NAME)) as NavPreview
