@tool
class_name CursorAgentMacosHost
extends RefCounted
## macOS 专用回退：tmux（优先）/ screen 托管 cursor-agent + 系统终端附着。
## 仅由 plat_macos 引用；禁止从 Linux/Windows 路径调用。


enum Backend { NONE, TMUX, SCREEN }

var _backend: int = Backend.NONE


func _init() -> void:
	if not _which("tmux").is_empty():
		_backend = Backend.TMUX
	elif not _which("screen").is_empty():
		_backend = Backend.SCREEN
	else:
		_backend = Backend.NONE


func backend_id() -> String:
	match _backend:
		Backend.TMUX:
			return "tmux"
		Backend.SCREEN:
			return "screen"
		_:
			return ""


func is_alive(session: String) -> bool:
	if session.is_empty() or _backend == Backend.NONE:
		return false
	if _backend == Backend.TMUX:
		return OS.execute("tmux", PackedStringArray(["has-session", "-t", session]), [], true) == 0
	var out: Array = []
	OS.execute("screen", PackedStringArray(["-ls"]), out, true)
	var text := "\n".join(out)
	return text.contains("." + session) or text.contains("\t" + session) or text.contains(session + "\t")


func start(session: String, cwd: String, agent_cmd: PackedStringArray) -> Error:
	if session.is_empty() or agent_cmd.is_empty() or _backend == Backend.NONE:
		return ERR_INVALID_PARAMETER
	if is_alive(session):
		return OK
	var parts: PackedStringArray = []
	for a in agent_cmd:
		parts.append(_shell_quote(a))
	var inner := "cd %s && exec %s" % [_shell_quote(cwd), " ".join(parts)]
	var shell := _resolve_shell()
	var out: Array = []
	var code: int = -1
	if _backend == Backend.TMUX:
		code = OS.execute(
			"tmux",
			PackedStringArray(["new-session", "-d", "-s", session, shell, "-lc", inner]),
			out,
			true,
		)
	else:
		code = OS.execute(
			"screen",
			PackedStringArray(["-dmS", session, shell, "-lc", inner]),
			out,
			true,
		)
	if code != 0:
		push_error(
			"cursor_agent_term: macOS %s 启动失败 code=%s out=%s"
			% [backend_id(), code, "\n".join(out)]
		)
		return FAILED
	return OK


func stop(session: String) -> void:
	if session.is_empty() or _backend == Backend.NONE:
		return
	if _backend == Backend.TMUX:
		OS.execute("tmux", PackedStringArray(["kill-session", "-t", session]), [], true)
	else:
		OS.execute("screen", PackedStringArray(["-S", session, "-X", "quit"]), [], true)


func stuff(session: String, text: String) -> Error:
	if session.is_empty() or not is_alive(session):
		return ERR_DOES_NOT_EXIST
	if _backend == Backend.TMUX:
		# -l：按字面量发送，避免按键名解析
		var code := OS.execute(
			"tmux",
			PackedStringArray(["send-keys", "-t", session, "-l", "--", text]),
			[],
			true,
		)
		return OK if code == 0 else FAILED
	var code2 := OS.execute(
		"screen",
		PackedStringArray(["-S", session, "-X", "stuff", text]),
		[],
		true,
	)
	return OK if code2 == 0 else FAILED


func send_image_paste(session: String) -> Error:
	## cursor-agent：剪贴板有图时发 0x16（Ctrl-V）触发贴图。
	if session.is_empty() or not is_alive(session):
		return ERR_DOES_NOT_EXIST
	if _backend == Backend.TMUX:
		var code := OS.execute(
			"tmux",
			PackedStringArray(["send-keys", "-t", session, "C-v"]),
			[],
			true,
		)
		return OK if code == 0 else FAILED
	return stuff(session, "^V")


func open_system_terminal(session: String) -> Error:
	if session.is_empty():
		return ERR_INVALID_PARAMETER
	if not is_alive(session):
		return ERR_DOES_NOT_EXIST
	var attach := _attach_cmd(session)
	if attach.is_empty():
		return FAILED

	# 1) 独立终端模拟器（若已装）
	for bin in ["kitty", "alacritty", "wezterm"]:
		var p := _which(bin)
		if p.is_empty():
			continue
		var pid := OS.create_process(p, PackedStringArray(["-e", "sh", "-lc", attach]))
		if pid > 0:
			return OK

	# 2) iTerm
	if DirAccess.dir_exists_absolute("/Applications/iTerm.app"):
		var iterm := (
			"tell application \"iTerm\"\n"
			+ "  activate\n"
			+ "  create window with default profile command %s\n" % _as_quote(attach)
			+ "end tell"
		)
		if OS.execute("osascript", PackedStringArray(["-e", iterm]), [], true) == 0:
			return OK

	# 3) Terminal.app（系统自带）
	if _terminal_app_path().is_empty():
		push_error("cursor_agent_term: 未找到 Terminal.app / iTerm / kitty 等")
		return ERR_FILE_NOT_FOUND
	var script := (
		"tell application \"Terminal\"\n"
		+ "  activate\n"
		+ "  do script %s\n" % _as_quote(attach)
		+ "end tell"
	)
	var code := OS.execute("osascript", PackedStringArray(["-e", script]), [], true)
	if code != 0:
		push_error("cursor_agent_term: 打开 Terminal.app 失败 code=%s" % code)
		return FAILED
	return OK


func _attach_cmd(session: String) -> String:
	if _backend == Backend.TMUX:
		return "tmux attach -t %s" % _shell_quote(session)
	if _backend == Backend.SCREEN:
		return "screen -r %s" % _shell_quote(session)
	return ""


func _terminal_app_path() -> String:
	for p in [
		"/System/Applications/Utilities/Terminal.app",
		"/Applications/Utilities/Terminal.app",
		"/Applications/Terminal.app",
	]:
		if DirAccess.dir_exists_absolute(p):
			return p
	return ""


func _resolve_shell() -> String:
	for c in ["zsh", "bash", "sh"]:
		var p := _which(c)
		if not p.is_empty():
			return p
	return "/bin/zsh"


func _which(name: String) -> String:
	if name.is_empty() or name.contains("/") or name.contains(" "):
		return ""
	var out: Array = []
	if OS.execute("sh", ["-c", "command -v %s" % name], out, true) != 0 or out.is_empty():
		return ""
	return str(out[0]).strip_edges()


func _shell_quote(s: String) -> String:
	return "'" + s.replace("'", "'\"'\"'") + "'"


func _as_quote(s: String) -> String:
	## AppleScript 字符串字面量
	return "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
