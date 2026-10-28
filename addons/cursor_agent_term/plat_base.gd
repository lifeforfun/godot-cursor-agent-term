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


func slot_screen_rect(slot: Control) -> Rect2i:
	## 槽位 → 屏幕像素矩形（左上原点、y 向下）。Linux 默认实现；macOS 覆盖。
	if slot == null or not is_instance_valid(slot):
		return Rect2i()
	var gr: Rect2 = slot.get_global_rect()
	var vp: Viewport = slot.get_viewport()
	if vp == null:
		return Rect2i()
	var win_id: int = vp.get_window_id()
	var win_pos := DisplayServer.window_get_position(win_id)
	var win_size := DisplayServer.window_get_size(win_id)
	var vp_size: Vector2 = vp.get_visible_rect().size
	var sx := float(win_size.x) / maxf(vp_size.x, 1.0)
	var sy := float(win_size.y) / maxf(vp_size.y, 1.0)
	var x := win_pos.x + int(round(gr.position.x * sx))
	var y := win_pos.y + int(round(gr.position.y * sy))
	var w := maxi(1, int(round(gr.size.x * sx)))
	var h := maxi(1, int(round(gr.size.y * sy)))
	if w < 8 or h < 8:
		return Rect2i()
	return Rect2i(x, y, w, h)
