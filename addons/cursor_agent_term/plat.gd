@tool
class_name CursorAgentPlat
extends RefCounted
## 平台门面：唯一入口。业务只 call get()，禁止再写 OS.get_name() 分支。

const LinuxScript := preload("res://addons/cursor_agent_term/plat_linux.gd")
const MacosScript := preload("res://addons/cursor_agent_term/plat_macos.gd")
const WindowsScript := preload("res://addons/cursor_agent_term/plat_windows.gd")

static var _inst: RefCounted = null


static func get_plat() -> RefCounted:
	if _inst != null:
		return _inst
	match OS.get_name():
		"Windows":
			_inst = WindowsScript.new()
		"macOS":
			_inst = MacosScript.new()
		"Linux", "FreeBSD", "NetBSD", "OpenBSD":
			_inst = LinuxScript.new()
		_:
			# 未知 Unix 先走 Linux 探测（VTE/screen）；不行由 hint 提示
			_inst = LinuxScript.new()
	return _inst


static func reset() -> void:
	## 测试或热重载用
	_inst = null
