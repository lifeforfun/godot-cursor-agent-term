@tool
extends Control
## Dock 槽位 + xterm 叠窗：会话 / 注入路径 / 跟 dock；弹层与失焦时藏叠窗。

const SessionStoreScript := preload("res://addons/cursor_agent_term/session_store.gd")
const LauncherScript := preload("res://addons/cursor_agent_term/launcher.gd")
const EditorCtxScript := preload("res://addons/cursor_agent_term/editor_ctx.gd")
const PlatScript := preload("res://addons/cursor_agent_term/plat.gd")
const GEOM_EPS_PX := 3

var _plat
var _store
var _screen
var _embed
var _use_embed: bool = false
var _slot: ColorRect
var _bound_session_id: String = ""
var _session_started_at_ms: int = 0
var _auto_started: bool = false
var _last_geom: Rect2i = Rect2i()
var _term_placed: bool = false
var _was_panel_active: bool = false
var _geom_sync_queued: bool = false
var _editor_ready_seen: bool = false
var _suppress_popup: bool = false
var _suppress_blur: bool = false
var _first_remount_done: bool = false
var _place_busy: bool = false
const _DBG_PATH := "/tmp/gcat_linux_debug.log"


func _dbg(tag: String, msg: String, extra: Dictionary = {}) -> void:
	## 与宿主同文件，黑窗联调
	var f := FileAccess.open(_DBG_PATH, FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(_DBG_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	var row := {"t": Time.get_time_string_from_system(), "tag": tag, "msg": msg}
	for k in extra.keys():
		row[k] = extra[k]
	f.store_line(JSON.stringify(row))
	f.close()


func _ready() -> void:
	_plat = PlatScript.get_plat()
	_store = SessionStoreScript.new()
	if _plat.embed_ok():
		_embed = _plat.new_embed()
		_use_embed = _embed != null
	_screen = _plat.new_fallback()
	_build_ui()
	set_process(true)
	set_process_input(true)
	visibility_changed.connect(func() -> void: _refresh_active("panel-vis"))


func _exit_tree() -> void:
	if _use_embed and _embed:
		_embed.stop_host()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		## 点终端叠窗也会 FOCUS_OUT；勿在此 hide（日志里 app-blur 会立刻黑槽）。
		## 切到其它 App 由宿主 _poll_front 自己 park。
		_suppress_blur = true
		_dbg("G-FOCUS", "out", {})
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_suppress_blur = false
		_dbg("G-FOCUS", "in", {})
		_restore_overlay("focus-in")


func _editor_focused() -> bool:
	return not _suppress_blur


func _restore_overlay(reason: String) -> void:
	## FOCUS_IN / 弹层关闭后强制铺回（_refresh_active 在 active 未变时会直接 return）
	if not _use_embed or _embed == null:
		return
	if not _panel_slot_active():
		return
	if _suppress_popup or _editor_blocks_overlay():
		_suppress_popup = true
		_dbg("G-PLACE", "restore-blocked", {"reason": reason})
		return
	_dbg("G-PLACE", "restore", {"reason": reason, "placed": _term_placed, "running": _embed.is_running()})
	if not _embed.is_running() or not _term_placed:
		_ensure_placed(true)
		return
	_apply_geom(true)
	if _embed.has_method("refresh_paint"):
		_embed.refresh_paint()


func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_theme_constant_override("separation", 2)
	add_child(root)

	_slot = ColorRect.new()
	_slot.color = Color(0.08, 0.08, 0.08, 1)
	_slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_slot.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_slot.mouse_filter = Control.MOUSE_FILTER_STOP
	_slot.gui_input.connect(_on_slot_gui_input)
	_slot.resized.connect(func() -> void: on_dock_geom_event("slot-resized"))
	_slot.item_rect_changed.connect(func() -> void: on_dock_geom_event("slot-rect"))
	root.add_child(_slot)

	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 10)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.size_flags_vertical = Control.SIZE_SHRINK_END
	root.add_child(bar)

	_add_btn(bar, "开启会话", Callable(self, "_on_start_session"))
	_add_btn(bar, "注入路径", Callable(self, "_on_inject_path"))
	_add_btn(bar, "滚到底部", Callable(self, "_on_scroll_bottom"))
	if not _use_embed:
		_add_btn(bar, "打开终端", Callable(self, "_on_open_terminal"))


func _add_btn(parent: Node, text: String, cb: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.custom_minimum_size = Vector2(0, 26)
	b.add_theme_font_size_override("font_size", 13)
	b.add_theme_stylebox_override("normal", _btn_style(Color(0.16, 0.16, 0.16, 1), Color(0.55, 0.55, 0.55, 1)))
	b.add_theme_stylebox_override("hover", _btn_style(Color(0.22, 0.22, 0.22, 1), Color(0.72, 0.72, 0.72, 1)))
	b.add_theme_stylebox_override("pressed", _btn_style(Color(0.12, 0.12, 0.12, 1), Color(0.85, 0.85, 0.85, 1)))
	b.pressed.connect(cb)
	parent.add_child(b)


func _btn_style(bg: Color, border: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_border_width_all(1)
	sb.border_color = border
	sb.set_corner_radius_all(3)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 3
	sb.content_margin_bottom = 3
	return sb


func _process(_delta: float) -> void:
	EditorCtxScript.refresh_cache()
	if _use_embed and _embed:
		while true:
			var ev: Dictionary = _embed.poll_event()
			if ev.is_empty():
				break
			# mapped 只作提示；不再连环 remount
		_update_popup_suppress()


func _update_popup_suppress() -> void:
	if not _use_embed or _embed == null:
		_suppress_popup = false
		return
	var info := _editor_block_info()
	var block := not info.is_empty()
	if block:
		if not _suppress_popup:
			_suppress_popup = true
			_dbg("G-POPUP", "suppress", info)
			if _embed.is_running():
				_embed.hide()
				_dbg("G-HIDE", "popup", info)
		return
	if not _suppress_popup:
		return
	_suppress_popup = false
	_dbg("G-POPUP", "restore", {})
	_restore_overlay("popup-restore")


func _editor_tree_root() -> Node:
	var base: Control = EditorInterface.get_base_control()
	if base != null and base.get_tree() != null:
		return base.get_tree().root
	var tree := get_tree()
	return tree.root if tree != null else null


func _editor_blocks_overlay() -> bool:
	return not _editor_block_info().is_empty()


func _editor_block_info() -> Dictionary:
	## 返回挡层信息；空=不挡。去掉「任意 exclusive Window」扫射（Godot 4.7 会误判成永久黑槽）。
	if EditorInterface.is_playing_scene():
		return {"kind": "playing"}
	var root := _editor_tree_root()
	if root == null:
		return {}
	var main_win: Window = get_window()
	for cls_name in ["PopupMenu", "PopupPanel", "Popup", "AcceptDialog", "ConfirmationDialog", "FileDialog"]:
		for node in root.find_children("*", cls_name, true, false):
			if not (node is Window):
				continue
			var w := node as Window
			if w == main_win or not w.visible:
				continue
			if _is_tooltip_window(w):
				# Tooltip/EditorHelpBitTooltip 常挂 visible，勿当弹层（会永久 G-HIDE→黑槽）
				continue
			if _suppress_blur and (w is PopupMenu or w is PopupPanel or w is Popup):
				continue
			if w.size.x < 8 or w.size.y < 8:
				continue
			return _win_info(w, cls_name)
	return {}


func _win_info(w: Window, kind: String) -> Dictionary:
	return {
		"kind": kind,
		"cls": w.get_class(),
		"name": str(w.name),
		"w": int(w.size.x),
		"h": int(w.size.y),
		"exclusive": bool(w.exclusive),
	}


func _is_tooltip_window(w: Window) -> bool:
	var cls := w.get_class()
	return cls == "TooltipPanel" or cls.begins_with("Tooltip") or cls.ends_with("Tooltip")


func on_editor_ready() -> void:
	_editor_ready_seen = true
	await _bootstrap()


func on_dock_geom_event(reason: String) -> void:
	_schedule_geom_sync(reason)


func on_dock_layout_event(_layout: int) -> void:
	_schedule_geom_sync("layout")


func on_dock_closed() -> void:
	if _use_embed and _embed and _embed.is_running():
		_embed.hide()
	_was_panel_active = false


func on_dock_opened() -> void:
	_refresh_active("dock-opened")
	_schedule_geom_sync("dock-opened")


func on_dock_visibility_ping() -> void:
	_refresh_active("dock-vis")


func _refresh_active(reason: String) -> void:
	if not _use_embed or _embed == null:
		return
	var active := _panel_slot_active()
	if active == _was_panel_active:
		if not active and _embed.is_running():
			_embed.hide()
		return
	_was_panel_active = active
	if not active:
		if _embed.is_running():
			_embed.hide()
		return
	if _suppress_popup or _editor_blocks_overlay():
		_suppress_popup = true
		if not _embed.is_running() or not _term_placed:
			_ensure_placed(false)
		elif _embed.is_running():
			_embed.hide()
		return
	if _term_placed and _embed.is_running():
		_apply_geom()
		_maybe_first_remount()
	else:
		_ensure_placed(false)


func _schedule_geom_sync(reason: String) -> void:
	if _geom_sync_queued:
		return
	_geom_sync_queued = true
	call_deferred("_run_geom_sync", reason)


func _run_geom_sync(reason: String) -> void:
	_geom_sync_queued = false
	await get_tree().process_frame
	if not _use_embed or _embed == null:
		return
	_refresh_active("geom-" + reason)
	if not _panel_slot_active():
		return
	if _term_placed and _embed.is_running() and _embed.is_attached():
		_sync_geom_if_changed()
	elif _session_alive() or (_embed.is_running() and _editor_ready_seen):
		await _ensure_placed(false)


func _sync_geom_if_changed() -> void:
	if _suppress_popup or _editor_blocks_overlay():
		_suppress_popup = true
		_embed.hide()
		return
	if not _term_placed or _embed == null or not _embed.is_running() or not _embed.is_attached():
		return
	var r := _slot_screen_rect()
	if r.size.x < 8 or r.size.y < 8:
		return
	if _geom_near(_last_geom, r):
		return
	_apply_geom()


func _geom_near(a: Rect2i, b: Rect2i) -> bool:
	return (
		absi(a.position.x - b.position.x) <= GEOM_EPS_PX
		and absi(a.position.y - b.position.y) <= GEOM_EPS_PX
		and absi(a.size.x - b.size.x) <= GEOM_EPS_PX
		and absi(a.size.y - b.size.y) <= GEOM_EPS_PX
	)


func _bootstrap() -> void:
	if DisplayServer.get_name() == "headless":
		return
	if not _auto_started:
		_auto_started = true
		await _start_session_async(true, false)
	for _i in range(6):
		await get_tree().process_frame
		if _panel_slot_active():
			await _ensure_placed(false)
			if _term_placed:
				return
		await get_tree().create_timer(0.08).timeout
	if _use_embed and _embed and _embed.is_running() and not _term_placed:
		_embed.hide()


func _panel_slot_active() -> bool:
	if not visible or not is_visible_in_tree():
		return false
	if not _is_current_tab_page():
		return false
	if _slot == null:
		return false
	var gr := _slot.get_global_rect()
	return gr.size.x >= 32.0 and gr.size.y >= 32.0


func _is_current_tab_page() -> bool:
	var n: Node = self
	while n != null:
		var p: Node = n.get_parent()
		if p is TabContainer:
			var tc := p as TabContainer
			var cur: Control = tc.get_current_tab_control()
			if cur == null:
				return false
			return cur == n or cur.is_ancestor_of(n)
		n = p
	return true


func _slot_screen_rect() -> Rect2i:
	if _plat != null and _plat.has_method("slot_screen_rect"):
		return _plat.slot_screen_rect(_slot)
	return Rect2i()


func _apply_geom(allow_blur: bool = false) -> bool:
	if not allow_blur and (_suppress_blur or not _editor_focused()):
		return false
	if _suppress_popup or _editor_blocks_overlay():
		_suppress_popup = true
		if _embed:
			_embed.hide()
		return false
	if _embed == null or not _embed.is_running() or not _embed.is_attached():
		return false
	if _embed.has_method("set_slot_geom") and _plat != null and _plat.has_method("slot_geom_dict"):
		var d: Dictionary = _plat.slot_geom_dict(_slot)
		if d.is_empty() or float(d.get("fw", 0)) <= 0.0 or float(d.get("fh", 0)) <= 0.0:
			return false
		_last_geom = Rect2i(int(d.get("x", 0)), int(d.get("y", 0)), int(d.get("w", 0)), int(d.get("h", 0)))
		_embed.set_slot_geom(d)
		return true
	var r := _slot_screen_rect()
	if r.size.x < 8 or r.size.y < 8:
		return false
	_last_geom = r
	_embed.set_geom(r.position.x, r.position.y, r.size.x, r.size.y)
	return true


func _maybe_first_remount() -> void:
	## 对齐 macOS：首次只 refresh/remount-paint，禁止 hide+show（WebKit 会黑）
	if _first_remount_done or not _use_embed or _embed == null:
		return
	if not _editor_focused() or _suppress_popup or _suppress_blur:
		return
	_first_remount_done = true
	_dbg("G-PLACE", "first-remount", {})
	if _embed.has_method("remount"):
		_embed.remount()
	elif _embed.has_method("refresh_paint"):
		_embed.refresh_paint()


func _ensure_placed(force_restart_host: bool, grab_focus: bool = false) -> void:
	if _place_busy:
		return
	if not _use_embed or _embed == null:
		return
	if not _panel_slot_active():
		return
	_place_busy = true
	var blocked := _suppress_popup or _editor_blocks_overlay()
	await get_tree().process_frame
	await get_tree().process_frame

	var had_child: bool = _embed.has_child()
	if force_restart_host or not _embed.is_running():
		if _embed.is_running():
			_embed.stop_host()
			await get_tree().create_timer(0.05).timeout
		var e: Error = _embed.start_host()
		if e != OK:
			_place_busy = false
			return
		had_child = false
		_first_remount_done = false
	var att: Error = _embed.attach_to_godot()
	if att != OK:
		_place_busy = false
		return

	_term_placed = true
	if not had_child or not _session_alive():
		await _start_session_async(true, false)

	if blocked or _editor_blocks_overlay():
		_suppress_popup = true
		_embed.hide()
		_place_busy = false
		return

	if not _apply_geom():
		_place_busy = false
		return

	await get_tree().process_frame
	if not _editor_focused():
		_place_busy = false
		return
	_apply_geom()
	_maybe_first_remount()
	if grab_focus and _editor_focused():
		_embed.focus()
	_place_busy = false


func _on_slot_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if _use_embed and _embed and _embed.is_running():
			if _term_placed and _panel_slot_active():
				_apply_geom()
				_embed.focus()
			else:
				_ensure_placed(false, true)


func _input(event: InputEvent) -> void:
	if _use_embed:
		return
	if not visible or not is_visible_in_tree() or not _panel_slot_active():
		return
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	var k := event as InputEventKey
	if k.keycode != KEY_V and k.physical_keycode != KEY_V:
		return
	if not k.ctrl_pressed or not _session_alive():
		return
	var text := DisplayServer.clipboard_get()
	if text.is_empty():
		return
	_screen.stuff(_session_name(), text.replace("\n", "\r"))
	get_viewport().set_input_as_handled()


func _project_path() -> String:
	return LauncherScript.project_root()


func _session_name() -> String:
	return LauncherScript.screen_session_name(_project_path())


func _session_alive() -> bool:
	if _use_embed:
		return _embed != null and _embed.is_running() and _embed.has_child()
	return _screen != null and _screen.is_alive(_session_name())


func _on_start_session() -> void:
	if _session_alive() and not _bound_session_id.is_empty():
		_confirm_new_chat()
		return
	await _start_session_async(true, false)
	if _use_embed:
		if _panel_slot_active():
			await _ensure_placed(false, true)


func _confirm_new_chat() -> void:
	var dlg := ConfirmationDialog.new()
	dlg.title = "Cursor Agent"
	dlg.dialog_text = "结束当前会话并开启全新对话？"
	dlg.ok_button_text = "开启新对话"
	add_child(dlg)
	dlg.confirmed.connect(func() -> void:
		_start_session_async(false, true)
		dlg.queue_free()
	)
	dlg.canceled.connect(dlg.queue_free)
	dlg.close_requested.connect(dlg.queue_free)
	dlg.popup_centered()


func _start_session_async(resume: bool, force_new: bool) -> void:
	var project := _project_path()
	var resume_id := ""
	if not LauncherScript.agent_available():
		return
	if force_new or not resume:
		_store.invalidate(project)
		_bound_session_id = ""
		await _stop_session()
		_term_placed = false
		_first_remount_done = false
	else:
		resume_id = _store.find_last_session_id(project, _bound_session_id)

	var cmd: PackedStringArray = LauncherScript.build_command(project, resume_id)
	_session_started_at_ms = int(Time.get_unix_time_from_system() * 1000.0)

	var err: Error = OK
	if _use_embed:
		err = await _start_embed_session(cmd, project)
	else:
		err = _screen.start(_session_name(), project, cmd)
	if err != OK:
		return

	_bound_session_id = resume_id
	if not resume_id.is_empty():
		_store.record_active(project, resume_id)
	_schedule_adopt(force_new or resume_id.is_empty())
	if _use_embed:
		if _term_placed:
			_apply_geom()
			_embed.focus()
		elif _panel_slot_active():
			await _ensure_placed(false, true)
		else:
			_embed.hide()
	elif force_new or not resume:
		_on_open_terminal()


func _start_embed_session(cmd: PackedStringArray, project: String) -> Error:
	if _embed == null:
		return FAILED
	if not _embed.is_running():
		var e: Error = _embed.start_host()
		if e != OK:
			return e
	var att: Error = _embed.attach_to_godot()
	if att != OK:
		_embed.stop_host()
		return att
	return _embed.spawn(cmd, project)


func _stop_session() -> void:
	if _use_embed and _embed:
		_embed.stop_host()
		_last_geom = Rect2i()
		_term_placed = false
		await get_tree().create_timer(0.15).timeout
	elif _screen != null and _screen.is_alive(_session_name()):
		_screen.stop(_session_name())
		await get_tree().create_timer(0.25).timeout


func _schedule_adopt(require_fresh: bool) -> void:
	for delay_sec in [0.5, 1.5, 3.0, 6.0, 12.0]:
		var timer := get_tree().create_timer(delay_sec)
		timer.timeout.connect(func() -> void:
			var adopted: String = _store.adopt_discovered(
				_project_path(),
				_bound_session_id,
				_session_started_at_ms,
				require_fresh,
			)
			if not adopted.is_empty() and adopted != _bound_session_id:
				_bound_session_id = adopted
		)


func _on_inject_path() -> void:
	var notation := EditorCtxScript.collect_at_notation()
	_dbg("G-INJECT", "click", {"notation": notation, "alive": _session_alive()})
	if notation.is_empty():
		_dbg("G-INJECT", "empty-notation", {})
		return
	if not await _ensure_session():
		_dbg("G-INJECT", "session-fail", {})
		return
	var payload := "\n" + notation + "\n"
	if _use_embed:
		var err: Error = _embed.write(payload)
		# 注入后勿 focus 终端：会抢焦点导致第二次点按钮无效（4da6e60）
		_dbg("G-INJECT", "wrote", {"err": err, "n": payload.length(), "text": notation})
	else:
		_screen.stuff(_session_name(), payload)
		_dbg("G-INJECT", "screen-stuff", {"text": notation})


func _ensure_session() -> bool:
	if _session_alive():
		return true
	await _start_session_async(true, false)
	return _session_alive()


func _on_scroll_bottom() -> void:
	if _use_embed and _embed and _embed.is_running():
		_embed.scroll_bottom()


func _on_open_terminal() -> void:
	if _screen == null:
		return
	if not _session_alive():
		await _start_session_async(true, false)
	if not _session_alive():
		return
	_screen.open_system_terminal(_session_name())
