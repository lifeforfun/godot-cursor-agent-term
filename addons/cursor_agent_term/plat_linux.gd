@tool
class_name CursorAgentPlatLinux
extends "res://addons/cursor_agent_term/plat_base.gd"
## Linux：WebKitGTK + xterm_web/linux.html 内嵌 + GNU screen 回退。


const EmbedBridgeScript := preload("res://addons/cursor_agent_term/embed_bridge.gd")
const ScreenHostScript := preload("res://addons/cursor_agent_term/screen_host.gd")
const HOST_SCRIPT := "res://addons/cursor_agent_term/linux_embed_host.py"


func os_id() -> String:
	return "linux"


func embed_ok() -> bool:
	return EmbedBridgeScript.linux_ok()


func new_embed() -> RefCounted:
	if not embed_ok():
		return null
	return EmbedBridgeScript.new(HOST_SCRIPT, "python3")


func fallback_ok() -> bool:
	return not which("screen").is_empty()


func new_fallback() -> RefCounted:
	return ScreenHostScript.new()


func term_bins() -> PackedStringArray:
	return PackedStringArray([
		"gnome-terminal",
		"x-terminal-emulator",
		"xfce4-terminal",
		"konsole",
		"kitty",
		"alacritty",
		"wezterm",
		"xterm",
	])


func clip_img_ok() -> bool:
	return not which("xclip").is_empty()


func hint() -> String:
	if embed_ok():
		return ""
	if fallback_ok():
		return "无 WebKitGTK：已用 screen 回退（可装 gir1.2-webkit2-4.1 启用内嵌 xterm）"
	return "Linux 需 WebKitGTK（python3-gi + gir1.2-webkit2-4.1）或 screen + 终端模拟器"
