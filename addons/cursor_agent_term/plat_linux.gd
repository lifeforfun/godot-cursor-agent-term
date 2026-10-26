@tool
class_name CursorAgentPlatLinux
extends "res://addons/cursor_agent_term/plat_base.gd"
## Linux：内嵌 VTE（vte_host.py）+ GNU screen 回退。


const VteBridgeScript := preload("res://addons/cursor_agent_term/vte_bridge.gd")
const ScreenHostScript := preload("res://addons/cursor_agent_term/screen_host.gd")


func os_id() -> String:
	return "linux"


func embed_ok() -> bool:
	return VteBridgeScript.available()


func new_embed() -> RefCounted:
	if not embed_ok():
		return null
	return VteBridgeScript.new()


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
		return "无 VTE：已用 screen 回退（可装 python3-gi / gir1.2-vte-2.91 启用内嵌）"
	return "Linux 需 VTE（python3-gi+Vte）或 screen + 终端模拟器"
