extends Container

func _ready() -> void:
	# a display scale applied at start grows the window in pixels while the logical size, and so this container,
	# stays the same: sort again on the window's own size
	get_window().size_changed.connect(queue_sort)

func _notification(what: int) -> void:
	if what == NOTIFICATION_SORT_CHILDREN:
		var window = get_window()
		var scale = window.get_stretch_transform().get_scale()
		$SubViewportContainer.scale = Vector2(1., 1.) / scale
		$SubViewportContainer.size = window.size
