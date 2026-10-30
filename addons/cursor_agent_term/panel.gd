@tool
extends Control
## Dock 内槽位 + VTE 浮层：自动铺开、跟尺寸/页签/dock；工具栏仅会话相关。

const SessionStoreScript := preload("res://addons/cursor_agent_term/session_store.gd")
const LauncherScript := preload("res://addons/cursor_agent_term/launcher.gd")
const EditorCtxScript := preload("res://addons/cursor_agent_term/editor_ctx.gd")
const PlatScript := preload("res://addons/cursor_agent_term/plat.gd")
const GEOM_EPS_PX := 3

var _plat
var _store
var _screen
var _vte
var _use_vte: bool = false
var _status: Label
var _slot: ColorRect
var _bound_session_id: String = ""
var _session_started_at_ms: int = 0
var _auto_started: bool = false
var _last_geom: Rect2i = Rect2i()
## 已铺过浮层后，尺寸/dock 变化会自动跟
var _term_placed: bool = false
var _was_panel_active: bool = false
var _geom_sync_queued: bool = false
var _editor_ready_seen: bool = false
## 编辑器 Popup/对话框打开时隐藏浮层，避免挡住且看不见（全平台）
var _overlay_suppressed_by_popup: bool = false


func _ready() -> void:
	_plat = PlatScript.get_plat()
	_store = SessionStoreScript.new()
	# 内嵌 / 回退全部由 plat 工厂创建，panel 不写 OS 分支
	if _plat.embed_ok():
		_vte = _plat.new_embed()
		_use_vte = _vte != null
	_screen = _plat.new_fallback()
	_build_ui()
	set_process(true)
	set_process_input(true)
	visibility_changed.connect(_on_visibility_changed)
	# 面板自身尺寸变化（拆分条拖动 dock 大小）
	resized.connect(func() -> void: on_dock_geom_event("panel-resized"))
	item_rect_changed.connect(func() -> void: on_dock_geom_event("panel-rect"))
	_dbg("G-PANEL", "ready", {"os": _plat.os_id(), "vte": _use_vte})
	var ph: String = str(_plat.hint())
	if not _use_vte and not ph.is_empty():
		_set_status(ph)
	# 会话预热；真正铺终端等 on_editor_ready / 显隐事件


func _dbg(tag: String, msg: String, extra: Dictionary = {}) -> void:
	## 默认关闭；export GCAT_DEBUG=1 时写入系统临时目录
	if OS.get_environment("GCAT_DEBUG").strip_edges().is_empty():
		return
	var d := {"t": Time.get_time_string_from_system(), "tag": tag, "msg": msg}
	for k in extra:
		d[k] = extra[k]
	var path := OS.get_temp_dir().path_join(
		"gcat_macos_debug.log" if OS.get_name() == "macOS" else "gcat_vte_debug.log"
	)
	var f := FileAccess.open(path, FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	f.store_line(JSON.stringify(d))
	f.flush()


func _exit_tree() -> void:
	if _vte:
		_vte.stop_host()


func _build_ui() -> void:
	# 自身铺满 dock；工具栏贴底，上方高度全给终端槽位
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_theme_constant_override("separation", 2)
	add_child(root)

	# 状态只打日志，不占 UI 行
	_status = null

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
	if not _use_vte:
		_add_btn(bar, "打开终端", Callable(self, "_on_open_terminal"))


func _add_btn(parent: Node, text: String, cb: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.flat = false
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.custom_minimum_size = Vector2(0, 26)
	b.add_theme_constant_override("h_separation", 4)
	b.add_theme_font_size_override("font_size", 13)
	# 深色 dock 里默认按钮边容易糊掉，显式描边
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


func _focus_vte() -> void:
	if not _use_vte or _vte == null:
		return
	_vte.focus()


func _on_slot_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if _use_vte and _vte and _vte.is_running() and _term_placed:
			_focus_vte()
			_dbg("G-PANEL", "slot-click-focus")


func _input(event: InputEvent) -> void:
	## VTE 路径：Ctrl+V 只由 vte_host 在终端持焦时处理。
	## 这里若再全局拦截，会把脚本编辑器里的粘贴偷进终端。
	if _use_vte:
		return
	if not visible or not is_visible_in_tree():
		return
	if not _panel_slot_active():
		return
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	var k := event as InputEventKey
	if k.keycode != KEY_V and k.physical_keycode != KEY_V:
		return
	if not k.ctrl_pressed:
		return
	if not _session_alive():
		return
	# screen 回退：仅本页签激活时把剪贴板打进会话
	var text := DisplayServer.clipboard_get()
	if text.is_empty():
		return
	var e2: Error = _write_to_agent(text.replace("\n", "\r"))
	_dbg("G-PASTE", "screen-text", {"err": e2, "n": text.length()})
	if e2 == OK:
		get_viewport().set_input_as_handled()
		_set_status("已粘贴文本")


func _project_path() -> String:
	return LauncherScript.project_root()


func _session_name() -> String:
	return LauncherScript.screen_session_name(_project_path())


func _set_status(t: String) -> void:
	## 不再占行；需要时只写调试日志
	if t.is_empty():
		return
	_dbg("G-STATUS", t, {})


func _process(_delta: float) -> void:
	## 轮询内嵌宿主 TCP；并缓存脚本选区（点按钮失焦前）
	EditorCtxScript.refresh_cache()
	if _use_vte and _vte:
		_vte.poll_event()
		_update_popup_suppress()


func _update_popup_suppress() -> void:
	## 有可见临时 UI 时藏浮层；关掉后若本页签仍在再铺回
	if not _use_vte or _vte == null or not _vte.is_running():
		if _overlay_suppressed_by_popup:
			_overlay_suppressed_by_popup = false
		return
	var block := _editor_blocks_overlay()
	if block:
		if not _overlay_suppressed_by_popup:
			_overlay_suppressed_by_popup = true
			_dbg("G-POPUP", "suppress")
		# 弹层期间保持藏：macOS Floating NSPanel 会盖住主窗内嵌入弹层
		_vte.hide()
		return
	if not _overlay_suppressed_by_popup:
		return
	_overlay_suppressed_by_popup = false
	_dbg("G-POPUP", "restore")
	if _panel_slot_active() and _term_placed:
		_apply_placed_geom()


func _editor_tree_root() -> Node:
	var base: Control = EditorInterface.get_base_control()
	if base != null and base.get_tree() != null:
		return base.get_tree().root
	var tree := get_tree()
	return tree.root if tree != null else null


func _editor_blocks_overlay() -> bool:
	## 只认引擎临时 UI 原语（Popup / Dialog / exclusive / ColorPicker），
	## 用 find_children 全树检索。嵌入子窗勿碰 DisplayServer.window_*（macOS 会报错）。
	var root := _editor_tree_root()
	if root == null:
		return false
	var main_win: Window = get_window()
	# 1) 引擎弹层窗（取色器是 PopupPanel；右键是 PopupMenu；对话框是 AcceptDialog…）
	for cls_name in ["PopupPanel", "PopupMenu", "Popup", "AcceptDialog", "ConfirmationDialog", "FileDialog"]:
		for node in root.find_children("*", cls_name, true, false):
			if not (node is Window):
				continue
			var w := node as Window
			if w == main_win or not w.visible:
				continue
			if _is_tooltip_window(w):
				continue
			return true
	# 2) exclusive 子弹窗（勿对嵌入子窗调 DisplayServer.window_*：macOS 会报 !windows.has）
	for node in root.find_children("*", "Window", true, false):
		if not (node is Window):
			continue
		var w2 := node as Window
		if w2 == main_win or not w2.visible or _is_tooltip_window(w2):
			continue
		if w2.exclusive:
			return true
	# 3) 可见的 ColorPicker（懒创建，只有弹开才在树里可见）
	for node in root.find_children("*", "ColorPicker", true, false):
		if node is CanvasItem and (node as CanvasItem).is_visible_in_tree():
			return true
	return false

func _is_tooltip_window(w: Window) -> bool:
	var cls := w.get_class()
	return cls == "TooltipPanel" or cls.begins_with("Tooltip")


func _on_visibility_changed() -> void:
	_refresh_active_from_event("panel-vis")


func on_editor_ready() -> void:
	## 插件进入树 / 编辑器恢复 layout 后
	_dbg("G-EVT", "editor-ready", {"seen": _editor_ready_seen})
	_editor_ready_seen = true
	await _bootstrap_session_and_place()


func on_dock_geom_event(reason: String) -> void:
	## dock/面板/槽位 resized、挪槽位后的矩形变化
	_dbg("G-EVT", "geom", {"reason": reason})
	_schedule_geom_sync(reason)


func on_dock_layout_event(layout: int) -> void:
	## 竖/横/浮动布局切换（_update_layout）
	_dbg("G-EVT", "layout", {"layout": layout})
	_schedule_geom_sync("layout=%d" % layout)


func on_dock_closed() -> void:
	if _use_vte and _vte and _vte.is_running():
		_vte.hide()
	_was_panel_active = false
	_dbg("G-EVT", "dock-closed", {})


func on_dock_opened() -> void:
	_dbg("G-EVT", "dock-opened", {"placed": _term_placed})
	_refresh_active_from_event("dock-opened")
	_schedule_geom_sync("dock-opened")


func on_dock_visibility_ping() -> void:
	## 与 Inspector 等同槽切页签
	_refresh_active_from_event("dock-vis")


func _refresh_active_from_event(reason: String) -> void:
	if not _use_vte or _vte == null:
		return
	var active := _panel_slot_active()
	if active == _was_panel_active:
		if not active and _vte.is_running():
			_vte.hide()
		return
	_was_panel_active = active
	_dbg("G-TAB", "changed", {"active": active, "placed": _term_placed, "reason": reason})
	if not active:
		if _vte.is_running():
			_vte.hide()
		_set_status("已切到其它页签 · 终端已隐藏")
		return
	if _overlay_suppressed_by_popup or _editor_blocks_overlay():
		_overlay_suppressed_by_popup = true
		if _vte.is_running():
			_vte.hide()
		return
	if _term_placed and _vte.is_running():
		_apply_placed_geom()
		_set_status("已回到 Cursor Agent")
	elif _session_alive() or _use_vte:
		_ensure_placed(false)
	else:
		_set_status("开启会话后会自动铺终端")


func _schedule_geom_sync(reason: String) -> void:
	## 合并同一帧内多次 resized
	if _geom_sync_queued:
		return
	_geom_sync_queued = true
	call_deferred("_run_geom_sync", reason)


func _run_geom_sync(reason: String) -> void:
	_geom_sync_queued = false
	await get_tree().process_frame
	if not _use_vte or _vte == null:
		return
	_refresh_active_from_event("geom-" + reason)
	if not _panel_slot_active():
		return
	if _term_placed and _vte.is_running() and _vte.is_attached():
		_sync_geom_if_changed(reason)
	elif _session_alive() or (_vte.is_running() and _editor_ready_seen):
		await _ensure_placed(false)


func _sync_geom_if_changed(reason: String) -> void:
	## 必须与 _apply_placed_geom 同路径（macOS rel / 其它 abs）。
	## 旧逻辑 sync 时 set_geom 绝对坐标，HiDPI 下会漂到槽位左边。
	if _overlay_suppressed_by_popup or _editor_blocks_overlay():
		_overlay_suppressed_by_popup = true
		if _vte != null and _vte.is_running():
			_vte.hide()
		return
	if not _term_placed or _vte == null or not _vte.is_running() or not _vte.is_attached():
		return
	var r := _slot_screen_rect()
	if r.size.x < 8 or r.size.y < 8:
		return
	if _geom_near(_last_geom, r):
		return
	if _apply_placed_geom():
		_dbg("G-GEOM", "sync", {"reason": reason, "x": _last_geom.position.x, "y": _last_geom.position.y, "w": _last_geom.size.x, "h": _last_geom.size.y})


func _geom_near(a: Rect2i, b: Rect2i) -> bool:
	return (
		absi(a.position.x - b.position.x) <= GEOM_EPS_PX
		and absi(a.position.y - b.position.y) <= GEOM_EPS_PX
		and absi(a.size.x - b.size.x) <= GEOM_EPS_PX
		and absi(a.size.y - b.size.y) <= GEOM_EPS_PX
	)


func _bootstrap_session_and_place() -> void:
	if DisplayServer.get_name() == "headless":
		return
	if not _auto_started:
		_auto_started = true
		await _start_session_async(true, false)
	# 等 dock 几何落地
	for _i in range(6):
		await get_tree().process_frame
		if _panel_slot_active():
			await _ensure_placed(false)
			if _term_placed:
				_set_status("终端已自动铺满")
				return
		await get_tree().create_timer(0.08).timeout
	if _use_vte and _vte and _vte.is_running() and not _term_placed:
		_vte.hide()
	_set_status("打开 Cursor Agent 页签后自动铺终端")


func _panel_slot_active() -> bool:
	## 底栏 / 左侧 / 右侧（Inspector 同槽）只要当前不是本页签就不算 active。
	if not visible or not is_visible_in_tree():
		return false
	if not _is_current_tab_page():
		return false
	if _slot == null:
		return false
	var gr := _slot.get_global_rect()
	return gr.size.x >= 32.0 and gr.size.y >= 32.0


func _is_current_tab_page() -> bool:
	## 沿父链找 TabContainer：当前 tab 必须是本面板所在页（Inspector 切走 → false）。
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
	## 槽位屏幕矩形：交由 plat（Linux 原公式；macOS 用 screen_transform 防 HiDPI 算飞）
	if _plat != null and _plat.has_method("slot_screen_rect"):
		var r: Rect2i = _plat.slot_screen_rect(_slot)
		_dbg("G-GEOM", "slot", {"x": r.position.x, "y": r.position.y, "w": r.size.x, "h": r.size.y, "os": _plat.os_id()})
		return r
	return Rect2i()


func _apply_placed_geom() -> bool:
	# 现场再判一次：避免几何同步抢在 suppress 标志之前把叠窗又 show 出来
	if _overlay_suppressed_by_popup or _editor_blocks_overlay():
		_overlay_suppressed_by_popup = true
		if _vte != null and _vte.is_running():
			_vte.hide()
		return false
	if _vte == null or not _vte.is_running() or not _vte.is_attached():
		return false
	# macOS：相对槽位（宿主用 CGWindow 对齐）；其它平台：绝对屏幕矩形
	if _vte.has_method("set_slot_geom") and _plat != null and _plat.has_method("slot_geom_dict"):
		var d: Dictionary = _plat.slot_geom_dict(_slot)
		if d.is_empty() or float(d.get("fw", 0)) <= 0.0 or float(d.get("fh", 0)) <= 0.0:
			_dbg("G-GEOM", "slot-too-small", {})
			return false
		_last_geom = Rect2i(int(d.get("x", 0)), int(d.get("y", 0)), int(d.get("w", 0)), int(d.get("h", 0)))
		_vte.set_slot_geom(d)
		_dbg("G-GEOM", "place-rel", d)
		return true
	var r := _slot_screen_rect()
	if r.size.x < 8 or r.size.y < 8:
		_dbg("G-GEOM", "slot-too-small", {})
		return false
	_last_geom = r
	_vte.set_geom(r.position.x, r.position.y, r.size.x, r.size.y)
	_dbg("G-GEOM", "place", {"x": r.position.x, "y": r.position.y, "w": r.size.x, "h": r.size.y})
	return true


func _ensure_placed(force_restart_host: bool, grab_focus: bool = false) -> void:
	## 铺 VTE 到当前槽位；默认不抢键盘（Alt+Tab / 几何同步只铺窗）。
	## grab_focus：开启会话等主动操作才为 true。
	if not _use_vte or _vte == null:
		_set_status("无 VTE")
		return
	if _overlay_suppressed_by_popup or _editor_blocks_overlay():
		_overlay_suppressed_by_popup = true
		if _vte.is_running():
			_vte.hide()
		return
	if not _panel_slot_active():
		_set_status("请先打开 Cursor Agent 页签/dock")
		return
	await get_tree().process_frame
	await get_tree().process_frame

	var had_child: bool = _vte.has_child()
	if force_restart_host or not _vte.is_running():
		if _vte.is_running():
			_vte.stop_host()
			await get_tree().create_timer(0.05).timeout
		var e: Error = _vte.start_host()
		if e != OK:
			_set_status("VTE 宿主启动失败")
			return
		had_child = false
	var att: Error = _vte.attach_to_godot()
	if att != OK:
		_set_status("VTE 附着失败")
		return

	if not _apply_placed_geom():
		_set_status("槽位尺寸无效，请先拉大 dock 再试")
		return

	_term_placed = true
	if not had_child or not _session_alive():
		await _start_session_async(true, false)
	await get_tree().process_frame
	_apply_placed_geom()
	await get_tree().create_timer(0.1).timeout
	_apply_placed_geom()
	if grab_focus:
		_focus_vte()
	_dbg("G-PLACE", "ok", {"restart": force_restart_host, "grab": grab_focus, "w": _last_geom.size.x, "h": _last_geom.size.y})


func _on_start_session() -> void:
	if _session_alive() and not _bound_session_id.is_empty():
		_confirm_new_chat()
		return
	await _start_session_async(true, false)
	if _use_vte:
		if _panel_slot_active():
			await _ensure_placed(false, true)
		else:
			if _vte and _vte.is_running():
				_vte.hide()
			_set_status("会话已开 · 回到本页签即自动铺终端")


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


func _session_alive() -> bool:
	if _use_vte:
		return _vte != null and _vte.is_running() and _vte.has_child()
	return _screen.is_alive(_session_name())


func _start_session_async(resume: bool, force_new: bool) -> void:
	var project := _project_path()
	var resume_id := ""
	if not LauncherScript.agent_available():
		_set_status("未找到 cursor-agent：请安装 CLI，或设 CURSOR_AGENT_PATH")
		return

	if force_new or not resume:
		_store.invalidate(project)
		_bound_session_id = ""
		await _stop_session()
		_term_placed = false
	else:
		resume_id = _store.find_last_session_id(project, _bound_session_id)

	var cmd: PackedStringArray = LauncherScript.build_command(project, resume_id)
	_session_started_at_ms = int(Time.get_unix_time_from_system() * 1000.0)

	var err: Error = OK
	if _use_vte:
		err = await _start_vte_session(cmd, project)
	else:
		err = _screen.start(_session_name(), project, cmd)

	if err != OK:
		_set_status("启动失败（检查 cursor-agent / VTE）")
		return

	_bound_session_id = resume_id
	if not resume_id.is_empty():
		_store.record_active(project, resume_id)
	_schedule_adopt(force_new or resume_id.is_empty())
	if _use_vte:
		if _term_placed:
			_apply_placed_geom()
			_focus_vte()
			_set_status("resume=%s" % (resume_id if not resume_id.is_empty() else "新会话"))
		elif _panel_slot_active():
			await _ensure_placed(false, true)
		else:
			_vte.hide()
			_set_status("会话已开 · 回到本页签即铺终端")
	elif force_new or not resume:
		_on_open_terminal()


func _start_vte_session(cmd: PackedStringArray, project: String) -> Error:
	if _vte == null:
		return FAILED
	if not _vte.is_running():
		var e: Error = _vte.start_host()
		if e != OK:
			return e
	var att: Error = _vte.attach_to_godot()
	if att != OK:
		_vte.stop_host()
		return att
	# geom 由 _ensure_placed / 自动同步负责
	return _vte.spawn(cmd, project)


func _stop_session() -> void:
	if _use_vte and _vte:
		_vte.stop_host()
		_last_geom = Rect2i()
		_term_placed = false
		await get_tree().create_timer(0.15).timeout
	elif _screen.is_alive(_session_name()):
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
				_set_status("chatId=%s" % adopted)
		)


func _ensure_session() -> bool:
	if _session_alive():
		return true
	await _start_session_async(true, false)
	return _session_alive()


func _write_to_agent(text: String) -> Error:
	if _use_vte:
		if not _vte or not _vte.is_running():
			return ERR_DOES_NOT_EXIST
		return _vte.write(text)
	return _screen.stuff(_session_name(), text)


func _on_inject_path() -> void:
	# 先采路径/选区（点按钮易失焦丢选区；缓存见 editor_ctx），再确保会话
	var notation: String = EditorCtxScript.collect_at_notation()
	if notation.is_empty():
		_set_status("请先打开脚本")
		return
	if not await _ensure_session():
		_set_status("会话未启动")
		return
	var err: Error = _write_to_agent("\n" + notation + "\n")
	if err == OK and _use_vte and _vte:
		_focus_vte()
	_set_status("已注入 %s" % notation if err == OK else "注入失败")


func _on_scroll_bottom() -> void:
	if _use_vte:
		if not _vte or not _vte.is_running():
			_set_status("会话未启动")
			return
		_vte.scroll_bottom()
		_focus_vte()
		return
	_on_open_terminal()


func _on_open_terminal() -> void:
	if not _screen.is_alive(_session_name()):
		_set_status("无会话，请先开启")
		return
	var err: Error = _screen.open_system_terminal(_session_name())
	_set_status("已打开系统终端" if err == OK else "打开终端失败")
