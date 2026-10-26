@tool
class_name CursorAgentDock
extends EditorDock
## 编辑器 dock 的固定回调 → 信号，供面板事件驱动同步 VTE（不靠轮询猜尺寸）。

signal dock_layout_changed(layout: int)
signal dock_geom_changed(reason: String)
signal dock_vis_changed()


func _enter_tree() -> void:
	if not resized.is_connected(_on_resized):
		resized.connect(_on_resized)
	if not visibility_changed.is_connected(_on_vis):
		visibility_changed.connect(_on_vis)
	if has_signal("item_rect_changed") and not item_rect_changed.is_connected(_on_rect):
		item_rect_changed.connect(_on_rect)


func _update_layout(layout: int) -> void:
	## 竖栏 / 底栏横槽 / 浮动 切换时由引擎调用（挪 dock 位置也会走到）
	dock_layout_changed.emit(layout)
	dock_geom_changed.emit("layout=%d" % layout)


func _notification(what: int) -> void:
	# 父节点变更（换槽位）后矩形常变
	if what == NOTIFICATION_PARENTED or what == NOTIFICATION_UNPARENTED:
		dock_geom_changed.emit("reparent")
	elif what == NOTIFICATION_RESIZED:
		dock_geom_changed.emit("notif-resized")


func _on_resized() -> void:
	dock_geom_changed.emit("resized")


func _on_rect() -> void:
	dock_geom_changed.emit("item-rect")


func _on_vis() -> void:
	dock_vis_changed.emit()
