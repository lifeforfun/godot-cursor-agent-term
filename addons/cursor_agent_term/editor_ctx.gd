@tool
class_name CursorAgentEditorCtx
extends RefCounted
## 采集当前脚本路径与选区行号，拼成 [path] 或 [path:start-end]。
## 点 dock 按钮常会让 CodeEdit 失焦丢选区，故在仍有选区时写入缓存。

const LauncherScript := preload("res://addons/cursor_agent_term/launcher.gd")

## 最近一次「真实选区」快照；失焦丢选后同文件仍可用
static var _sel_cache: Dictionary = {}


static func refresh_cache() -> void:
	var live := collect()
	if live.is_empty():
		return
	if bool(live.get("from_sel", false)):
		_sel_cache = {
			"path": live["path"],
			"start": live["start"],
			"end": live["end"],
		}
		return
	# 换文件则丢掉旧选区行号
	if str(_sel_cache.get("path", "")) != str(live.get("path", "")):
		_sel_cache = {"path": live["path"]}


static func collect_at_notation() -> String:
	refresh_cache()
	var live := collect()
	if live.is_empty() and _sel_cache.is_empty():
		return ""
	var path: String = ""
	var start := 0
	var end := 0
	var has_lines := false

	if bool(live.get("from_sel", false)):
		path = str(live.get("path", ""))
		start = int(live["start"])
		end = int(live["end"])
		has_lines = true
	elif not live.is_empty() and str(_sel_cache.get("path", "")) == str(live.get("path", "")) and _sel_cache.has("start"):
		path = str(live.get("path", ""))
		start = int(_sel_cache["start"])
		end = int(_sel_cache["end"])
		has_lines = true
	elif _sel_cache.has("path") and _sel_cache.has("start") and live.is_empty():
		path = str(_sel_cache.get("path", ""))
		start = int(_sel_cache["start"])
		end = int(_sel_cache["end"])
		has_lines = true
	elif not live.is_empty() and int(live.get("caret", 0)) >= 1:
		path = str(live.get("path", ""))
		start = int(live["caret"])
		end = start
		has_lines = true
	elif not live.is_empty():
		path = str(live.get("path", ""))
	elif _sel_cache.has("path"):
		path = str(_sel_cache.get("path", ""))

	path = path.replace(" ", "\\ ")
	if path.is_empty():
		return ""
	if has_lines:
		return "[%s:%d-%d]" % [path, start, end]
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
		result["from_sel"] = true
	else:
		result["caret"] = code.get_caret_line() + 1
	return result


static func _to_project_relative(res_path: String) -> String:
	if res_path.begins_with("res://"):
		return res_path.trim_prefix("res://")
	var root: String = LauncherScript.project_root()
	var abs := ProjectSettings.globalize_path(res_path)
	if abs.begins_with(root + "/"):
		return abs.trim_prefix(root + "/")
	return abs
