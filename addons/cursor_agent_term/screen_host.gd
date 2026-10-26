@tool
class_name CursorAgentScreenHost
extends RefCounted
## Linux 专用回退：GNU screen 托管 cursor-agent + 系统终端附着。仅由 plat_linux 引用。


func is_alive(session: String) -> bool:
	if session.is_empty():
		return false
	var out: Array = []
	OS.execute("screen", ["-ls"], out, true)
	var text := "\n".join(out)
	# screen -ls 行形如： "\t123.gcat_xxxx\t(Detached)"
	return text.contains("." + session) or text.contains("\t" + session) or text.contains(session + "\t")


func start(session: String, cwd: String, agent_cmd: PackedStringArray) -> Error:
	if session.is_empty() or agent_cmd.is_empty():
		return ERR_INVALID_PARAMETER
	if is_alive(session):
		return OK
	# 组装：cd 到工程后 exec cursor-agent …
	var parts: PackedStringArray = []
	for a in agent_cmd:
		parts.append(_shell_quote(a))
	var inner := "cd %s && exec %s" % [_shell_quote(cwd), " ".join(parts)]
	var shell := _resolve_shell()
	var args: PackedStringArray = ["-dmS", session, shell, "-lc", inner]
	var out: Array = []
	var code := OS.execute("screen", args, out, true)
	if code != 0:
		push_error("cursor_agent_term: screen 启动失败 code=%s out=%s" % [code, "\n".join(out)])
		return FAILED
	return OK


func stop(session: String) -> void:
	if session.is_empty():
		return
	OS.execute("screen", ["-S", session, "-X", "quit"], [], true)


func stuff(session: String, text: String) -> Error:
	if session.is_empty() or not is_alive(session):
		return ERR_DOES_NOT_EXIST
	# screen stuff 会把字符串打进会话；用 -X stuff
	var code := OS.execute("screen", ["-S", session, "-X", "stuff", text], [], true)
	return OK if code == 0 else FAILED


func send_image_paste(session: String) -> Error:
	## cursor-agent：剪贴板有图时发 0x16（Ctrl-V / SYN）触发贴图。
	## screen caret：^V == Ctrl-V
	return stuff(session, "^V")


func open_system_terminal(session: String) -> Error:
	if session.is_empty():
		return ERR_INVALID_PARAMETER
	if not is_alive(session):
		return ERR_DOES_NOT_EXIST
	var term := _resolve_terminal()
	if term.is_empty():
		push_error("cursor_agent_term: 未找到可用终端模拟器（gnome-terminal / kitty / xterm 等）")
		return ERR_FILE_NOT_FOUND
	var shell := _resolve_shell()
	var cmd := "%s -- screen -r %s" % [_shell_quote(term), _shell_quote(session)]
	var pid := OS.create_process(shell, PackedStringArray(["-lc", cmd]))
	if pid <= 0:
		pid = OS.create_process(
			shell,
			PackedStringArray(["-lc", "%s -e screen -r %s" % [_shell_quote(term), _shell_quote(session)]]),
		)
	return OK if pid > 0 else FAILED


func _resolve_shell() -> String:
	for c in ["bash", "sh"]:
		var p := _which(c)
		if not p.is_empty():
			return p
	return "sh"


func _resolve_terminal() -> String:
	for c in [
		"gnome-terminal",
		"x-terminal-emulator",
		"xfce4-terminal",
		"konsole",
		"kitty",
		"alacritty",
		"wezterm",
		"xterm",
	]:
		var p := _which(c)
		if not p.is_empty():
			return p
	return ""


func _which(name: String) -> String:
	var out: Array = []
	if OS.execute("sh", ["-c", "command -v %s" % name], out, true) != 0 or out.is_empty():
		return ""
	return str(out[0]).strip_edges()


func _shell_quote(s: String) -> String:
	return "'" + s.replace("'", "'\"'\"'") + "'"
