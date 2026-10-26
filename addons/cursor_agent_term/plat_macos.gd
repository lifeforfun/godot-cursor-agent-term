@tool
class_name CursorAgentPlatMacos
extends "res://addons/cursor_agent_term/plat_base.gd"
## macOS：内嵌 / 外挂终端尚未落地；能力探测与工厂集中在此，禁止把 Cocoa 逻辑散到 panel。


const ExtStubScript := preload("res://addons/cursor_agent_term/ext_host_stub.gd")


func os_id() -> String:
	return "macos"


func embed_ok() -> bool:
	# TODO: 内嵌终端（如 WKWebView/SwiftTerm 叠在 EditorDock 槽位）
	return false


func new_embed() -> RefCounted:
	# TODO: 返回 macOS 内嵌桥（对标 vte_bridge.gd）
	return null


func fallback_ok() -> bool:
	# TODO: 探测 Terminal.app / iTerm / tmux / screen 任一可用
	return false


func new_fallback() -> RefCounted:
	return ExtStubScript.new(os_id())


func which(name: String) -> String:
	if name.is_empty() or name.contains("/") or name.contains(" "):
		return ""
	var out: Array = []
	# macOS 通常有 /bin/zsh；command -v 走 sh 即可
	if OS.execute("sh", ["-c", "command -v %s" % name], out, true) != 0 or out.is_empty():
		return ""
	return str(out[0]).strip_edges()


func shell() -> String:
	for c in ["zsh", "bash", "sh"]:
		var p := which(c)
		if not p.is_empty():
			return p
	return "/bin/zsh"


func term_bins() -> PackedStringArray:
	# TODO: 按 open -a / which 探测后用于外挂附着
	return PackedStringArray(["Terminal", "iTerm", "kitty", "alacritty", "wezterm"])


func clip_img_ok() -> bool:
	# TODO: pbcopy/pngpaste 或 NSPasteboard 桥
	return false


func agent_path_candidates() -> PackedStringArray:
	return PackedStringArray([
		".local/bin/cursor-agent",
		".local/bin/agent",
		".cursor/bin/cursor-agent",
		".cursor/bin/agent",
	])


func agent_abs_candidates() -> PackedStringArray:
	return PackedStringArray([
		"/Applications/Cursor.app/Contents/Resources/app/bin/cursor-agent",
		"/usr/local/bin/cursor-agent",
		"/opt/homebrew/bin/cursor-agent",
	])


func hint() -> String:
	return "macOS 终端宿主尚未实现（plat_macos）；目前仅 Linux 支持内嵌 VTE"
