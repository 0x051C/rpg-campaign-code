@tool
class_name HeightmapFile
extends RefCounted

## Terrain heights as an image file, for painting in an image editor (TerrainData.heightmap).
## 16-bit grayscale PNG keeps 65536 levels: Godot's own PNG loader drops them to 256 (8 cm
## steps over 20 m, visible terracing), so this reads and writes those PNG chunks itself.
## .exr holds meters exactly. Any other image Godot reads works too, at 8-bit precision.

const PNG_SIGNATURE: Array[int] = [137, 80, 78, 71, 13, 10, 26, 10]
const CHANNELS: Dictionary[int, int] = {0: 1, 2: 3, 4: 2, 6: 4}  ## PNG color type -> channels

static var _crc_table := PackedInt64Array()


## Heights from the image at `path`, resampled to `vertices`: black is `low` meters, white
## `high` (an .exr's values are meters already). {heights} or {error}.
static func read(path: String, vertices: Vector2i, low: float, high: float) -> Dictionary:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return {"error": "Can't read %s" % path}
	var meters := path.get_extension().to_lower() == "exr"
	var image := _decode_png16(bytes) if path.get_extension().to_lower() == "png" else null
	if image == null:
		image = Image.load_from_file(path)  # EXR, 8-bit PNG, JPEG...
		if image == null or image.is_empty():
			return {"error": "Can't read %s" % path}
		if image.is_compressed():
			image.decompress()
		image.convert(Image.FORMAT_RF)
	if image.get_size() != vertices:
		image.resize(vertices.x, vertices.y, Image.INTERPOLATE_CUBIC)
	var values := image.get_data().to_float32_array()
	var heights := PackedFloat32Array()
	heights.resize(values.size())
	for i in values.size():
		heights[i] = values[i] if meters else lerpf(low, high, clampf(values[i], 0.0, 1.0))
	return {"heights": heights}


## Writes `heights` (`vertices` of them, row by row) to `path`: a 16-bit grayscale PNG with
## black = `low` and white = `high` meters, or an .exr in meters. Returns "" or the error.
static func write(path: String, heights: PackedFloat32Array, vertices: Vector2i, low: float, high: float) -> String:
	var bytes := PackedByteArray()
	if path.get_extension().to_lower() == "exr":
		var image := Image.create_from_data(vertices.x, vertices.y, false, Image.FORMAT_RF, heights.to_byte_array())
		return "" if image.save_exr(path, true) == OK else "Can't write %s" % path
	var levels := PackedFloat32Array()
	levels.resize(heights.size())
	var span := high - low if not is_zero_approx(high - low) else 1.0
	for i in heights.size():
		levels[i] = (heights[i] - low) / span
	bytes = _encode_png16(levels, vertices.x, vertices.y)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return "Can't write %s" % path
	file.store_buffer(bytes)
	return ""


## A 16-bit PNG (gray, gray+alpha, RGB or RGBA; the first channel counts) as an FORMAT_RF
## image of 0..1 values; null for anything else, left to Godot's loader.
static func _decode_png16(bytes: PackedByteArray) -> Image:
	if bytes.size() < 8 or Array(bytes.slice(0, 8)) != PNG_SIGNATURE:
		return null
	var width := 0
	var height := 0
	var depth := 0
	var color := -1
	var interlace := 0
	var compressed := PackedByteArray()
	var at := 8
	while at + 8 <= bytes.size():
		var length := _u32(bytes, at)
		var type := bytes.slice(at + 4, at + 8).get_string_from_ascii()
		var body := at + 8
		if type == "IHDR":
			width = _u32(bytes, body)
			height = _u32(bytes, body + 4)
			depth = bytes[body + 8]
			color = bytes[body + 9]
			interlace = bytes[body + 12]
		elif type == "IDAT":
			compressed.append_array(bytes.slice(body, body + length))
		elif type == "IEND":
			break
		at = body + length + 4  # skip the CRC
	if depth != 16 or interlace != 0 or not CHANNELS.has(color) or width <= 0 or height <= 0:
		return null
	var pixel := CHANNELS[color] * 2
	var stride := width * pixel
	var raw := compressed.decompress_dynamic(-1, FileAccess.COMPRESSION_DEFLATE)
	if raw.size() < (stride + 1) * height:
		return null
	var values := PackedFloat32Array()
	values.resize(width * height)
	var prior := PackedByteArray()
	prior.resize(stride)
	for y in height:
		var start := y * (stride + 1)
		var filter := raw[start]
		var row := raw.slice(start + 1, start + 1 + stride)
		for i in stride:
			var left := row[i - pixel] if i >= pixel else 0
			match filter:
				1:
					row[i] = (row[i] + left) & 0xFF
				2:
					row[i] = (row[i] + prior[i]) & 0xFF
				3:
					row[i] = (row[i] + ((left + prior[i]) >> 1)) & 0xFF
				4:
					var up_left := prior[i - pixel] if i >= pixel else 0
					row[i] = (row[i] + _paeth(left, prior[i], up_left)) & 0xFF
		for x in width:
			values[y * width + x] = ((row[x * pixel] << 8) | row[x * pixel + 1]) / 65535.0
		prior = row
	return Image.create_from_data(width, height, false, Image.FORMAT_RF, values.to_byte_array())


## `levels` (0..1, row by row) as a 16-bit grayscale PNG, rows "Sub"-filtered to compress well.
static func _encode_png16(levels: PackedFloat32Array, width: int, height: int) -> PackedByteArray:
	var raw := PackedByteArray()
	raw.resize((width * 2 + 1) * height)
	var at := 0
	for y in height:
		raw[at] = 1  # Sub: each byte minus the same byte of the pixel to its left
		at += 1
		var previous := 0
		for x in width:
			var value := clampi(roundi(levels[y * width + x] * 65535.0), 0, 65535)
			raw[at] = ((value >> 8) - (previous >> 8)) & 0xFF
			raw[at + 1] = ((value & 0xFF) - (previous & 0xFF)) & 0xFF
			previous = value
			at += 2
	var header := PackedByteArray()
	header.resize(13)
	_put_u32(header, 0, width)
	_put_u32(header, 4, height)
	header[8] = 16  # bits per sample
	header[9] = 0  # grayscale
	var png := PackedByteArray(PNG_SIGNATURE)
	_chunk(png, "IHDR", header)
	_chunk(png, "IDAT", raw.compress(FileAccess.COMPRESSION_DEFLATE))
	_chunk(png, "IEND", PackedByteArray())
	return png


static func _chunk(png: PackedByteArray, type: String, body: PackedByteArray) -> void:
	var length := PackedByteArray()
	length.resize(4)
	_put_u32(length, 0, body.size())
	png.append_array(length)
	var typed := type.to_ascii_buffer()
	typed.append_array(body)
	png.append_array(typed)
	var crc := PackedByteArray()
	crc.resize(4)
	_put_u32(crc, 0, _crc32(typed))
	png.append_array(crc)


static func _crc32(bytes: PackedByteArray) -> int:
	if _crc_table.is_empty():
		_crc_table.resize(256)
		for n in 256:
			var c := n
			for k in 8:
				c = (0xEDB88320 ^ (c >> 1)) if c & 1 else c >> 1
			_crc_table[n] = c
	var crc := 0xFFFFFFFF
	for byte in bytes:
		crc = _crc_table[(crc ^ byte) & 0xFF] ^ (crc >> 8)
	return crc ^ 0xFFFFFFFF


static func _paeth(a: int, b: int, c: int) -> int:
	var p := a + b - c
	var pa := absi(p - a)
	var pb := absi(p - b)
	var pc := absi(p - c)
	if pa <= pb and pa <= pc:
		return a
	return b if pb <= pc else c


static func _u32(bytes: PackedByteArray, at: int) -> int:
	return (bytes[at] << 24) | (bytes[at + 1] << 16) | (bytes[at + 2] << 8) | bytes[at + 3]


static func _put_u32(bytes: PackedByteArray, at: int, value: int) -> void:
	bytes[at] = (value >> 24) & 0xFF
	bytes[at + 1] = (value >> 16) & 0xFF
	bytes[at + 2] = (value >> 8) & 0xFF
	bytes[at + 3] = value & 0xFF
