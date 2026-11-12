@tool
class_name CursorAgentEmbedBridge
extends RefCounted
## 跨平台内嵌宿主桥：TCP NDJSON ↔ linux_embed_host / macos_embed_host。
## 宿主脚本由 plat 注入；UI 只认本类 API。

## vendor 共用；页面按平台隔离（linux.html / macos.html）
const XTERM_JS := "res://addons/cursor_agent_term/xterm_web/xterm.js"
const XTERM_LINUX := "res://addons/cursor_agent_term/xterm_web/linux.html"
const XTERM_MACOS := "res://addons/cursor_agent_term/xterm_web/macos.html"

var _host_script: String = ""
var _python_bin: String = "python3"
var _peer: StreamPeerTCP
var _pid: int = -1
var _port_file: String = ""
var _alive: bool = false
var _child_alive: bool = false
var _attached: bool = false
var _rx: String = ""


func _init(host_script_res: String = "", python_bin: String = "python3") -> void:
	_host_script = host_script_res
	_python_bin = python_bin if not python_bin.is_empty() else "python3"


static func _res_ok(res_path: String) -> bool:
	return FileAccess.file_exists(ProjectSettings.globalize_path(res_path))


static func xterm_vendor_ok() -> bool:
	return (
		_res_ok(XTERM_JS)
		and _res_ok("res://addons/cursor_agent_term/xterm_web/xterm.css")
		and _res_ok("res://addons/cursor_agent_term/xterm_web/addon-fit.js")
	)


static func linux_ok() -> bool:
	if not xterm_vendor_ok() or not _res_ok(XTERM_LINUX):
		return false
	var script := ProjectSettings.globalize_path("res://addons/cursor_agent_term/linux_embed_host.py")
	if not FileAccess.file_exists(script):
		return false
	var out: Array = []
	var code := OS.execute(
		"python3",
		PackedStringArray([
			"-c",
			"import gi; gi.require_version('Gtk','3.0'); gi.require_version('WebKit2','4.1'); "
			+ "from gi.repository import Gtk,WebKit2; print('ok')",
		]),
		out,
		true,
	)
	if code != 0:
		return false
	return "\n".join(out).contains("ok")


static func macos_ok(python_bin: String) -> bool:
	if OS.get_name() != "macOS":
		return false
	if not xterm_vendor_ok() or not _res_ok(XTERM_MACOS):
		return false
	var script := ProjectSettings.globalize_path("res://addons/cursor_agent_term/macos_embed_host.py")
	if not FileAccess.file_exists(script):
		return false
	if python_bin.is_empty() or not FileAccess.file_exists(python_bin):
		return false
	var out: Array = []
	var code := OS.execute(
		python_bin,
		PackedStringArray(["-c", "from AppKit import NSWindow; import WebKit; print('ok')"]),
		out,
		true,
	)
	if code != 0:
		return false
	return "\n".join(out).contains("ok")


func is_running() -> bool:
	return _alive and _peer != null and _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED


func has_child() -> bool:
	return _child_alive


func start_host() -> Error:
	if is_running():
		return OK
	if _host_script.is_empty():
		return ERR_INVALID_PARAMETER
	var script := ProjectSettings.globalize_path(_host_script)
	if not FileAccess.file_exists(script):
		push_error("cursor_agent_term: 缺少宿主 %s" % script)
		return ERR_FILE_NOT_FOUND
	if not FileAccess.file_exists(_python_bin) and _python_bin != "python3":
		# python3 走 PATH
		if _python_bin.contains("/"):
			push_error("cursor_agent_term: Python 不存在 %s" % _python_bin)
			return ERR_FILE_NOT_FOUND

	_port_file = OS.get_temp_dir().path_join("gcat_embed_%s.port" % str(Time.get_ticks_msec()))
	if FileAccess.file_exists(_port_file):
		DirAccess.remove_absolute(_port_file)

	_pid = OS.create_process(_python_bin, PackedStringArray([script, _port_file]))
	if _pid <= 0:
		push_error("cursor_agent_term: 无法启动宿主")
		return FAILED

	var port := _wait_port(5000)
	if port <= 0:
		push_error("cursor_agent_term: 宿主端口未就绪")
		stop_host()
		return ERR_TIMEOUT

	_peer = StreamPeerTCP.new()
	var err := _peer.connect_to_host("127.0.0.1", port)
	if err != OK:
		push_error("cursor_agent_term: 连接宿主失败 %s" % err)
		stop_host()
		return err

	var deadline := Time.get_ticks_msec() + 4000
	while Time.get_ticks_msec() < deadline:
		_peer.poll()
		if _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			break
		OS.delay_msec(20)
	if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		push_error("cursor_agent_term: 宿主 TCP 未连通")
		stop_host()
		return ERR_CANT_CONNECT

	_alive = true
	_child_alive = false
	_attached = false
	deadline = Time.get_ticks_msec() + 4000
	while Time.get_ticks_msec() < deadline:
		var ev := poll_event()
		if ev.get("event") == "ready":
			return OK
		OS.delay_msec(20)
	return OK


func stop_host() -> void:
	if _peer != null and _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		_send({"cmd": "quit"})
		OS.delay_msec(40)
		_peer.disconnect_from_host()
	_peer = null
	if _pid > 0:
		OS.kill(_pid)
	_pid = -1
	_alive = false
	_child_alive = false
	_attached = false
	_rx = ""
	if not _port_file.is_empty() and FileAccess.file_exists(_port_file):
		DirAccess.remove_absolute(_port_file)
	_port_file = ""


func attach_to_godot() -> Error:
	if not is_running():
		return ERR_DOES_NOT_EXIST
	if _attached:
		return OK
	var xid: int = int(DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE))
	_send({"cmd": "attach", "xid": xid})
	var deadline := Time.get_ticks_msec() + 2000
	while Time.get_ticks_msec() < deadline:
		var ev := poll_event()
		var name := str(ev.get("event", ""))
		if name == "attached":
			_attached = true
			return OK
		if name == "error":
			push_error("cursor_agent_term: attach %s" % str(ev.get("message", "")))
			return FAILED
		OS.delay_msec(10)
	push_warning("cursor_agent_term: attach 回包超时，继续尝试显示")
	_attached = true
	return OK


func is_attached() -> bool:
	return _attached


func set_geom(x: int, y: int, w: int, h: int) -> void:
	_send({"cmd": "geom", "x": x, "y": y, "w": w, "h": h})


func set_slot_geom(d: Dictionary) -> void:
	var msg := {"cmd": "geom", "mode": str(d.get("mode", "rel"))}
	for k in ["fx", "fy", "fw", "fh", "x", "y", "w", "h"]:
		if d.has(k):
			msg[k] = d[k]
	_send(msg)


func hide() -> void:
	_send({"cmd": "hide"})


func remount() -> void:
	_send({"cmd": "remount"})


func refresh_paint() -> void:
	_send({"cmd": "refresh_paint"})


func focus() -> void:
	_send({"cmd": "focus"})


func scroll_bottom() -> void:
	_send({"cmd": "scroll_bottom"})


func spawn(argv: PackedStringArray, cwd: String) -> Error:
	if not is_running():
		var e: Error = start_host()
		if e != OK:
			return e
	var arr: Array = []
	for a in argv:
		arr.append(a)
	_send({"cmd": "spawn", "argv": arr, "cwd": cwd})
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		var ev := poll_event()
		var name := str(ev.get("event", ""))
		if name == "spawned":
			_child_alive = true
			return OK
		if name == "error":
			_child_alive = false
			push_error("cursor_agent_term: spawn %s" % str(ev.get("message", "")))
			return FAILED
		OS.delay_msec(20)
	_child_alive = false
	push_error("cursor_agent_term: spawn 超时")
	return ERR_TIMEOUT


func write(text: String) -> Error:
	if not is_running():
		return ERR_DOES_NOT_EXIST
	_send({"cmd": "write", "data": text})
	return OK


func send_image_paste() -> Error:
	return write(String.chr(0x16))


func paste() -> Error:
	if not is_running():
		return ERR_DOES_NOT_EXIST
	_send({"cmd": "paste"})
	return OK


func poll_event() -> Dictionary:
	if _peer == null:
		return {}
	_peer.poll()
	if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		_alive = false
		_child_alive = false
		return {}
	var avail := _peer.get_available_bytes()
	if avail > 0:
		var chunk := _peer.get_utf8_string(avail)
		_rx += chunk
	var nl := _rx.find("\n")
	if nl < 0:
		return {}
	var line := _rx.substr(0, nl).strip_edges()
	_rx = _rx.substr(nl + 1)
	if line.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(line)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	var d: Dictionary = parsed
	if d.get("event") == "child_exited":
		_child_alive = false
	return d


func _wait_port(timeout_ms: int) -> int:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if FileAccess.file_exists(_port_file):
			var f := FileAccess.open(_port_file, FileAccess.READ)
			if f:
				var t := f.get_as_text().strip_edges()
				f = null
				if t.is_valid_int():
					return int(t)
		OS.delay_msec(20)
	return -1


func _send(msg: Dictionary) -> void:
	if _peer == null:
		return
	_peer.poll()
	if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return
	var line := JSON.stringify(msg) + "\n"
	var err := _peer.put_data(line.to_utf8_buffer())
	if err != OK:
		push_warning("cursor_agent_term: TCP 发送失败 %s" % err)
	_peer.poll()
