@tool
extends EditorExportPlugin
## 导出时跳过本编辑器插件目录。

const SKIP_PREFIX := "res://addons/cursor_agent_term/"


func _get_name() -> String:
	return "cursor_agent_term_skip_export"


func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
	if path.begins_with(SKIP_PREFIX):
		skip()
