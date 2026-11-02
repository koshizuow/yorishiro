## Which copy of the app this is, for several people on one computer (VTube Studio's "window #"). `--instance=2` for
## run.sh or the AppImage: the launcher gives that copy its own settings folder (the model, item and background
## libraries stay shared) and sets YORISHIRO_INSTANCE. What two copies must not share comes from here.
extends RefCounted

static func number() -> int:
	return maxi(1, OS.get_environment("YORISHIRO_INSTANCE").to_int())

## the window title and the PipeWire stream, "Yorishiro" for the first copy
static func name_with(separator: String) -> String:
	return "Yorishiro" if number() == 1 else "Yorishiro%s%d" % [separator, number()]
