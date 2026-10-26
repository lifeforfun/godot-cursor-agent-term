@tool
class_name CursorAgentSessionStore
extends RefCounted
## 按工程隔离会话：resume 只认本插件写入的绑定 id，绝不扫同工程下 IDE 的其它聊天。

const PlatScript := preload("res://addons/cursor_agent_term/plat.gd")
const CACHE_TTL_MS := 30_000
const FRESH_SESSION_GRACE_MS := 15_000
const PERSISTED_SESSION_FILE := ".plugin-bound-session"
const PROJECT_BIND_REL := ".godot/cursor_agent_term.session"

var _cache: Dictionary = {} # hash -> {id, at_ms}
var _active: Dictionary = {} # hash -> id


func find_last_session_id(project_path: String, preferred: String = "") -> String:
	if project_path.is_empty():
		return ""
	var project := normalize_project_path(project_path)
	var wh := _workspace_hash(project)
	var root := _chats_root(wh)

	# 1) 调用方 preferred
	if not preferred.is_empty() and _session_exists(root, preferred):
		_remember(wh, preferred, project)
		return preferred

	# 2) 内存
	if _active.has(wh):
		var remembered: String = _active[wh]
		if _session_exists(root, remembered):
			return remembered
		_active.erase(wh)

	# 3) 工程内绑定（换工程/重开最稳）
	var local_id := _read_project_bind(project)
	if not local_id.is_empty() and _session_exists(root, local_id):
		_remember(wh, local_id, project)
		return local_id

	# 4) ~/.cursor/chats/<hash>/.plugin-bound-session（仅本插件写入）
	var persisted := _read_persisted(root)
	if not persisted.is_empty() and _session_exists(root, persisted):
		_remember(wh, persisted, project)
		return persisted
	if not persisted.is_empty():
		_clear_persisted(root)
		_clear_project_bind(project)

	if _cache.has(wh):
		var c: Dictionary = _cache[wh]
		if Time.get_ticks_msec() - int(c.get("at_ms", 0)) < CACHE_TTL_MS:
			var cid: String = str(c.get("id", ""))
			if _session_exists(root, cid):
				_remember(wh, cid, project)
				return cid
			_cache.erase(wh)

	# 无插件绑定 → 空，让 agent 开新会话；禁止扫 chats 里 IDE 的最近对话
	return ""


func record_active(project_path: String, session_id: String) -> void:
	if project_path.is_empty() or session_id.is_empty():
		return
	var project := normalize_project_path(project_path)
	_remember(_workspace_hash(project), session_id, project)


func invalidate(project_path: String) -> void:
	if project_path.is_empty():
		return
	var project := normalize_project_path(project_path)
	var wh := _workspace_hash(project)
	_cache.erase(wh)
	_active.erase(wh)
	_clear_persisted(_chats_root(wh))
	_clear_project_bind(project)


func adopt_discovered(
	project_path: String,
	bound_session_id: String,
	session_started_at_ms: int = 0,
	require_fresh: bool = false,
) -> String:
	if project_path.is_empty():
		return ""
	var project := normalize_project_path(project_path)
	var wh := _workspace_hash(project)
	var root := _chats_root(wh)

	if not bound_session_id.is_empty() and _session_exists(root, bound_session_id):
		_remember(wh, bound_session_id, project)
		return bound_session_id

	# 新开会话：只认「本轮启动后创建」的目录，避免把 IDE 正在更新的同工程聊天认领进来
	if require_fresh:
		var discovered := _scan_latest_for_project(
			root, project, session_started_at_ms, true, false
		)
		if not discovered.is_empty():
			_remember(wh, discovered, project)
			return discovered
	return ""


func workspace_hash(project_path: String) -> String:
	return _workspace_hash(normalize_project_path(project_path))


func normalize_project_path(project_path: String) -> String:
	var p := project_path.strip_edges().rstrip("/").rstrip("\\")
	if p.is_empty():
		return ""
	# 跨机器：优先 python3 realpath（不依赖 GNU realpath -m）
	var out: Array = []
	var py := OS.execute(
		"python3",
		PackedStringArray(["-c", "import os,sys; print(os.path.realpath(sys.argv[1]))", p]),
		out,
		true,
	)
	if py == 0 and not out.is_empty():
		var rp := str(out[0]).strip_edges()
		if not rp.is_empty():
			return rp.rstrip("/").rstrip("\\")
	out.clear()
	if OS.execute("realpath", ["-m", p], out, true) == 0 and not out.is_empty():
		var rp2 := str(out[0]).strip_edges()
		if not rp2.is_empty():
			return rp2.rstrip("/").rstrip("\\")
	return p


func _workspace_hash(project_path: String) -> String:
	return _md5_hex(normalize_project_path(project_path))


func _home_dir() -> String:
	return str(PlatScript.get_plat().home())


func _chats_root(workspace_hash: String) -> String:
	## cursor-agent 默认落盘：~/.cursor/chats/<hash>/
	var home := _home_dir()
	if home.is_empty():
		return ""
	return home.path_join(".cursor/chats").path_join(workspace_hash)


func _md5_hex(input: String) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	ctx.update(input.to_utf8_buffer())
	return ctx.finish().hex_encode()


func _session_exists(chats_root: String, session_id: String) -> bool:
	if chats_root.is_empty() or session_id.is_empty():
		return false
	return DirAccess.dir_exists_absolute(chats_root.path_join(session_id))


func _remember(workspace_hash: String, session_id: String, project_path: String = "") -> void:
	_cache[workspace_hash] = {"id": session_id, "at_ms": Time.get_ticks_msec()}
	_active[workspace_hash] = session_id
	_write_persisted(_chats_root(workspace_hash), session_id)
	if not project_path.is_empty():
		_write_project_bind(project_path, session_id)


func _project_bind_path(project_path: String) -> String:
	return normalize_project_path(project_path).path_join(PROJECT_BIND_REL)


func _read_project_bind(project_path: String) -> String:
	var path := _project_bind_path(project_path)
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text().strip_edges()


func _write_project_bind(project_path: String, session_id: String) -> void:
	var path := _project_bind_path(project_path)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(session_id)


func _clear_project_bind(project_path: String) -> void:
	var path := _project_bind_path(project_path)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


func _read_persisted(chats_root: String) -> String:
	var path := chats_root.path_join(PERSISTED_SESSION_FILE)
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text().strip_edges()


func _write_persisted(chats_root: String, session_id: String) -> void:
	DirAccess.make_dir_recursive_absolute(chats_root)
	var f := FileAccess.open(chats_root.path_join(PERSISTED_SESSION_FILE), FileAccess.WRITE)
	if f:
		f.store_string(session_id)


func _clear_persisted(chats_root: String) -> void:
	var path := chats_root.path_join(PERSISTED_SESSION_FILE)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


func _scan_latest_for_project(
	chats_root: String,
	project_path: String,
	session_started_at_ms: int,
	require_fresh: bool,
	require_conversation: bool,
) -> String:
	if not DirAccess.dir_exists_absolute(chats_root):
		return ""
	var da := DirAccess.open(chats_root)
	if da == null:
		return ""
	var best_id := ""
	var best_updated := -1
	var project_n := normalize_project_path(project_path)
	da.list_dir_begin()
	var name := da.get_next()
	while name != "":
		if da.current_is_dir() and not name.begins_with("."):
			var dir_path := chats_root.path_join(name)
			var meta := _read_meta(dir_path)
			if require_conversation and not meta.get("has_conversation", false):
				name = da.get_next()
				continue
			var cwd_raw := str(meta.get("cwd", ""))
			if not cwd_raw.is_empty() and normalize_project_path(cwd_raw) != project_n:
				name = da.get_next()
				continue
			if require_fresh and not _is_created_after(meta, dir_path, session_started_at_ms):
				name = da.get_next()
				continue
			# 新会话优先按创建时间；否则按更新时间
			var rank: int = int(meta.get("created_at_ms", 0))
			if rank <= 0:
				rank = int(meta.get("updated_at_ms", 0))
			if rank <= 0:
				rank = int(FileAccess.get_modified_time(dir_path)) * 1000
			if rank >= best_updated:
				best_updated = rank
				best_id = name
		name = da.get_next()
	da.list_dir_end()
	return best_id


func _read_meta(session_dir: String) -> Dictionary:
	var path := session_dir.path_join("meta.json")
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var text := f.get_as_text()
	var has_conv := text.contains('"hasConversation": true') or text.contains('"hasConversation":true')
	var updated := _meta_int(text, "updatedAtMs")
	var created := _meta_int(text, "createdAtMs")
	var cwd := ""
	var re_c := RegEx.new()
	re_c.compile('"cwd"\\s*:\\s*"([^"]*)"')
	var m_c := re_c.search(text)
	if m_c:
		cwd = m_c.get_string(1).replace("\\\\", "\\")
	return {
		"has_conversation": has_conv,
		"updated_at_ms": updated,
		"created_at_ms": created,
		"cwd": cwd,
	}


func _meta_int(text: String, key: String) -> int:
	var re := RegEx.new()
	re.compile('"%s"\\s*:\\s*(\\d+)' % key)
	var m := re.search(text)
	if m:
		return int(m.get_string(1))
	return 0


func _is_created_after(meta: Dictionary, session_dir: String, session_started_at_ms: int) -> bool:
	## 用 createdAtMs 判断「本轮新开」，不用 updatedAtMs（IDE 同工程聊天会一直刷新）
	if session_started_at_ms <= 0:
		return true
	var threshold := session_started_at_ms - FRESH_SESSION_GRACE_MS
	var created: int = int(meta.get("created_at_ms", 0))
	if created <= 0:
		created = int(FileAccess.get_modified_time(session_dir)) * 1000
	return created >= threshold
