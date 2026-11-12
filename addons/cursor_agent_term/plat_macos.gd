@tool
class_name CursorAgentPlatMacos
extends "res://addons/cursor_agent_term/plat_base.gd"
## macOS：WKWebView + xterm_web/macos.html + tmux/screen 外挂回退。


const EmbedBridgeScript := preload("res://addons/cursor_agent_term/embed_bridge.gd")
const MacosHostScript := preload("res://addons/cursor_agent_term/macos_host.gd")
const ExtStubScript := preload("res://addons/cursor_agent_term/ext_host_stub.gd")
const HOST_SCRIPT := "res://addons/cursor_agent_term/macos_embed_host.py"


func os_id() -> String:
	return "macos"


func _venv_python() -> String:
	var env_py := OS.get_environment("GCAT_MACOS_PYTHON").strip_edges()
	if not env_py.is_empty() and FileAccess.file_exists(env_py):
		return env_py
	var h := home()
	if h.is_empty():
		return ""
	var p := h.path_join(".cache/cursor-agent-term/macos-venv/bin/python")
	if FileAccess.file_exists(p):
		return p
	return ""


func embed_ok() -> bool:
	return EmbedBridgeScript.macos_ok(_venv_python())


func new_embed() -> RefCounted:
	if not embed_ok():
		return null
	return EmbedBridgeScript.new(HOST_SCRIPT, _venv_python())


func fallback_ok() -> bool:
	return not which("tmux").is_empty() or not which("screen").is_empty()


func new_fallback() -> RefCounted:
	if fallback_ok():
		return MacosHostScript.new()
	return ExtStubScript.new(os_id())


func shell() -> String:
	for c in ["zsh", "bash", "sh"]:
		var p := which(c)
		if not p.is_empty():
			return p
	return "/bin/zsh"


func term_bins() -> PackedStringArray:
	return PackedStringArray(["Terminal", "iTerm", "kitty", "alacritty", "wezterm"])


func clip_img_ok() -> bool:
	return not which("osascript").is_empty()


func agent_abs_candidates() -> PackedStringArray:
	return PackedStringArray([
		"/Applications/Cursor.app/Contents/Resources/app/bin/cursor-agent",
		"/usr/local/bin/cursor-agent",
		"/opt/homebrew/bin/cursor-agent",
	])


func hint() -> String:
	if embed_ok():
		return ""
	if fallback_ok():
		return "macOS 内嵌宿主不可用：已回退外挂 tmux/screen（可跑 install.sh 安装 PyObjC venv）"
	return "macOS 需内嵌宿主（install.sh 会装 PyObjC venv）或 tmux/screen + Terminal.app"


func slot_screen_rect(slot: Control) -> Rect2i:
	## 仅作调试参考；真正铺窗走 slot_geom_dict 相对坐标。
	var d: Dictionary = slot_geom_dict(slot)
	if d.is_empty():
		return Rect2i()
	return Rect2i(int(d.get("x", 0)), int(d.get("y", 0)), int(d.get("w", 0)), int(d.get("h", 0)))


func slot_geom_dict(slot: Control) -> Dictionary:
	## macOS 宿主用相对视口比例对齐 CGWindow 中的 Godot 窗，避开绝对坐标坑。
	if slot == null or not is_instance_valid(slot):
		return {}
	var vp: Viewport = slot.get_viewport()
	if vp == null:
		return {}
	var gr: Rect2 = slot.get_global_rect()
	var vr: Rect2 = vp.get_visible_rect()
	if vr.size.x < 1.0 or vr.size.y < 1.0:
		return {}
	var fx: float = gr.position.x / vr.size.x
	var fy: float = gr.position.y / vr.size.y
	var fw: float = gr.size.x / vr.size.x
	var fh: float = gr.size.y / vr.size.y
	var xf: Transform2D = vp.get_screen_transform()
	var tl: Vector2 = xf * gr.position
	var br: Vector2 = xf * (gr.position + gr.size)
	var x := int(floor(minf(tl.x, br.x)))
	var y := int(floor(minf(tl.y, br.y)))
	var w := maxi(1, int(ceil(absf(br.x - tl.x))))
	var h := maxi(1, int(ceil(absf(br.y - tl.y))))
	return {
		"mode": "rel",
		"fx": fx,
		"fy": fy,
		"fw": fw,
		"fh": fh,
		"x": x,
		"y": y,
		"w": w,
		"h": h,
	}
