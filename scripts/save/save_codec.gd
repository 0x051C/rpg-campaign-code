class_name SaveCodec
extends RefCounted

## Turns game state into plain data and back, for save files now and network snapshots
## later: only Variant values (numbers, strings, vectors, packed arrays, arrays,
## dictionaries), never Objects, so a save can be written with var_to_bytes and sent to
## another machine unchanged. Resources are referenced by their file, which every machine
## has; resources made at runtime (a summon's leveled definition) are written inline, as
## their script and properties.

const FILE := &"$res"
const INLINE := &"$inline"


## A resource as plain data: {"$res": path} for files, {"$inline": script, ...} otherwise.
static func encode_resource(resource: Resource) -> Variant:
	if resource == null:
		return null
	if resource.resource_path.begins_with("res://") and not resource.resource_path.contains("::"):
		return {FILE: resource.resource_path}
	var script: Script = resource.get_script()
	var data := {INLINE: script.resource_path if script != null else resource.get_class()}
	for property in resource.get_property_list():
		if property.usage & PROPERTY_USAGE_STORAGE == 0 or property.name in [&"script", &"resource_path", &"resource_name"]:
			continue
		data[property.name] = encode_value(resource.get(property.name))
	return data


static func decode_resource(data: Variant) -> Resource:
	if data == null:
		return null
	var entry: Dictionary = data
	if entry.has(FILE):
		return load(entry[FILE])
	var kind: String = entry[INLINE]
	var resource: Resource
	if kind.begins_with("res://"):
		resource = (load(kind) as Script).new()
	else:
		resource = ClassDB.instantiate(kind)
	for key: Variant in entry:
		if key == INLINE:
			continue
		var decoded: Variant = decode_value(entry[key])
		var current: Variant = resource.get(key)
		# Typed arrays and dictionaries keep their element types
		if current is Array and decoded is Array:
			(current as Array).assign(decoded)
		elif current is Dictionary and decoded is Dictionary:
			(current as Dictionary).assign(decoded)
		else:
			resource.set(key, decoded)
	return resource


## Any value: resources become references, arrays and dictionaries are walked.
static func encode_value(value: Variant) -> Variant:
	if value is Resource:
		return encode_resource(value)
	if value is Object:
		return null  # nodes and other objects never go into a save
	if value is Array:
		var list := []
		for element: Variant in value:
			list.append(encode_value(element))
		return list
	if value is Dictionary:
		var dictionary := {}
		for key: Variant in value:
			dictionary[key] = encode_value(value[key])
		return dictionary
	return value


static func decode_value(value: Variant) -> Variant:
	if value is Dictionary:
		var entry: Dictionary = value
		if entry.has(FILE) or entry.has(INLINE):
			return decode_resource(entry)
		var dictionary := {}
		for key: Variant in entry:
			dictionary[key] = decode_value(entry[key])
		return dictionary
	if value is Array:
		var list := []
		for element: Variant in value:
			list.append(decode_value(element))
		return list
	return value


## A typed array of resources (Array[ItemDefinition] etc.) as plain data, and back into `into`.
static func encode_resources(resources: Array) -> Array:
	var list := []
	for resource: Resource in resources:
		list.append(encode_resource(resource))
	return list


static func decode_resources_into(data: Array, into: Array) -> void:
	into.clear()
	for entry: Variant in data:
		into.append(decode_resource(entry))
