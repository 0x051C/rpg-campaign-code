extends SceneTree
## HeightmapFile: round trip, ImageMagick's 16-bit PNGs (all row filters, in fixtures/), RGB,
## the 8-bit fallback, and how long a 1025x1025 map takes.

const FIXTURES := "res://tests/fixtures/"

func _initialize() -> void:
	var support: Script = load("res://tests/framework/support.gd")
	var scratch: String = support.call(&"output_dir").path_join("heightmap_")
	var fixtures := ProjectSettings.globalize_path(FIXTURES)
	var failures := 0
	var size := Vector2i(161, 161)
	var heights := PackedFloat32Array()
	heights.resize(size.x * size.y)
	for z in size.y:
		for x in size.x:
			heights[z * size.x + x] = 3.0 + 7.0 * sin(x * 0.07) * cos(z * 0.05) + x * 0.01
	var error := HeightmapFile.write(scratch + "round.png", heights, size, -5.0, 15.0)
	var back: Dictionary = HeightmapFile.read(scratch + "round.png", size, -5.0, 15.0)
	var worst := 0.0
	for i in heights.size():
		worst = maxf(worst, absf(heights[i] - back.heights[i]))
	print("round trip: error '%s', worst difference %.6f m (one 16-bit step: %.6f)" % [error, worst, 20.0 / 65535.0])
	if not error.is_empty() or worst > 20.0 / 65535.0:
		failures += 1
	for file in ["im_gray16.png", "im_plasma16.png", "im_rgb16.png"]:
		var mine := HeightmapFile._decode_png16(FileAccess.get_file_as_bytes(fixtures + file))
		var reference := Image.load_from_file(fixtures + file)  # Godot's 8-bit read of the same file
		reference.convert(Image.FORMAT_RF)
		var levels := {}
		var off := 0.0
		for i in 161 * 161:
			var v := mine.get_data().decode_float(i * 4)
			levels[v] = true
			off = maxf(off, absf(v - reference.get_data().decode_float(i * 4)))
		print("%s: %d distinct levels, max difference from Godot's 8-bit read %.4f" % [file, levels.size(), off])
		if off > 1.0 / 255.0 + 0.0001 or (file != "im_rgb16.png" and levels.size() <= 256):
			failures += 1
	var eight: Dictionary = HeightmapFile.read(fixtures + "im_gray8.png", size, 0.0, 10.0)
	print("8-bit PNG falls back to Godot: %s" % ("ok" if eight.has("heights") else eight.error))
	if not eight.has("heights"):
		failures += 1
	var big := Vector2i(1025, 1025)
	var many := PackedFloat32Array()
	many.resize(big.x * big.y)
	for i in many.size():
		many[i] = sin(i * 0.001) * 10.0
	var t := Time.get_ticks_msec()
	HeightmapFile.write(scratch + "big.png", many, big, -10.0, 10.0)
	var written := Time.get_ticks_msec() - t
	t = Time.get_ticks_msec()
	HeightmapFile.read(scratch + "big.png", big, -10.0, 10.0)
	print("1025x1025: write %d ms, read %d ms" % [written, Time.get_ticks_msec() - t])
	print("FAILURES: %d" % failures)
	quit()
