@tool
class_name CursorAgentEditorCtx
extends RefCounted
## 采集当前脚本路径与选区行号，拼成 [path] 或 [path:start-end]。

const LauncherScript := preload("res://addons/cursor_agent_term/launcher.gd")


static func collect_at_notation() -> String:
	var ref := collect()
	if ref.is_empty():
		return ""
	var path: String = str(ref.get("path", "")).replace(" ", "\\ ")
	if ref.has("start") and ref.has("end"):
		return "[%s:%d-%d]" % [path, int(ref["start"]), int(ref["end"])]
	return "[%s]" % path


static func collect() -> Dictionary:
	var se := EditorInterface.get_script_editor()
	if se == null:
		return {}
	var script: Script = se.get_current_script()
	if script == null:
		return {}
	var res_path := script.resource_path
	if res_path.is_empty():
		return {}
	var rel := _to_project_relative(res_path)
	var result := {"path": rel}

	var editor_base := se.get_current_editor()
	if editor_base == null:
		return result
	var base: Control = editor_base.get_base_editor()
	if base == null or not (base is CodeEdit):
		return result
	var code := base as CodeEdit
	if code.has_selection():
		var from_line := mini(code.get_selection_from_line(), code.get_selection_to_line()) + 1
		var to_line := maxi(code.get_selection_from_line(), code.get_selection_to_line()) + 1
		result["start"] = from_line
		result["end"] = to_line
	return result


static func _to_project_relative(res_path: String) -> String:
	if res_path.begins_with("res://"):
		return res_path.trim_prefix("res://")
	var root: String = LauncherScript.project_root()
	var abs := ProjectSettings.globalize_path(res_path)
	if abs.begins_with(root + "/"):
		return abs.trim_prefix(root + "/")
	return abs
