@tool
class_name CursorAgentLauncher
extends RefCounted
## 解析本机 cursor-agent；路径发现走 plat，不在此写 OS 分支。

const SessionStoreScript := preload("res://addons/cursor_agent_term/session_store.gd")
const PlatScript := preload("res://addons/cursor_agent_term/plat.gd")


static func resolve_exe() -> String:
	var plat: RefCounted = PlatScript.get_plat()
	var env_path := OS.get_environment("CURSOR_AGENT_PATH").strip_edges()
	if not env_path.is_empty() and _is_exe(env_path):
		return env_path
	for name in ["cursor-agent", "agent", "cursor-agent.exe", "agent.exe"]:
		var found: String = plat.which(name)
		if not found.is_empty():
			return found
	var home: String = plat.home()
	if not home.is_empty():
		var cands: PackedStringArray = plat.agent_path_candidates()
		for rel in cands:
			var p: String = home.path_join(rel)
			if _is_exe(p):
				return p
	var abs_cands: PackedStringArray = plat.agent_abs_candidates()
	for ap in abs_cands:
		if _is_exe(ap):
			return ap
	return "cursor-agent"


static func agent_available() -> bool:
	var plat: RefCounted = PlatScript.get_plat()
	var exe := resolve_exe()
	if exe.contains("/") or exe.contains("\\"):
		return _is_exe(exe)
	return not plat.which(exe).is_empty()


static func build_command(project_path: String, resume_session_id: String = "") -> PackedStringArray:
	var store := SessionStoreScript.new()
	var ws: String = store.normalize_project_path(project_path)
	var cmd: PackedStringArray = [resolve_exe(), "--workspace", ws]
	if not resume_session_id.is_empty():
		cmd.append("--resume")
		cmd.append(resume_session_id)
	return cmd


static func project_root() -> String:
	var store := SessionStoreScript.new()
	return store.normalize_project_path(ProjectSettings.globalize_path("res://"))


static func screen_session_name(project_path: String) -> String:
	var store := SessionStoreScript.new()
	var h: String = store.workspace_hash(project_path)
	return "gcat_" + h.substr(0, 12)


static func _is_exe(path: String) -> bool:
	return not path.is_empty() and FileAccess.file_exists(path)
