@tool
class_name CursorAgentExtHostStub
extends RefCounted
## 非 Linux 外挂终端占位：接口对齐 screen_host，逻辑未实现处一律 TODO。

var _os: String = ""


func _init(os_id: String = "") -> void:
	_os = os_id


func is_alive(_session: String) -> bool:
	return false


func start(_session: String, _cwd: String, _agent_cmd: PackedStringArray) -> Error:
	# TODO: macOS→Terminal/iTerm；Windows→Windows Terminal；启动并附着 cursor-agent
	push_error("cursor_agent_term: %s 外挂终端尚未实现" % _os_label())
	return ERR_UNAVAILABLE


func stop(_session: String) -> void:
	# TODO: 结束外挂会话
	pass


func stuff(_session: String, _text: String) -> Error:
	# TODO: 向会话写入文本
	return ERR_UNAVAILABLE


func send_image_paste(_session: String) -> Error:
	# TODO: 图片粘贴
	return ERR_UNAVAILABLE


func open_system_terminal(_session: String) -> Error:
	# TODO: 打开系统终端附着会话
	push_error("cursor_agent_term: %s 打开系统终端尚未实现" % _os_label())
	return ERR_UNAVAILABLE


func _os_label() -> String:
	return _os if not _os.is_empty() else "当前系统"
