@tool
class_name CursorAgentPlatBase
extends RefCounted
## 平台能力抽象：业务代码只依赖本接口，系统独有逻辑放在 plat_linux / plat_macos / plat_windows。


func os_id() -> String:
	return "unknown"


func embed_ok() -> bool:
	## 编辑器内嵌终端（Linux=VTE 浮层）
	return false


func new_embed() -> RefCounted:
	## 返回与 CursorAgentVteBridge 同协议的对象；不可用则 null
	return null


func fallback_ok() -> bool:
	## 外挂终端回退（Linux=GNU screen）
	return false


func new_fallback() -> RefCounted:
	## 返回与 CursorAgentScreenHost 同协议的对象；不可用则 null
	return null


func which(name: String) -> String:
	if name.is_empty() or name.contains("/") or name.contains("\\") or name.contains(" "):
		return ""
	var out: Array = []
	if OS.execute("sh", ["-c", "command -v %s" % name], out, true) != 0 or out.is_empty():
		return ""
	return str(out[0]).strip_edges()


func home() -> String:
	var h := OS.get_environment("HOME").strip_edges()
	if not h.is_empty():
		return h
	h = OS.get_environment("USERPROFILE").strip_edges()
	if not h.is_empty():
		return h
	var drive := OS.get_environment("HOMEDRIVE").strip_edges()
	var path := OS.get_environment("HOMEPATH").strip_edges()
	if not drive.is_empty() and not path.is_empty():
		return drive + path
	return ""


func shell() -> String:
	for c in ["bash", "sh"]:
		var p := which(c)
		if not p.is_empty():
			return p
	return "sh"


func term_bins() -> PackedStringArray:
	return PackedStringArray()


func clip_img_ok() -> bool:
	## 图片粘贴规范化工具（Linux=xclip）
	return false


func hint() -> String:
	## 当前平台能力不足时的用户提示
	return "当前系统尚未支持内嵌/回退终端"


func agent_path_candidates() -> PackedStringArray:
	## 相对 home 的常见 agent 安装位（各平台可覆盖）
	return PackedStringArray([
		".local/bin/cursor-agent",
		".local/bin/agent",
		".cursor/bin/cursor-agent",
		".cursor/bin/agent",
	])


func agent_abs_candidates() -> PackedStringArray:
	## 绝对路径候选（如 /Applications/...）
	return PackedStringArray()
