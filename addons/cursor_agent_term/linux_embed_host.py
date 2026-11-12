#!/usr/bin/env python3
"""Linux 内嵌终端：GTK 叠窗 + WebKitGTK + xterm_web/linux.html + 真 PTY。
协议与 macOS 宿主对齐（TCP NDJSON）。仅 plat_linux / embed_bridge 使用。
页面与 macOS 隔离：只用 linux.html，不含 macOS IME 补交。
"""
from __future__ import annotations

import base64
import fcntl
import json
import os
import pty
import select
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
import warnings
from pathlib import Path
from shutil import which

os.environ.setdefault("GDK_BACKEND", "x11")
lang = (os.environ.get("LANG") or "").strip()
if not lang.upper().endswith("UTF-8"):
	os.environ["LANG"] = "C.UTF-8"
os.environ.setdefault("LC_CTYPE", os.environ.get("LANG", "C.UTF-8"))

import gi

warnings.filterwarnings("ignore", category=DeprecationWarning)
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("WebKit2", "4.1")
from gi.repository import Gdk, GLib, Gtk, WebKit2  # noqa: E402

try:
	gi.require_version("GdkX11", "3.0")
	from gi.repository import GdkX11
except Exception:  # noqa: BLE001
	GdkX11 = None

SHIFT_ENTER = "\x1b[13;2u"
IMAGE_PASTE = "\x16"

try:
	_FONT_PT = max(7, min(18, int((os.environ.get("GCAT_TERM_FONT_SIZE") or "10").strip())))
except ValueError:
	_FONT_PT = 10

# 黑窗排查期默认落盘；GCAT_DEBUG=0 可关。正式收敛后再改回仅环境变量开启。
_raw_dbg = (os.environ.get("GCAT_VTE_DEBUG") or os.environ.get("GCAT_DEBUG") or "1").strip()
_DEFAULT_DBG = os.path.join(tempfile.gettempdir(), "gcat_linux_debug.log")
_DEBUG_PATH = ""
if _raw_dbg in ("0", "false", "no", "off"):
	_DEBUG_PATH = ""
elif _raw_dbg in ("1", "true", "yes", "on"):
	_DEBUG_PATH = _DEFAULT_DBG
elif _raw_dbg:
	_DEBUG_PATH = _raw_dbg


def _dbg(tag: str, msg: str, **extra) -> None:
	if not _DEBUG_PATH:
		return
	try:
		with open(_DEBUG_PATH, "a", encoding="utf-8") as f:
			f.write(
				json.dumps({"t": time.strftime("%H:%M:%S"), "tag": tag, "msg": msg, **extra}, ensure_ascii=False)
				+ "\n"
			)
	except OSError:
		pass


def _assets_dir() -> Path:
	return Path(__file__).resolve().parent / "xterm_web"


class Host:
	def __init__(self) -> None:
		self.win = Gtk.Window(type=Gtk.WindowType.TOPLEVEL)
		self.win.set_decorated(False)
		self.win.set_skip_taskbar_hint(True)
		self.win.set_skip_pager_hint(True)
		self.win.set_accept_focus(False)
		self.win.set_can_focus(True)
		self.win.set_keep_above(False)
		self.win.set_focus_on_map(False)
		self.win.set_type_hint(Gdk.WindowTypeHint.UTILITY)
		self.win.set_resizable(False)
		self.win.set_gravity(Gdk.Gravity.NORTH_WEST)
		try:
			self.win.set_role("godot-cursor-agent-term-dock")
		except Exception:
			pass
		self.win.connect("destroy", Gtk.main_quit)
		self.win.connect("button-press-event", self._on_win_button)
		self.win.connect("configure-event", self._on_configure)
		self.win.connect("focus-out-event", self._on_focus_out)
		self.win.connect("map-event", self._on_map)
		self.win.connect("key-press-event", self._on_key_press)
		self.win.add_events(Gdk.EventMask.KEY_PRESS_MASK | Gdk.EventMask.BUTTON_PRESS_MASK)

		self._ucm = WebKit2.UserContentManager()
		self._ucm.register_script_message_handler("gcat")
		self._ucm.connect("script-message-received::gcat", self._on_script_message)
		inject = f"window.GCAT_FONT_SIZE={_FONT_PT};"
		self._ucm.add_script(
			WebKit2.UserScript.new(
				inject,
				WebKit2.UserContentInjectedFrames.TOP_FRAME,
				WebKit2.UserScriptInjectionTime.START,
				None,
				None,
			)
		)
		self.web = WebKit2.WebView.new_with_user_content_manager(self._ucm)
		self.web.set_can_focus(True)
		settings = self.web.get_settings()
		try:
			settings.set_enable_developer_extras(False)
			settings.set_enable_write_console_messages_to_stdout(bool(_DEBUG_PATH))
			if hasattr(settings, "set_allow_file_access_from_file_urls"):
				settings.set_allow_file_access_from_file_urls(True)
			if hasattr(settings, "set_allow_universal_access_from_file_urls"):
				settings.set_allow_universal_access_from_file_urls(True)
		except Exception:
			pass
		self.web.connect("load-changed", self._on_load_changed)
		self.web.connect("load-failed", self._on_load_failed)
		self.win.add(self.web)

		self._conn: socket.socket | None = None
		self._buf = b""
		self._attached = False
		self._parent_xid = 0
		self._visible = False
		self._want_visible = False  # 对齐 macOS：dock 要显示；真正 map 还看前台是否 Godot/本窗
		self._remounting = False
		self._last_geom: tuple = (None, None, None, None)
		self._clamp_armed = False
		self._web_ready = False
		self._pending_out = bytearray()
		self._pending_lock = threading.Lock()
		self._child_pid = -1
		self._master_fd = -1
		self._pty_stop = threading.Event()
		self._pty_thread: threading.Thread | None = None
		self._cols = 80
		self._rows = 24
		self._xdisp = None
		self._xclip_proc: subprocess.Popen | None = None
		self._paste_gen = 0
		self._front_parked = False
		self._load_xterm()
		GLib.timeout_add(200, self._poll_front)

	def _load_xterm(self) -> None:
		assets = _assets_dir()
		html = assets / "linux.html"
		if not html.is_file():
			_dbg("H-WEB", "missing-index", path=str(html))
			return
		uri = html.resolve().as_uri()
		_dbg("H-WEB", "load-uri", uri=uri, page="linux")
		self.web.load_uri(uri)

	def _on_load_changed(self, _web, event) -> None:
		_dbg("H-WEB", "load-changed", event=int(event), web_ready=self._web_ready)

	def _on_load_failed(self, _web, _event, uri, err) -> bool:
		_dbg("H-WEB", "load-failed", uri=str(uri), err=str(err))
		return False

	def _toplevel_xid(self, xid: int) -> int:
		d = self._xdisplay()
		if d is None or xid <= 0:
			return 0
		try:
			from Xlib import X

			w = d.create_resource_object("window", xid)
			root = d.screen().root
			while True:
				tree = w.query_tree()
				if tree.parent is None or tree.parent.id == root.id:
					return int(w.id)
				w = tree.parent
		except Exception:
			return int(xid)

	def _active_toplevel_xid(self) -> int:
		d = self._xdisplay()
		if d is None:
			return 0
		try:
			from Xlib import X

			root = d.screen().root
			atom = d.get_atom("_NET_ACTIVE_WINDOW")
			r = root.get_full_property(atom, X.AnyPropertyType)
			if not r or not r.value:
				return 0
			return self._toplevel_xid(int(r.value[0]))
		except Exception:
			return 0

	def _front_is_godot_or_self(self) -> bool:
		"""对齐 macOS _godot_is_front：前台是编辑器或本叠窗则保持显示。"""
		active = self._active_toplevel_xid()
		if active <= 0:
			return True
		gdk_win = self.win.get_window()
		self_xid = 0
		if gdk_win is not None and GdkX11 is not None:
			try:
				self_xid = int(GdkX11.X11Window.get_xid(gdk_win))
			except Exception:
				self_xid = 0
		if self_xid and active == self._toplevel_xid(self_xid):
			return True
		if self._parent_xid > 0 and active == self._toplevel_xid(self._parent_xid):
			return True
		return False

	def _poll_front(self) -> bool:
		## 切到钉钉/浏览器时 park；点终端/Godot 时抬回。禁止靠 Godot FOCUS_OUT hide（会黑槽）。
		if not self._want_visible or not self._attached or self._last_geom[0] is None:
			return True
		ok = self._front_is_godot_or_self()
		if ok:
			if self._front_parked or not self._visible:
				self._front_parked = False
				_dbg("H-APP", "unpark", active=self._active_toplevel_xid())
				self._visible = False
				g = self._last_geom
				self.show_at(int(g[0]), int(g[1]), int(g[2]), int(g[3]))
		else:
			if self._visible and not self._front_parked:
				_dbg("H-APP", "park", active=self._active_toplevel_xid(), **self._win_map_state())
				try:
					self.win.hide()
				except Exception:
					pass
				self._visible = False
				self._front_parked = True
		return True

	def _win_map_state(self) -> dict:
		info = {
			"flag_visible": self._visible,
			"want": self._want_visible,
			"parked": self._front_parked,
			"gtk_visible": bool(self.win.get_visible()),
			"web_ready": self._web_ready,
			"attached": self._attached,
			"geom": list(self._last_geom) if self._last_geom[0] is not None else None,
		}
		gdk_win = self.win.get_window()
		if gdk_win is None:
			info["gdk"] = None
			return info
		try:
			geo = gdk_win.get_geometry()
			info["gdk"] = {
				"xid": int(GdkX11.X11Window.get_xid(gdk_win)) if GdkX11 else None,
				"x": int(geo.x),
				"y": int(geo.y),
				"w": int(geo.width),
				"h": int(geo.height),
				"is_visible": bool(gdk_win.is_visible()),
			}
		except Exception as e:  # noqa: BLE001
			info["gdk_err"] = str(e)
		return info

	def set_conn(self, conn: socket.socket) -> None:
		self._conn = conn
		self._conn.setblocking(False)

	def _emit(self, obj: dict) -> None:
		if self._conn is None:
			return
		try:
			self._conn.sendall((json.dumps(obj, ensure_ascii=False) + "\n").encode("utf-8"))
		except OSError:
			pass

	def _js(self, script: str) -> None:
		try:
			self.web.run_javascript(script, None, None, None)
		except Exception as e:  # noqa: BLE001
			_dbg("H-JS", "fail", err=str(e))

	def _js_val_to_obj(self, message) -> dict | None:
		try:
			# WebKitGTK 2.40+: JavascriptResult / JSCValue
			if hasattr(message, "get_js_value"):
				val = message.get_js_value()
				if val is None:
					return None
				if hasattr(val, "to_json"):
					return json.loads(val.to_json(0))
				if hasattr(val, "to_string"):
					return json.loads(str(val.to_string()))
			if hasattr(message, "get_global_context"):
				# older path
				from gi.repository import JavaScriptCore as JSC  # type: ignore

				ctx = message.get_global_context()
				val = message.get_value()
				s = JSC.value_to_string(ctx, val) if ctx and val else str(val)
				return json.loads(s)
		except Exception as e:  # noqa: BLE001
			_dbg("H-JS", "parse-fail", err=str(e))
		return None

	def _on_script_message(self, _manager, message) -> None:
		msg = self._js_val_to_obj(message)
		if not isinstance(msg, dict):
			return
		self.on_js_message(msg)

	def on_js_message(self, msg: dict) -> None:
		typ = str(msg.get("type") or "")
		if typ == "ready":
			self._web_ready = True
			_dbg("H-WEB", "js-ready", **self._win_map_state())
			self._js("window.gcatFit && window.gcatFit()")
			self._flush_pending()
		elif typ == "error":
			_dbg("H-WEB", "js-error", message=str(msg.get("message") or ""))
		elif typ == "focus-req":
			self._focus_term()
		elif typ == "data":
			self.write(str(msg.get("data") or ""))
		elif typ == "shift-enter":
			self.write(SHIFT_ENTER)
		elif typ == "paste":
			self._handle_paste(shift=bool(msg.get("shift")))
		elif typ == "copy":
			text = str(msg.get("text") or "")
			if text:
				Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD).set_text(text, -1)
		elif typ == "size":
			self._pty_resize(int(msg.get("cols") or self._cols), int(msg.get("rows") or self._rows))

	def _flush_pending(self) -> None:
		with self._pending_lock:
			data = bytes(self._pending_out)
			self._pending_out.clear()
		if data:
			self._write_term_bytes_now(data)

	def _write_term_bytes_now(self, data: bytes) -> None:
		if not data:
			return
		b64 = base64.b64encode(data).decode("ascii")
		for i in range(0, len(b64), 24000):
			chunk = b64[i : i + 24000]
			self._js(f"window.gcatWriteB64 && window.gcatWriteB64('{chunk}')")

	def _write_term_bytes(self, data: bytes) -> None:
		if not data:
			return
		if not self._web_ready:
			with self._pending_lock:
				self._pending_out.extend(data)
				if len(self._pending_out) > 512_000:
					del self._pending_out[:-256_000]
			return
		self._write_term_bytes_now(data)

	def _xdisplay(self):
		if self._xdisp is not None:
			return self._xdisp if self._xdisp is not False else None
		try:
			from Xlib import display as xdisplay

			self._xdisp = xdisplay.Display()
		except Exception:
			self._xdisp = False
		return self._xdisp if self._xdisp is not False else None

	def _apply_skip_hints(self) -> None:
		try:
			self.win.set_skip_taskbar_hint(True)
			self.win.set_skip_pager_hint(True)
			self.win.set_focus_on_map(False)
		except Exception:
			pass
		d = self._xdisplay()
		gdk_win = self.win.get_window()
		if d is None or gdk_win is None or GdkX11 is None:
			return
		try:
			from Xlib import X
			from Xlib.protocol import event as xevent

			xid = int(GdkX11.X11Window.get_xid(gdk_win))
			root = d.screen().root
			nw = d.get_atom("_NET_WM_STATE")
			skip_tb = d.get_atom("_NET_WM_STATE_SKIP_TASKBAR")
			skip_pg = d.get_atom("_NET_WM_STATE_SKIP_PAGER")
			ev = xevent.ClientMessage(
				window=xid,
				client_type=nw,
				data=(32, [1, skip_tb, skip_pg, 0, 0]),
			)
			mask = X.SubstructureRedirectMask | X.SubstructureNotifyMask
			root.send_event(ev, event_mask=mask)
			d.flush()
		except Exception as e:  # noqa: BLE001
			_dbg("H-WM", "skip-hints-fail", err=str(e))

	def _release_wm_focus(self) -> None:
		try:
			self.win.set_accept_focus(False)
		except Exception:
			pass
		d = self._xdisplay()
		if d is None:
			return
		try:
			from Xlib import X

			d.set_input_focus(X.PointerRoot, X.RevertToPointerRoot, X.CurrentTime)
			d.flush()
		except Exception as e:  # noqa: BLE001
			_dbg("H-FOCUS", "release-fail", err=str(e))

	def _event_time(self) -> int:
		try:
			return int(Gtk.get_current_event_time() or 0)
		except Exception:
			return 0

	def _focus_term(self) -> None:
		try:
			self._apply_skip_hints()
			self.win.set_accept_focus(True)
			gdk_win = self.win.get_window()
			if gdk_win is not None:
				gdk_win.focus(self._event_time())
			self.web.grab_focus()
			self._js("window.gcatFocus && window.gcatFocus()")
		except Exception as e:  # noqa: BLE001
			_dbg("H-FOCUS", "fail", err=str(e))

	def _on_focus_out(self, _w, _e) -> bool:
		try:
			self.win.set_accept_focus(False)
		except Exception:
			pass
		return False

	def _on_win_button(self, _w, _e) -> bool:
		self._focus_term()
		return False

	def _on_key_press(self, _widget, event) -> bool:
		if event.keyval in (
			Gdk.KEY_Alt_L,
			Gdk.KEY_Alt_R,
			Gdk.KEY_Meta_L,
			Gdk.KEY_Meta_R,
			Gdk.KEY_Super_L,
			Gdk.KEY_Super_R,
		):
			self._release_wm_focus()
		return False

	def attach(self, parent_xid: int) -> None:
		self._parent_xid = int(parent_xid or 0)
		self._attached = True
		self._emit({"event": "attached", "xid": self._parent_xid})
		GLib.idle_add(self._apply_transient)

	def _apply_transient(self) -> bool:
		try:
			if not self.win.get_realized():
				self.win.realize()
			gdk_win = self.win.get_window()
			if gdk_win is None:
				return False
			gdk_win.set_keep_above(False)
			if self._parent_xid > 0 and GdkX11 is not None:
				display = self.win.get_display()
				if isinstance(display, GdkX11.X11Display):
					parent = GdkX11.X11Window.foreign_new_for_display(display, self._parent_xid)
					if parent is not None:
						gdk_win.set_transient_for(parent)
		except Exception as e:  # noqa: BLE001
			self._emit({"event": "warn", "message": f"transient: {e}"})
		return False

	def _lock_size_hints(self, w: int, h: int) -> None:
		try:
			g = Gdk.Geometry()
			g.min_width = w
			g.max_width = w
			g.min_height = h
			g.max_height = h
			g.base_width = w
			g.base_height = h
			hints = Gdk.WindowHints.MIN_SIZE | Gdk.WindowHints.MAX_SIZE | Gdk.WindowHints.BASE_SIZE
			self.win.set_geometry_hints(self.win, g, hints)
		except Exception:
			pass

	def _apply_geom_only(self, x: int, y: int, w: int, h: int) -> bool:
		try:
			self._lock_size_hints(w, h)
			self.win.set_size_request(w, h)
			self.win.set_default_size(w, h)
			self.web.set_size_request(w, h)
			self.win.resize(w, h)
			self.win.move(x, y)
			gdk_win = self.win.get_window()
			if gdk_win is not None:
				gdk_win.set_keep_above(False)
				gdk_win.move_resize(x, y, w, h)
			self._js("window.gcatFit && window.gcatFit()")
			if gdk_win is not None:
				geo = gdk_win.get_geometry()
				gw, gh = int(geo.width), int(geo.height)
				if gw and gh and (abs(gw - w) > 4 or abs(gh - h) > 4) and not self._clamp_armed:
					self._clamp_armed = True
					GLib.timeout_add(30, self._reclamp_last)
		except Exception as e:  # noqa: BLE001
			_dbg("H-GEOM", "apply-fail", err=str(e))
		return False

	def _reclamp_last(self) -> bool:
		self._clamp_armed = False
		g = self._last_geom
		if g[0] is None:
			return False
		self._apply_geom_only(g[0], g[1], g[2], g[3])
		return False

	def _on_configure(self, _widget, event) -> bool:
		g = self._last_geom
		if g[0] is None or not self._visible:
			return False
		try:
			if (
				abs(int(event.width) - g[2]) > 2
				or abs(int(event.height) - g[3]) > 2
				or abs(int(event.x) - g[0]) > 2
				or abs(int(event.y) - g[1]) > 2
			) and not self._clamp_armed:
				self._clamp_armed = True
				GLib.idle_add(self._reclamp_last)
		except Exception:
			pass
		return False

	def show_at(self, x: int, y: int, w: int, h: int) -> None:
		if not self._attached:
			_dbg("H-GEOM", "skip-not-attached", x=x, y=y, w=w, h=h)
			return
		w, h, x, y = max(1, int(w)), max(1, int(h)), int(x), int(y)
		geom = (x, y, w, h)
		self._want_visible = True
		self._front_parked = False
		if not self.win.get_realized():
			self.win.realize()
			GLib.idle_add(self._apply_transient)
		# 其它 App 前台：只记几何，等 _poll_front unpark（对齐 macOS _sync_front_app）
		if not self._front_is_godot_or_self():
			self._last_geom = geom
			self._front_parked = True
			_dbg("H-GEOM", "show-deferred-foreign", x=x, y=y, w=w, h=h, active=self._active_toplevel_xid())
			return
		gdk_win = self.win.get_window()
		mapped = bool(gdk_win is not None and gdk_win.is_visible())
		need_show = (not self._visible) or (not mapped)
		self._last_geom = geom
		self._apply_geom_only(x, y, w, h)
		if need_show:
			self.win.show_all()
			self._visible = True
			self._apply_skip_hints()
			GLib.idle_add(self._apply_geom_only, x, y, w, h)
			GLib.idle_add(self._log_map, "show")
			_dbg("H-GEOM", "show", x=x, y=y, w=w, h=h, was_mapped=mapped)
		else:
			self._js("window.gcatFit && window.gcatFit()")
			_dbg("H-GEOM", "move", x=x, y=y, w=w, h=h, **self._win_map_state())

	def _log_map(self, reason: str) -> bool:
		_dbg("H-GEOM", "map-state", reason=reason, **self._win_map_state())
		return False

	def remount(self) -> None:
		## 对齐 macOS：禁止 hide/show。WebKit orderOut 再 show 会打成透明黑槽。
		g = self._last_geom
		if not self._attached or g[0] is None:
			_dbg("H-GEOM", "remount-skip", attached=self._attached, geom=list(g))
			return
		st = self._win_map_state()
		mapped = bool(st.get("gdk") and st["gdk"].get("is_visible"))
		if not mapped:
			# 真被 hide 过：只补 show，不先 orderOut
			_dbg("H-GEOM", "remount-remap", **st)
			self._visible = False
			self.show_at(int(g[0]), int(g[1]), int(g[2]), int(g[3]))
		else:
			self.refresh_paint()
			_dbg("H-GEOM", "remount-paint", **self._win_map_state())

	def _on_map(self, _w, _e) -> bool:
		self._apply_skip_hints()
		self._js("window.gcatFit && window.gcatFit()")
		_dbg("H-GEOM", "map-event", **self._win_map_state())
		self._emit({"event": "mapped"})
		return False

	def hide(self) -> None:
		## 面板主动藏（弹层/切页签）：清 want，区别于前台 park
		self._want_visible = False
		self._front_parked = False
		if self._visible or bool(self.win.get_visible()):
			_dbg("H-GEOM", "hide", **self._win_map_state())
			try:
				self.win.hide()
			except Exception:
				pass
			self._visible = False
			self._clamp_armed = False
			try:
				self.win.set_accept_focus(False)
			except Exception:
				pass

	def refresh_paint(self) -> None:
		## 对齐 macOS refresh_paint：fit + 重绘；若未 map 则补 show
		g = self._last_geom
		gdk_win = self.win.get_window()
		mapped = bool(gdk_win is not None and gdk_win.is_visible())
		if (not mapped) and g[0] is not None and self._attached:
			_dbg("H-PAINT", "remap", **self._win_map_state())
			self._visible = False
			self.show_at(int(g[0]), int(g[1]), int(g[2]), int(g[3]))
			return
		self._js("window.gcatFit && window.gcatFit()")
		try:
			self.web.queue_draw()
			self.win.queue_draw()
		except Exception as e:  # noqa: BLE001
			_dbg("H-PAINT", "fail", err=str(e))
		_dbg("H-PAINT", "ok", **self._win_map_state())

	def scroll_bottom(self) -> None:
		self._js("window.gcatScrollBottom && window.gcatScrollBottom()")

	def _pty_resize(self, cols: int, rows: int) -> None:
		self._cols = max(1, int(cols))
		self._rows = max(1, int(rows))
		if self._master_fd < 0:
			return
		try:
			fcntl.ioctl(
				self._master_fd,
				termios.TIOCSWINSZ,
				struct.pack("HHHH", self._rows, self._cols, 0, 0),
			)
		except Exception as e:  # noqa: BLE001
			_dbg("H-PTY", "resize-fail", err=str(e))

	def _pty_reader(self) -> None:
		fd = self._master_fd
		while not self._pty_stop.is_set() and fd >= 0:
			try:
				r, _, _ = select.select([fd], [], [], 0.2)
			except (OSError, ValueError):
				break
			if not r:
				continue
			try:
				data = os.read(fd, 8192)
			except OSError:
				break
			if not data:
				break
			GLib.idle_add(self._write_term_bytes, data)
		if self._child_pid > 0:
			pid = self._child_pid
			self._child_pid = -1
			GLib.idle_add(self._emit, {"event": "child_exited", "pid": pid})

	def spawn(self, argv: list[str], cwd: str) -> None:
		if not argv:
			self._emit({"event": "error", "message": "empty argv"})
			return
		self._stop_pty()
		cwd = cwd or os.path.expanduser("~")
		env = os.environ.copy()
		env["TERM"] = "xterm-256color"
		env["COLORTERM"] = "truecolor"
		env.setdefault("LANG", "en_US.UTF-8")
		env.setdefault("LC_CTYPE", env["LANG"])
		for k in ("GTK_IM_MODULE", "QT_IM_MODULE", "XMODIFIERS", "IBUS_ADDRESS"):
			if k in os.environ:
				env[k] = os.environ[k]
		try:
			pid, master = pty.fork()
		except OSError as e:
			self._emit({"event": "error", "message": f"pty.fork: {e}"})
			return
		if pid == 0:
			try:
				os.chdir(cwd)
			except OSError:
				pass
			os.environ.clear()
			os.environ.update(env)
			try:
				os.execvp(argv[0], argv)
			except OSError:
				os._exit(127)
		self._child_pid = int(pid)
		self._master_fd = int(master)
		try:
			os.set_blocking(self._master_fd, False)
		except Exception:
			pass
		self._pty_resize(self._cols, self._rows)
		self._pty_stop.clear()
		self._pty_thread = threading.Thread(target=self._pty_reader, name="gcat-pty", daemon=True)
		self._pty_thread.start()
		_dbg("H-SPAWN", "ok", pid=self._child_pid, argv=argv[:4], cwd=cwd)
		self._emit({"event": "spawned", "pid": self._child_pid})

	def _stop_pty(self) -> None:
		self._pty_stop.set()
		if self._child_pid > 0:
			try:
				os.kill(self._child_pid, signal.SIGTERM)
			except OSError:
				pass
			self._child_pid = -1
		if self._master_fd >= 0:
			try:
				os.close(self._master_fd)
			except OSError:
				pass
			self._master_fd = -1
		th = self._pty_thread
		self._pty_thread = None
		if th and th.is_alive():
			th.join(timeout=0.4)

	def write(self, data: str) -> None:
		if not data or self._master_fd < 0:
			_dbg("H-WRITE", "skip", has_data=bool(data), fd=self._master_fd, pid=self._child_pid)
			return
		try:
			b = data.encode("utf-8", errors="replace")
			n = os.write(self._master_fd, b)
			_dbg(
				"H-WRITE",
				"ok",
				n=n,
				fd=self._master_fd,
				head=repr(data[:48]),
			)
		except OSError as e:
			_dbg("H-WRITE", "fail", err=str(e), fd=self._master_fd)

	def _clipboard_text(self) -> str:
		try:
			t = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD).wait_for_text()
			return t if t else ""
		except Exception:
			return ""

	def _clipboard_has_image(self) -> bool:
		clip = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
		for name in ("image/png", "image/bmp", "image/tiff", "image/jpeg", "PIXMAP", "image/webp"):
			try:
				if clip.wait_is_target_available(Gdk.Atom.intern(name, False)):
					return True
			except Exception:
				continue
		try:
			return clip.wait_for_image() is not None
		except Exception:
			return False

	def _export_clipboard_png(self) -> str | None:
		clip = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
		png: bytes | None = None
		try:
			pixbuf = clip.wait_for_image()
			if pixbuf is not None:
				ok, buf = pixbuf.save_to_bufferv("png", [], [])
				if ok and buf:
					png = bytes(buf)
		except Exception:
			pass
		if not png:
			return None
		clip_dir = os.path.join(tempfile.gettempdir(), "cursor-agent-clipboard")
		try:
			os.makedirs(clip_dir, exist_ok=True)
			path = os.path.join(clip_dir, "paste.png")
			with open(path, "wb") as f:
				f.write(png)
			return path
		except OSError:
			return None

	def _reseed_clipboard_png(self, path: str) -> bool:
		if which("xclip") is None:
			return False
		try:
			if self._xclip_proc is not None:
				self._xclip_proc.kill()
				self._xclip_proc = None
		except Exception:
			pass
		try:
			Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD).clear()
			while Gtk.events_pending():
				Gtk.main_iteration_do(False)
			proc = subprocess.Popen(
				["xclip", "-selection", "clipboard", "-t", "image/png", "-i", path],
				stdout=subprocess.DEVNULL,
				stderr=subprocess.DEVNULL,
			)
			self._xclip_proc = proc
			return True
		except Exception as e:  # noqa: BLE001
			_dbg("H-IMG", "reseed-fail", err=str(e))
			return False

	def _handle_paste(self, shift: bool = False) -> None:
		if shift:
			text = self._clipboard_text()
			if text:
				self.write(text.replace("\r\n", "\r").replace("\n", "\r"))
			return
		if self._clipboard_has_image():
			path = self._export_clipboard_png()
			_dbg("H-IMG", "export", path=path or "", has=bool(path))
			if path and self._reseed_clipboard_png(path):
				self._paste_gen += 1
				gen = self._paste_gen

				def _bg() -> None:
					# 等 xclip 坐稳再 Ctrl+V；agent 用 xclip -o 读图
					time.sleep(0.12)
					GLib.idle_add(self._send_image_paste, gen)

				threading.Thread(target=_bg, daemon=True).start()
				return
			_dbg("H-IMG", "fallback-text", reseed=False)
		text = self._clipboard_text()
		if text:
			self.write(text.replace("\r\n", "\r").replace("\n", "\r"))

	def _send_image_paste(self, gen: int) -> bool:
		if gen != self._paste_gen:
			return False
		_dbg("H-IMG", "ctrl-v")
		self.write(IMAGE_PASTE)
		return False

	def handle(self, msg: dict) -> None:
		cmd = msg.get("cmd")
		if cmd in ("attach", "embed"):
			self.attach(int(msg.get("xid") or 0))
		elif cmd == "geom":
			self.show_at(int(msg.get("x") or 0), int(msg.get("y") or 0), int(msg.get("w") or 800), int(msg.get("h") or 240))
		elif cmd == "hide":
			self.hide()
		elif cmd == "remount":
			self.remount()
		elif cmd == "refresh_paint":
			self.refresh_paint()
		elif cmd == "spawn":
			self.spawn(list(msg.get("argv") or []), str(msg.get("cwd") or ""))
		elif cmd == "write":
			data = str(msg.get("data") or "")
			_dbg("H-CMD", "write", n=len(data), head=repr(data[:48]))
			self.write(data)
		elif cmd == "scroll_bottom":
			self.scroll_bottom()
		elif cmd == "focus":
			if self._visible:
				self._focus_term()
		elif cmd == "paste":
			self._handle_paste(False)
		elif cmd == "ping":
			self._emit({"event": "pong"})
		elif cmd == "quit":
			self._stop_pty()
			Gtk.main_quit()

	def on_readable(self, _source, condition) -> bool:
		if condition & GLib.IO_HUP:
			self._stop_pty()
			Gtk.main_quit()
			return False
		try:
			chunk = self._conn.recv(4096)
		except BlockingIOError:
			return True
		except OSError:
			self._stop_pty()
			Gtk.main_quit()
			return False
		if not chunk:
			self._stop_pty()
			Gtk.main_quit()
			return False
		self._buf += chunk
		while b"\n" in self._buf:
			line, self._buf = self._buf.split(b"\n", 1)
			line = line.strip()
			if not line:
				continue
			try:
				msg = json.loads(line.decode("utf-8"))
			except (json.JSONDecodeError, UnicodeDecodeError) as e:
				self._emit({"event": "error", "message": f"bad json: {e}"})
				continue
			self.handle(msg)
		return True


def main() -> None:
	signal.signal(signal.SIGINT, signal.SIG_DFL)
	port_file = sys.argv[1] if len(sys.argv) > 1 else ""
	srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
	srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
	srv.bind(("127.0.0.1", 0))
	srv.listen(1)
	port = srv.getsockname()[1]
	if port_file:
		with open(port_file, "w", encoding="utf-8") as f:
			f.write(str(port))
	else:
		sys.stdout.write(json.dumps({"event": "listen", "port": port}) + "\n")
		sys.stdout.flush()

	host = Host()

	def on_accept(_source, _cond):
		conn, _addr = srv.accept()
		host.set_conn(conn)
		host._emit({"event": "ready"})
		GLib.io_add_watch(conn.fileno(), GLib.IO_IN | GLib.IO_HUP, host.on_readable)
		return False

	GLib.io_add_watch(srv.fileno(), GLib.IO_IN, on_accept)
	Gtk.main()
	host._stop_pty()
	try:
		srv.close()
	except OSError:
		pass
	if host._conn:
		try:
			host._conn.close()
		except OSError:
			pass


if __name__ == "__main__":
	main()
