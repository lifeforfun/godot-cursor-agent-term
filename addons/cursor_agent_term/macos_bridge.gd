@tool
class_name CursorAgentMacosBridge
extends RefCounted
## macOS 专用：启动 macos_embed_host.py，经 TCP NDJSON 控制叠窗终端。仅由 plat_macos 引用。

const HOST_SCRIPT := "res://addons/cursor_agent_term/macos_embed_host.py"
const ASSETS_INDEX := "res://addons/cursor_agent_term/macos_xterm/index.html"

var _peer: StreamPeerTCP
var _pid: int = -1
var _port_file: String = ""
var _alive: bool = false
var _child_alive: bool = false
var _attached: bool = false
var _rx: String = ""


static func _venv_python() -> String:
	var env_py := OS.get_environment("GCAT_MACOS_PYTHON").strip_edges()
	if not env_py.is_empty() and FileAccess.file_exists(env_py):
		return env_py
	var home := OS.get_environment("HOME").strip_edges()
	if home.is_empty():
		return ""
	var p := home.path_join(".cache/cursor-agent-term/macos-venv/bin/python")
	if FileAccess.file_exists(p):
		return p
	return ""


static func available() -> bool:
	if OS.get_name() != "macOS":
		return false
	if not FileAccess.file_exists(ProjectSettings.globalize_path(HOST_SCRIPT)):
		return false
	if not FileAccess.file_exists(ProjectSettings.globalize_path(ASSETS_INDEX)):
		return false
	var py := _venv_python()
	if py.is_empty():
		return false
	var out: Array = []
	var code := OS.execute(
		py,
		PackedStringArray([
			"-c",
			"from AppKit import NSWindow; import WebKit; print('ok')",
		]),
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
	var script := ProjectSettings.globalize_path(HOST_SCRIPT)
	if not FileAccess.file_exists(script):
		push_error("cursor_agent_term: 缺少 macos_embed_host.py")
		return ERR_FILE_NOT_FOUND
	var py := _venv_python()
	if py.is_empty():
		push_error("cursor_agent_term: 缺少 macOS 宿主 Python（~/.cache/cursor-agent-term/macos-venv）")
		return ERR_FILE_NOT_FOUND

	_port_file = OS.get_temp_dir().path_join("gcat_macos_%s.port" % str(Time.get_ticks_msec()))
	if FileAccess.file_exists(_port_file):
		DirAccess.remove_absolute(_port_file)

	_pid = OS.create_process(py, PackedStringArray([script, _port_file]))
	if _pid <= 0:
		push_error("cursor_agent_term: 无法启动 macos_embed_host.py")
		return FAILED

	var port := _wait_port(5000)
	if port <= 0:
		push_error("cursor_agent_term: macOS 终端端口未就绪")
		stop_host()
		return ERR_TIMEOUT

	_peer = StreamPeerTCP.new()
	var err := _peer.connect_to_host("127.0.0.1", port)
	if err != OK:
		push_error("cursor_agent_term: 连接 macOS 宿主失败 %s" % err)
		stop_host()
		return err

	var deadline := Time.get_ticks_msec() + 4000
	while Time.get_ticks_msec() < deadline:
		_peer.poll()
		if _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			break
		OS.delay_msec(20)
	if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		push_error("cursor_agent_term: macOS 宿主 TCP 未连通")
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
			push_error("cursor_agent_term: macos attach %s" % str(ev.get("message", "")))
			return FAILED
		OS.delay_msec(10)
	push_warning("cursor_agent_term: macos attach 回包超时，继续尝试显示")
	_attached = true
	return OK


func is_attached() -> bool:
	return _attached


func set_geom(x: int, y: int, w: int, h: int) -> void:
	_send({"cmd": "geom", "x": x, "y": y, "w": w, "h": h})


func set_slot_geom(d: Dictionary) -> void:
	## macOS：相对视口比例 + 绝对调试字段
	var msg := {"cmd": "geom", "mode": str(d.get("mode", "rel"))}
	for k in ["fx", "fy", "fw", "fh", "x", "y", "w", "h"]:
		if d.has(k):
			msg[k] = d[k]
	_send(msg)


func hide() -> void:
	_send({"cmd": "hide"})


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
			push_error("cursor_agent_term: macos spawn %s" % str(ev.get("message", "")))
			return FAILED
		OS.delay_msec(20)
	_child_alive = true
	return OK


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
		push_warning("cursor_agent_term: macOS TCP 发送失败 %s" % err)
	_peer.poll()
