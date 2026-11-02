class_name LoadingScreen
extends CanvasLayer

## Shown while a map loads (Campaign.go_to): little_demo01's loading overlay, a dark
## gradient with drifting mist and the ring of fading dots around "LOADING".

const FONT := preload("res://assets/ui/fonts/almendra/Almendra-Regular.ttf")
const SPINNER := preload("res://shaders/ui/loading_spinner.gdshader")
const FOG := preload("res://shaders/ui/loading_fog.gdshader")
const MIST := preload("res://shaders/ui/menu_mist.gdshader")
const SKULL := preload("res://assets/ui/images/loading_skull.png")
const FLOWMAP := preload("res://assets/ui/images/menu_flowmap.png")
const ACCENT := Color(0.301961, 0.152941, 1.0)


func _ready() -> void:
	layer = 100
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	var gradient := Gradient.new()
	gradient.colors = PackedColorArray([Color.BLACK, Color(0.0386827, 0.0, 0.240795)])
	var background := TextureRect.new()
	var gradient_texture := GradientTexture1D.new()
	gradient_texture.gradient = gradient
	background.texture = gradient_texture
	_fill(background)
	var skull := TextureRect.new()
	skull.texture = SKULL
	skull.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	skull.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	skull.modulate = Color(1, 1, 1, 0.12)
	_fill(skull)
	var mist := ColorRect.new()
	mist.material = _material(MIST, {&"mist_color": Vector4(0.025, 0.015, 0.075, 1.0), &"flowmap": FLOWMAP, &"radius": 2.56,
			&"smoothness": 2.755, &"speed": 1.0, &"noise_scale": 13.745, &"time_scale": 0.5})
	_fill(mist)
	var fog := ColorRect.new()
	fog.material = _material(FOG, {&"mist_color": Vector4(0.3, 0.3, 0.3, 0.16), &"radius": 0.79, &"smoothness": 0.67,
			&"speed": 5.0, &"noise_scale": 4.0, &"time_scale": 0.5})
	fog.color = Color.BLACK
	_fill(fog)
	var spinner := ColorRect.new()
	spinner.material = _material(SPINNER, {&"radius": 0.063, &"ring_radius": 0.819, &"speed": 5.0, &"count": 32,
			&"fade_power": 2.463, &"circle_color": ACCENT})
	spinner.set_anchors_preset(Control.PRESET_CENTER)
	spinner.custom_minimum_size = Vector2(380, 380)
	spinner.size = spinner.custom_minimum_size
	spinner.position = -spinner.size * 0.5
	add_child(spinner)
	var label := Label.new()
	label.text = "LOADING"
	var settings := LabelSettings.new()
	settings.font = FONT
	settings.font_size = 64
	settings.outline_size = 5
	settings.outline_color = ACCENT
	label.label_settings = settings
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_fill(label)


func _fill(control: Control) -> void:
	control.set_anchors_preset(Control.PRESET_FULL_RECT)
	control.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(control)


static func _material(shader: Shader, parameters: Dictionary) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = shader
	for key: StringName in parameters:
		material.set_shader_parameter(key, parameters[key])
	return material
