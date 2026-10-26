@tool
class_name CursorAgentPlatWindows
extends "res://addons/cursor_agent_term/plat_base.gd"
## Windows：内嵌 / 外挂终端尚未落地；Win32/ConPTY 逻辑只准写在本文件及将来的 win_host。


const ExtStubScript := preload("res://addons/cursor_agent_term/ext_host_stub.gd")


func os_id() -> String:
	return "windows"


func embed_ok() -> bool:
	# TODO: 内嵌 ConPTY / Windows Terminal 控件叠在 EditorDock
	return false


func new_embed() -> RefCounted:
	# TODO: 返回 Windows 内嵌桥（对标 vte_bridge.gd）
	return null


func fallback_ok() -> bool:
	# TODO: 探测 wt.exe / conhost / powershell 启动外挂
	return false


func new_fallback() -> RefCounted:
	return ExtStubScript.new(os_id())


func which(name: String) -> String:
	if name.is_empty() or name.contains("/") or name.contains("\\") or name.contains(" "):
		return ""
	var out: Array = []
	# where.exe 为 Windows 常驻
	if OS.execute("where", PackedStringArray([name]), out, true) == 0 and not out.is_empty():
		var line := str(out[0]).strip_edges()
		# where 可能多行，取首行
		var nl := line.find("\n")
		if nl >= 0:
			line = line.substr(0, nl).strip_edges()
		return line
	return ""


func shell() -> String:
	for c in ["powershell.exe", "pwsh.exe", "cmd.exe"]:
		var p := which(c)
		if not p.is_empty():
			return p
	return "cmd.exe"


func term_bins() -> PackedStringArray:
	return PackedStringArray(["wt.exe", "powershell.exe", "cmd.exe"])


func clip_img_ok() -> bool:
	# TODO: Win32 剪贴板 CF_DIB / PNG
	return false


func home() -> String:
	var h := OS.get_environment("USERPROFILE").strip_edges()
	if not h.is_empty():
		return h
	return super.home()


func agent_path_candidates() -> PackedStringArray:
	return PackedStringArray([
		"AppData/Local/Programs/cursor/resources/app/bin/cursor-agent.cmd",
		"AppData/Local/cursor-agent/cursor-agent.exe",
		".cursor/bin/cursor-agent.exe",
		".local/bin/cursor-agent.exe",
	])


func hint() -> String:
	return "Windows 终端宿主尚未实现（plat_windows）；目前仅 Linux 支持内嵌 VTE"
