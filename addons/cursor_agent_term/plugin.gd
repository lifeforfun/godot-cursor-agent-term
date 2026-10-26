@tool
extends EditorPlugin
## EditorDock 注册；把初始化/布局恢复/dock 尺寸与位置变化转成面板事件。

const PanelScript := preload("res://addons/cursor_agent_term/panel.gd")
const DockScript := preload("res://addons/cursor_agent_term/agent_dock.gd")
const ExportPluginScript := preload("res://addons/cursor_agent_term/export_plugin.gd")

var _panel: Control
var _dock: EditorDock
var _export_plugin: EditorExportPlugin


func _enter_tree() -> void:
	_panel = PanelScript.new()
	_panel.name = "CursorAgentTermPanel"
	_panel.custom_minimum_size = Vector2(120, 160)
	_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL

	_dock = DockScript.new()
	_dock.title = "Cursor Agent"
	_dock.layout_key = "cursor_agent_term"
	_dock.default_slot = EditorDock.DOCK_SLOT_BOTTOM
	_dock.available_layouts = EditorDock.DOCK_LAYOUT_ALL
	_dock.add_child(_panel)
	add_dock(_dock)

	_dock.closed.connect(_on_dock_closed)
	_dock.opened.connect(_on_dock_opened)
	if _dock.has_signal("dock_geom_changed"):
		_dock.dock_geom_changed.connect(_on_dock_geom)
	if _dock.has_signal("dock_vis_changed"):
		_dock.dock_vis_changed.connect(_on_dock_vis)
	if _dock.has_signal("dock_layout_changed"):
		_dock.dock_layout_changed.connect(_on_dock_layout)

	_export_plugin = ExportPluginScript.new()
	add_export_plugin(_export_plugin)
	# 插件挂上后延迟一拍：等编辑器把 dock 放进槽位
	call_deferred("_notify_editor_ready")


func _exit_tree() -> void:
	if _export_plugin:
		remove_export_plugin(_export_plugin)
		_export_plugin = null
	if _dock:
		_disconnect_dock()
		remove_dock(_dock)
		_dock.queue_free()
		_dock = null
		_panel = null


func _set_window_layout(_configuration: ConfigFile) -> void:
	## 编辑器恢复 dock 布局后回调 —— 固定的「初始化完成」事件之一
	_notify_editor_ready()


func _notify_editor_ready() -> void:
	if _panel and _panel.has_method("on_editor_ready"):
		_panel.call_deferred("on_editor_ready")


func _disconnect_dock() -> void:
	if _dock.closed.is_connected(_on_dock_closed):
		_dock.closed.disconnect(_on_dock_closed)
	if _dock.opened.is_connected(_on_dock_opened):
		_dock.opened.disconnect(_on_dock_opened)
	if _dock.has_signal("dock_geom_changed") and _dock.dock_geom_changed.is_connected(_on_dock_geom):
		_dock.dock_geom_changed.disconnect(_on_dock_geom)
	if _dock.has_signal("dock_vis_changed") and _dock.dock_vis_changed.is_connected(_on_dock_vis):
		_dock.dock_vis_changed.disconnect(_on_dock_vis)
	if _dock.has_signal("dock_layout_changed") and _dock.dock_layout_changed.is_connected(_on_dock_layout):
		_dock.dock_layout_changed.disconnect(_on_dock_layout)


func _on_dock_closed() -> void:
	if _panel and _panel.has_method("on_dock_closed"):
		_panel.call("on_dock_closed")


func _on_dock_opened() -> void:
	if _panel and _panel.has_method("on_dock_opened"):
		_panel.call("on_dock_opened")


func _on_dock_geom(reason: String) -> void:
	if _panel and _panel.has_method("on_dock_geom_event"):
		_panel.call("on_dock_geom_event", reason)


func _on_dock_vis() -> void:
	if _panel and _panel.has_method("on_dock_visibility_ping"):
		_panel.call("on_dock_visibility_ping")


func _on_dock_layout(layout: int) -> void:
	if _panel and _panel.has_method("on_dock_layout_event"):
		_panel.call("on_dock_layout_event", layout)
