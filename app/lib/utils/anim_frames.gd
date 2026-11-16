## Frames of an animated item or background: a folder of PNG frames (VTube Studio's animation folders), or one
## animated GIF, APNG or WebP decoded by Katashiro's AnimatedImage. The animation speed is the frames per second; a
## file's own frame delays stay as relative durations, so the average speed is its fps and changing it keeps the
## rhythm. A folder of frames plays in one second unless an fps is given (as before).
extends RefCounted

const ANIMATED_EXTENSIONS = ["gif", "png", "apng", "webp"]
const ANIM = &"default"

## {frames: SpriteFrames, size: Vector2} or {} when paths are not an animation (a still picture)
static func load_frames(paths: PackedStringArray) -> Dictionary:
	if paths.is_empty():
		return {}
	var files := paths
	if paths.size() == 1 and DirAccess.dir_exists_absolute(paths[0]):
		files = folder_frames(paths[0])
	var textures: Array[Texture2D] = []
	var durations: Array[float] = []
	if files.size() > 1:
		for f in files:
			var img := Image.load_from_file(f)
			if img:
				textures.append(ImageTexture.create_from_image(img))
				durations.append(1.0)
	elif files.size() == 1 and maybe_animated(files[0]) and ClassDB.class_exists(&"AnimatedImage"):
		var d: Dictionary = ClassDB.class_call_static(&"AnimatedImage", &"decode", files[0])
		if d.get("error", ""):
			push_warning("%s: %s" % [files[0], d.error])
		var delays: PackedFloat32Array = d.get("delays", PackedFloat32Array())
		for i in d.get("frames", []).size():
			textures.append(ImageTexture.create_from_image(d.frames[i]))
			durations.append(delays[i])
	if textures.size() < 2:
		return {}
	var frames := SpriteFrames.new()
	frames.set_animation_loop(ANIM, true)
	var size := Vector2.ZERO
	var total := 0.0
	for d in durations:
		total += d
	var mean := total / durations.size()
	for i in textures.size():
		frames.add_frame(ANIM, textures[i], durations[i] / mean)
		size = size.max(textures[i].get_size())
	# a file: its average rate; frames of a folder: the whole loop in a second, as before
	frames.set_animation_speed(ANIM, 1.0 / mean if files.size() == 1 else float(textures.size()))
	return {"frames": frames, "size": size}

## A texture for a background: an AnimatedTexture for an animated file (it plays on its own, also in copies of the
## background such as the virtual camera's; at most 256 frames), else the still picture. null when it cannot load.
static func load_texture(path: String) -> Texture2D:
	var anim := load_frames(PackedStringArray([path])) if maybe_animated(path) else {}
	if anim.is_empty():
		var still := load_still(path)
		return ImageTexture.create_from_image(still) if still else null
	var sf: SpriteFrames = anim.frames
	var n := sf.get_frame_count(ANIM)
	if n > AnimatedTexture.MAX_FRAMES:
		push_warning("%s: %d frames, a background plays the first %d" % [path, n, AnimatedTexture.MAX_FRAMES])
		n = AnimatedTexture.MAX_FRAMES
	var at := AnimatedTexture.new()
	at.frames = n
	var speed := sf.get_animation_speed(ANIM)
	for i in n:
		at.set_frame_texture(i, sf.get_frame_texture(ANIM, i))
		at.set_frame_duration(i, sf.get_frame_duration(ANIM, i) / speed)
	return at

## a still picture, including a GIF (Godot cannot load those): its first frame
static func load_still(path: String) -> Image:
	if path.get_extension().to_lower() == "gif" and ClassDB.class_exists(&"AnimatedImage"):
		var d: Dictionary = ClassDB.class_call_static(&"AnimatedImage", &"decode", path)
		return d.frames[0] if d.get("frames", []).size() > 0 else null
	return Image.load_from_file(path)

static func maybe_animated(path: String) -> bool:
	return path.get_extension().to_lower() in ANIMATED_EXTENSIONS

## PNG frames of an animation folder, in name order
static func folder_frames(dir: String) -> PackedStringArray:
	var files := Array(DirAccess.get_files_at(dir)).filter(func (f): return f.get_extension().to_lower() == "png")
	files.sort_custom(func (a, b): return a.naturalnocasecmp_to(b) < 0)
	return PackedStringArray(files.map(func (f): return dir.path_join(f)))
