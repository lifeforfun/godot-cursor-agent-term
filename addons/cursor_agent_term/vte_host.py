#!/usr/bin/env python3
"""Linux 专用 VTE 宿主（仅 plat_linux / vte_bridge 使用）。
叠在 Godot 槽位；沿用桌面 IME；键位对齐 GoLand（Shift+Enter / 贴图）。
macOS / Windows 勿引用本文件——各自实现放在对应 plat_* 与宿主里。
"""
from __future__ import annotations

import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import warnings

# 不强制本机输入法（ibus/fcitx 由桌面环境决定）；只保证 UTF-8 与 X11 后端
def _ensure_im_env() -> None:
	lang = (os.environ.get("LANG") or "").strip()
	if not lang.upper().endswith("UTF-8"):
		os.environ["LANG"] = "C.UTF-8"
	os.environ.setdefault("LC_CTYPE", os.environ.get("LANG", "C.UTF-8"))
	# Godot 叠窗依赖 X11 foreign window；Wayland 下走 XWayland
	os.environ.setdefault("GDK_BACKEND", "x11")


_ensure_im_env()

import gi

warnings.filterwarnings("ignore", category=DeprecationWarning)

gi.require_version("Gtk", "3.0")
gi.require_version("Vte", "2.91")
gi.require_version("Gdk", "3.0")

from gi.repository import Gtk, Vte, GLib, Gdk, Pango  # noqa: E402

try:
	gi.require_version("GdkX11", "3.0")
	from gi.repository import GdkX11
except Exception:  # noqa: BLE001
	GdkX11 = None

# GoLand TerminalKeyMapFeature.shiftEnter
SHIFT_ENTER = "\x1b[13;2u"
# GoLand ImagePasteFeature
IMAGE_PASTE = "\x16"

# 默认 10：dock 里多看几行；GCAT_TERM_FONT / GCAT_TERM_FONT_SIZE 可覆盖
try:
	_FONT_PT = max(7, min(18, int((os.environ.get("GCAT_TERM_FONT_SIZE") or "10").strip())))
except ValueError:
	_FONT_PT = 10

_custom_font = (os.environ.get("GCAT_TERM_FONT") or "").strip()
# 通用等宽优先，CJK 字体有则用；不依赖某台机器装了哪套中文字体
_FONT_CANDIDATES = []
if _custom_font:
	_parts = _custom_font.rsplit(" ", 1)
	if len(_parts) == 2 and _parts[1].isdigit():
		_FONT_CANDIDATES.append(_custom_font)
	else:
		_FONT_CANDIDATES.append(f"{_custom_font} {_FONT_PT}")
_FONT_CANDIDATES.extend(
	[
		f"Monospace {_FONT_PT}",
		f"DejaVu Sans Mono {_FONT_PT}",
		f"Noto Sans Mono {_FONT_PT}",
		f"Noto Sans Mono CJK SC {_FONT_PT}",
		f"WenQuanYi Micro Hei Mono {_FONT_PT}",
		f"Noto Sans CJK SC {_FONT_PT}",
		f"Source Han Sans SC {_FONT_PT}",
		f"Menlo {_FONT_PT}",
		f"Consolas {_FONT_PT}",
	]
)

# 设 GCAT_DEBUG=1 或 GCAT_VTE_DEBUG=1|/path 才写日志；未设则静默
_raw_vte_dbg = (os.environ.get("GCAT_VTE_DEBUG") or "").strip()
_DEBUG_PATH = ""
_DEFAULT_DBG = os.path.join(tempfile.gettempdir(), "gcat_vte_debug.log")
if _raw_vte_dbg in ("1", "true", "yes", "on"):
	_DEBUG_PATH = _DEFAULT_DBG
elif _raw_vte_dbg:
	_DEBUG_PATH = _raw_vte_dbg
elif (os.environ.get("GCAT_DEBUG") or "").strip():
	_DEBUG_PATH = _DEFAULT_DBG


def _dbg(tag: str, msg: str, **extra) -> None:
	if not _DEBUG_PATH:
		return
	try:
		line = {
			"t": time.strftime("%H:%M:%S"),
			"tag": tag,
			"msg": msg,
			**extra,
		}
		with open(_DEBUG_PATH, "a", encoding="utf-8") as f:
			f.write(json.dumps(line, ensure_ascii=False) + "\n")
	except OSError:
		pass


class Host:
	def __init__(self) -> None:
		# UTILITY + transient：钉在编辑器底栏槽位，避免 NORMAL 被 WM 拉大盖住 Output/编辑器
		self.win = Gtk.Window(type=Gtk.WindowType.TOPLEVEL)
		self.win.set_decorated(False)
		self.win.set_skip_taskbar_hint(True)
		self.win.set_skip_pager_hint(True)
		self.win.set_accept_focus(True)
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

		self.term = Vte.Terminal()
		self.term.set_can_focus(True)
		self.term.set_focus_on_click(True)
		self.term.set_input_enabled(True)
		self.term.set_cursor_blink_mode(Vte.CursorBlinkMode.ON)
		self.term.set_scrollback_lines(10000)
		self.term.set_scroll_on_output(True)
		self.term.set_scroll_on_keystroke(True)
		# 禁止 VTE 按行列自行 size_request 撑破宿主窗口
		try:
			self.term.set_property("geometry-hints", None)
		except Exception:
			pass
		self._apply_font()
		self.term.connect("child-exited", self._on_child_exited)
		self.term.connect("key-press-event", self._on_key_press)
		self.term.connect("button-press-event", self._on_term_button)
		self.win.add(self.term)

		self._child_pid = -1
		self._visible = False
		self._attached = False
		self._parent_xid = 0
		self._conn: socket.socket | None = None
		self._buf = b""
		self._last_geom = (None, None, None, None)
		self._clamp_armed = False
		self._xclip_proc: subprocess.Popen | None = None
		self._paste_gen = 0

	def _apply_font(self) -> None:
		for desc in _FONT_CANDIDATES:
			try:
				self.term.set_font(Pango.FontDescription(desc))
				break
			except Exception:
				continue
		# 略压行高/字宽，同高度多塞几行（旧 VTE 无此 API 则跳过）
		for name, scale in (("set_cell_height_scale", 0.92), ("set_cell_width_scale", 0.96)):
			fn = getattr(self.term, name, None)
			if callable(fn):
				try:
					fn(scale)
				except Exception:
					pass

	def set_conn(self, conn: socket.socket) -> None:
		self._conn = conn
		self._conn.setblocking(False)

	def _on_child_exited(self, *_args) -> None:
		self._child_pid = -1
		self._emit({"event": "child_exited"})

	def _emit(self, obj: dict) -> None:
		if self._conn is None:
			return
		try:
			self._conn.sendall((json.dumps(obj, ensure_ascii=False) + "\n").encode("utf-8"))
		except OSError:
			pass

	def _clipboard_targets(self) -> list[str]:
		clip = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
		atoms = clip.wait_for_targets()
		# wait_for_targets → (ok, [Atom,...]) 或仅 list，视绑定版本而定
		names: list[str] = []
		try:
			if isinstance(atoms, tuple) and len(atoms) >= 2:
				ok, lst = atoms[0], atoms[1]
				if not ok:
					return []
				atoms = lst
			for a in atoms or []:
				try:
					names.append(a.name() if hasattr(a, "name") else str(a))
				except Exception:
					names.append(str(a))
		except Exception as e:  # noqa: BLE001
			_dbg("H-IMG", "targets-error", err=str(e))
		return names

	def _clipboard_has_image(self) -> bool:
		names = self._clipboard_targets()
		lower = [n.lower() for n in names]
		img_hints = (
			"image/png",
			"image/bmp",
			"image/tiff",
			"image/jpeg",
			"image/jpg",
			"image/webp",
			"pixmap",
			"bitmap",
			"image",
		)
		hit = any(any(h in n for h in img_hints) for n in lower)
		_dbg("H-IMG", "clipboard-check", has_image=hit, targets=names[:24])
		if hit:
			return True
		clip = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
		for name in ("image/png", "image/bmp", "image/tiff", "image/jpeg", "PIXMAP", "image/webp"):
			try:
				if clip.wait_is_target_available(Gdk.Atom.intern(name, False)):
					_dbg("H-IMG", "clipboard-atom-hit", atom=name)
					return True
			except Exception:
				continue
		try:
			if clip.wait_for_image() is not None:
				_dbg("H-IMG", "clipboard-pixbuf-hit")
				return True
		except Exception:
			pass
		return False

	def _export_clipboard_png(self) -> str | None:
		"""把剪贴板图落成 PNG，供 xclip 重写。Qt 的 application/x-qt-image 常导致 agent 侧 xclip miss。"""
		clip = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
		pixbuf = None
		try:
			pixbuf = clip.wait_for_image()
		except Exception as e:  # noqa: BLE001
			_dbg("H-IMG", "pixbuf-fail", err=str(e))
		png: bytes | None = None
		if pixbuf is not None:
			try:
				ok, buf = pixbuf.save_to_bufferv("png", [], [])
				if ok and buf:
					png = bytes(buf)
			except Exception as e:  # noqa: BLE001
				_dbg("H-IMG", "pixbuf-encode-fail", err=str(e))
		if not png:
			for name in ("image/png", "image/bmp", "image/jpeg", "PIXMAP"):
				try:
					data = clip.wait_for_contents(Gdk.Atom.intern(name, False))
					if data is None:
						continue
					raw = data.get_data()
					if not raw:
						continue
					if name == "image/png":
						png = bytes(raw)
						break
					# 非 png：先经 pixbuf 再转
					loader = None
					try:
						from gi.repository import GdkPixbuf

						loader = GdkPixbuf.PixbufLoader()
						loader.write(bytes(raw))
						loader.close()
						pb = loader.get_pixbuf()
						if pb is not None:
							ok, buf = pb.save_to_bufferv("png", [], [])
							if ok and buf:
								png = bytes(buf)
								break
					except Exception as e:  # noqa: BLE001
						_dbg("H-IMG", "loader-fail", atom=name, err=str(e))
				except Exception as e:  # noqa: BLE001
					_dbg("H-IMG", "contents-fail", atom=name, err=str(e))
		if not png:
			_dbg("H-IMG", "export-empty")
			return None
		clip_dir = os.path.join(tempfile.gettempdir(), "cursor-agent-clipboard")
		try:
			os.makedirs(clip_dir, exist_ok=True)
		except OSError as e:
			_dbg("H-IMG", "mkdir-fail", err=str(e))
			return None
		path = os.path.join(clip_dir, f"gcat-{int(time.time() * 1000)}.png")
		try:
			with open(path, "wb") as f:
				f.write(png)
		except OSError as e:
			_dbg("H-IMG", "write-fail", err=str(e))
			return None
		_dbg("H-IMG", "exported-png", path=path, n=len(png))
		return path

	@staticmethod
	def _have_xclip() -> bool:
		from shutil import which

		return which("xclip") is not None

	def _kill_xclip_holders(self) -> None:
		if self._xclip_proc is not None:
			try:
				self._xclip_proc.kill()
			except Exception:
				pass
			self._xclip_proc = None
		from shutil import which

		if which("pkill"):
			subprocess.run(
				["pkill", "-f", "xclip -selection clipboard"],
				check=False,
				capture_output=True,
			)

	def _reseed_clipboard_png(self, path: str) -> bool:
		"""用 xclip 前台常驻提供 image/png（可选依赖；无 xclip 则跳过）。
		默认 -silent 会 fork 后父进程秒退；必须 -quiet -l 0 + stdin。
		先 clear+抽干 GTK 事件再启动 xclip，避免 GTK/Qt 仍占着 CLIPBOARD。"""
		if not self._have_xclip():
			_dbg("H-IMG", "reseed-skip-no-xclip")
			return False
		try:
			self._kill_xclip_holders()
			try:
				Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD).clear()
			except Exception:
				pass
			# 抽干 clear 的异步收尾，再让 xclip 夺权（顺序反了会 miss）
			for _ in range(30):
				if not Gtk.events_pending():
					break
				Gtk.main_iteration_do(False)
			time.sleep(0.02)
			fh = open(path, "rb")
			proc = subprocess.Popen(
				[
					"xclip",
					"-selection",
					"clipboard",
					"-t",
					"image/png",
					"-l",
					"0",
					"-quiet",
					"-i",
				],
				stdin=fh,
				stdout=subprocess.DEVNULL,
				stderr=subprocess.DEVNULL,
			)
			try:
				fh.close()
			except Exception:
				pass
			self._xclip_proc = proc
			GLib.timeout_add(40, self._xclip_alive_check, proc.pid)
			_dbg("H-IMG", "reseed-started", path=path, pid=proc.pid)
			return True
		except Exception as e:  # noqa: BLE001
			_dbg("H-IMG", "reseed-fail", err=str(e))
			return False

	def _xclip_alive_check(self, pid: int) -> bool:
		proc = self._xclip_proc
		if proc is None or proc.pid != pid:
			return False
		if proc.poll() is not None:
			_dbg("H-IMG", "reseed-xclip-died", code=proc.returncode, pid=pid)
			self._xclip_proc = None
		return False

	def _wait_clipboard_png_ready(self, expect_n: int, timeout_s: float = 1.5) -> int:
		"""在后台线程调用：确认 agent 同款 `xclip -o -t image/png` 已能读到数据。"""
		deadline = time.time() + timeout_s
		last_n = 0
		while time.time() < deadline:
			try:
				r = subprocess.run(
					["xclip", "-selection", "clipboard", "-t", "image/png", "-o"],
					capture_output=True,
					timeout=1.5,
					check=False,
				)
				last_n = len(r.stdout or b"")
				# PNG 头 + 合理大小；不必与 expect 完全相等（重编码可能略变）
				if last_n >= 64 and (r.stdout or b"").startswith(b"\x89PNG"):
					return last_n
			except Exception:
				pass
			time.sleep(0.04)
		return last_n

	def _focus_term(self) -> None:
		try:
			self.win.present()
			self.term.grab_focus()
		except Exception:
			pass

	def _on_win_button(self, _w, _e) -> bool:
		self._focus_term()
		return False

	def _on_term_button(self, _w, _e) -> bool:
		self._focus_term()
		return False

	def _on_key_press(self, _widget, event) -> bool:
		state = event.state & Gtk.accelerator_get_default_mod_mask()
		ctrl = bool(state & Gdk.ModifierType.CONTROL_MASK)
		shift = bool(state & Gdk.ModifierType.SHIFT_MASK)
		# 调试：记录可能相关的按键（Ctrl/Shift 组合）
		if ctrl or shift or event.keyval in (Gdk.KEY_v, Gdk.KEY_V, Gdk.KEY_Return):
			_dbg(
				"H-KEY",
				"key-press",
				keyval=int(event.keyval),
				keyname=Gdk.keyval_name(event.keyval) or "",
				ctrl=ctrl,
				shift=shift,
				state=int(state),
			)
		# Shift+Enter → CSI u（与 GoLand 一致）
		if event.keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter):
			if state == Gdk.ModifierType.SHIFT_MASK:
				self.write(SHIFT_ENTER)
				_dbg("H-KEY", "sent-shift-enter")
				return True
			return False
		# Ctrl+V / Ctrl+Shift+V：对齐 GoLand
		# - 有图 → 规范化 PNG + 0x16（触发 agent 贴图芯片）
		# - 有文本 → 直接写入 PTY（终端默认 Ctrl+V 只会发 0x16，agent 不贴文本）
		if event.keyval in (Gdk.KEY_v, Gdk.KEY_V) and ctrl:
			return self._handle_paste_shortcut(shift=shift)
		return False

	def _clipboard_text(self) -> str:
		clip = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
		try:
			t = clip.wait_for_text()
			return t if t else ""
		except Exception as e:  # noqa: BLE001
			_dbg("H-PASTE", "text-fail", err=str(e))
			return ""

	def _handle_paste_shortcut(self, shift: bool = False) -> bool:
		# Ctrl+Shift+V：始终当文本粘贴（终端习惯）
		if shift:
			text = self._clipboard_text()
			if text:
				self.write(text.replace("\r\n", "\r").replace("\n", "\r"))
				_dbg("H-PASTE", "text-shift-v", n=len(text))
				return True
			_dbg("H-PASTE", "shift-v-empty")
			return True

		has_img = self._clipboard_has_image()
		if has_img:
			path = self._export_clipboard_png()
			if path:
				# 导出已在本回调做完；交还主循环后再 reseed+0x16，避免堵死 GDK 剪贴板
				self._paste_gen += 1
				gen = self._paste_gen
				GLib.idle_add(self._finish_image_paste, path, gen)
				return True
			_dbg("H-IMG", "export-failed-fallback-text")

		text = self._clipboard_text()
		if text:
			self.write(text.replace("\r\n", "\r").replace("\n", "\r"))
			_dbg("H-PASTE", "text-ctrl-v", n=len(text), head=repr(text[:48]))
			return True

		_dbg("H-PASTE", "ctrl-v-empty")
		return True

	def _finish_image_paste(self, path: str, gen: int) -> bool:
		if gen != self._paste_gen:
			return False
		ok = self._reseed_clipboard_png(path)
		if not ok:
			_dbg("H-IMG", "reseed-abort-no-0x16", path=path)
			return False
		expect_n = 0
		try:
			expect_n = os.path.getsize(path)
		except OSError:
			pass

		def _bg() -> None:
			# 禁止在 GTK 主线程 xclip -o（GDK 剪贴板会死锁）
			n = self._wait_clipboard_png_ready(expect_n)
			_dbg("H-IMG", "reseed-verified", n=n, expect=expect_n, gen=gen)
			if n < 64:
				_dbg("H-IMG", "reseed-verify-empty-skip-0x16", n=n)
				return
			GLib.idle_add(self._send_image_paste_byte, path, gen, True, n)

		threading.Thread(target=_bg, name="gcat-clip-verify", daemon=True).start()
		return False

	def _send_image_paste_byte(self, path: str, gen: int, reseed_ok: bool, n: int = 0) -> bool:
		if gen != self._paste_gen:
			return False
		# 只发一次 0x16；补发会导致 Image 芯片出现两遍
		self.write(IMAGE_PASTE)
		_dbg("H-IMG", "sent-ctrl-v", bytes="0x16", path=path, reseed=reseed_ok, png_n=n)
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

	def show_at(self, x: int, y: int, w: int, h: int) -> None:
		"""严格按底栏槽位像素定位；不 present，避免 WM 改尺寸/抢焦点。"""
		if not self._attached:
			return
		w = max(1, int(w))
		h = max(1, int(h))
		x = int(x)
		y = int(y)
		geom = (x, y, w, h)
		if not self.win.get_realized():
			self.win.realize()
			GLib.idle_add(self._apply_transient)
		first = not self._visible
		self._last_geom = geom
		self._apply_geom_only(x, y, w, h)
		if first:
			self.win.show_all()
			self._visible = True
			# show 后再钉一次，抵消 map 时 WM/VTE 撑大
			GLib.idle_add(self._apply_geom_only, x, y, w, h)
			GLib.timeout_add(50, self._apply_geom_only, x, y, w, h)
			GLib.timeout_add(200, self._apply_geom_only, x, y, w, h)
			_dbg("H-GEOM", "show", x=x, y=y, w=w, h=h)
		else:
			_dbg("H-GEOM", "move", x=x, y=y, w=w, h=h)

	def _lock_size_hints(self, w: int, h: int) -> None:
		"""WM 层把窗口钉死在像素矩形（min=max）。"""
		try:
			g = Gdk.Geometry()
			g.min_width = w
			g.max_width = w
			g.min_height = h
			g.max_height = h
			g.base_width = w
			g.base_height = h
			hints = (
				Gdk.WindowHints.MIN_SIZE
				| Gdk.WindowHints.MAX_SIZE
				| Gdk.WindowHints.BASE_SIZE
			)
			self.win.set_geometry_hints(self.win, g, hints)
		except Exception as e:  # noqa: BLE001
			_dbg("H-GEOM", "hints-fail", err=str(e))

	def _sync_pty_from_pixels(self, w: int, h: int) -> None:
		"""像素已定后，只同步 PTY 行列（SIGWINCH），绝不用行列去决定窗口大小。"""
		try:
			# 先按像素要空间，堵住 VTE 用「偏好行列×字宽」反向撑父窗
			self.term.set_size_request(w, h)
			cw = int(self.term.get_char_width() or 0)
			ch = int(self.term.get_char_height() or 0)
			if cw < 1 or ch < 1:
				return
			self.term.set_size(max(1, w // cw), max(1, h // ch))
		except Exception as e:  # noqa: BLE001
			_dbg("H-GEOM", "pty-sync-fail", err=str(e))

	def _apply_geom_only(self, x: int, y: int, w: int, h: int) -> bool:
		"""唯一尺寸来源：屏幕像素矩形。"""
		try:
			self._lock_size_hints(w, h)
			self.win.set_size_request(w, h)
			self.win.set_default_size(w, h)
			self.term.set_size_request(w, h)
			self.win.resize(w, h)
			self.win.move(x, y)
			gdk_win = self.win.get_window()
			if gdk_win is not None:
				gdk_win.set_keep_above(False)
				gdk_win.move_resize(x, y, w, h)
			# 像素钉完再告诉 PTY 这格里能排几字（agent TUI 用）
			self._sync_pty_from_pixels(w, h)
			# 用 GDK 实际几何判断漂移；allocation 在 map 前常是 200x200，不能拿来狂刷 reclamp
			gdk_win = self.win.get_window()
			if gdk_win is not None:
				geo = gdk_win.get_geometry()
				gw = int(geo.width)
				gh = int(geo.height)
				if gw and gh and (abs(gw - w) > 4 or abs(gh - h) > 4):
					_dbg("H-GEOM", "drift", want_w=w, want_h=h, got_w=gw, got_h=gh)
					if not self._clamp_armed:
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
			ew = int(event.width)
			eh = int(event.height)
			ex = int(event.x)
			ey = int(event.y)
			if abs(ew - g[2]) > 2 or abs(eh - g[3]) > 2 or abs(ex - g[0]) > 2 or abs(ey - g[1]) > 2:
				_dbg("H-GEOM", "configure-drift", x=ex, y=ey, w=ew, h=eh, want=list(g))
				if not self._clamp_armed:
					self._clamp_armed = True
					GLib.idle_add(self._reclamp_last)
		except Exception:
			pass
		return False

	def hide(self) -> None:
		if self._visible:
			self.win.hide()
			self._visible = False
			self._last_geom = (None, None, None, None)
			self._clamp_armed = False

	def scroll_bottom(self) -> None:
		adj = self.term.get_vadjustment()
		if adj is None:
			return
		upper = adj.get_upper()
		page = adj.get_page_size()
		adj.set_value(max(adj.get_lower(), upper - page))

	def spawn(self, argv: list[str], cwd: str) -> None:
		if not argv:
			self._emit({"event": "error", "message": "empty argv"})
			return
		cwd = cwd or os.path.expanduser("~")
		env = os.environ.copy()
		env["TERM"] = "xterm-256color"
		env["COLORTERM"] = "truecolor"
		env["LANG"] = env.get("LANG") or "en_US.UTF-8"
		env["LC_CTYPE"] = env.get("LC_CTYPE") or env["LANG"]
		# 透传 IM，保证 cursor-agent TUI 内也能用系统输入法
		for k in ("GTK_IM_MODULE", "QT_IM_MODULE", "XMODIFIERS", "IBUS_ADDRESS"):
			if k in os.environ:
				env[k] = os.environ[k]
		envv = [f"{k}={v}" for k, v in env.items()]
		try:
			ok, pid = self.term.spawn_sync(
				Vte.PtyFlags.DEFAULT,
				cwd,
				argv,
				envv,
				GLib.SpawnFlags.DEFAULT,
				None,
				None,
			)
			if ok:
				self._child_pid = int(pid)
				self._emit({"event": "spawned", "pid": self._child_pid})
				GLib.idle_add(self._focus_term_idle)
				# TUI 启动常改行列，延迟再钉回槽位
				if self._visible and self._last_geom[0] is not None:
					GLib.idle_add(self._reclamp_last)
					GLib.timeout_add(80, self._reclamp_last)
					GLib.timeout_add(250, self._reclamp_last)
			else:
				self._emit({"event": "error", "message": "spawn_sync failed"})
		except Exception as e:  # noqa: BLE001
			self._emit({"event": "error", "message": str(e)})

	def write(self, data: str) -> None:
		"""写入 PTY。优先 master fd（feed_child 对 0x16 等控制字节可能静默失败）。"""
		if not data:
			return
		b = data.encode("utf-8", errors="replace")
		written = 0
		method = ""
		# 1) 直接写 PTY master
		try:
			pty = self.term.get_pty()
			if pty is not None:
				fd = pty.get_fd()
				if fd is not None and int(fd) >= 0:
					written = os.write(int(fd), b)
					method = "pty-fd"
		except Exception as e:  # noqa: BLE001
			_dbg("H-WRITE", "pty-fd-fail", err=str(e))
		# 2) 回退 feed_child*
		if written <= 0:
			try:
				self.term.feed_child_binary(b)
				written = len(b)
				method = "feed_child_binary"
			except TypeError:
				try:
					self.term.feed_child(data, len(data))
					written = len(b)
					method = "feed_child"
				except Exception as e:  # noqa: BLE001
					try:
						self.term.feed(b)
						written = len(b)
						method = "feed"
					except Exception as e2:  # noqa: BLE001
						_dbg("H-WRITE", "all-fail", err=str(e), err2=str(e2))
						return
			except Exception as e:  # noqa: BLE001
				_dbg("H-WRITE", "feed-fail", err=str(e))
				return
		_dbg(
			"H-WRITE",
			"ok",
			method=method,
			n=written,
			hex=" ".join(f"{x:02x}" for x in b[:16]),
		)

	def handle(self, msg: dict) -> None:
		cmd = msg.get("cmd")
		if cmd in ("attach", "embed"):
			self.attach(int(msg.get("xid") or 0))
		elif cmd == "geom":
			self.show_at(msg.get("x", 0), msg.get("y", 0), msg.get("w", 800), msg.get("h", 240))
		elif cmd == "hide":
			self.hide()
		elif cmd == "spawn":
			self.spawn(list(msg.get("argv") or []), str(msg.get("cwd") or ""))
		elif cmd == "write":
			data = str(msg.get("data") or "")
			_dbg("H-CMD", "write", n=len(data), head=repr(data[:32]))
			self.write(data)
		elif cmd == "scroll_bottom":
			self.scroll_bottom()
		elif cmd == "focus":
			if self._visible:
				self._focus_term()
				_dbg("H-CMD", "focus")
		elif cmd == "quit":
			Gtk.main_quit()
		elif cmd == "ping":
			self._emit({"event": "pong"})
		elif cmd == "paste":
			# 与 Ctrl+V 同一路径（图 / 文本）
			self._handle_paste_shortcut(shift=False)
		elif cmd == "debug_clipboard":
			has_img = self._clipboard_has_image()
			self._emit({"event": "clipboard", "has_image": has_img, "targets": self._clipboard_targets()[:24]})

	def on_readable(self, _source, condition) -> bool:
		if condition & GLib.IO_HUP:
			Gtk.main_quit()
			return False
		try:
			chunk = self._conn.recv(4096)
		except BlockingIOError:
			return True
		except OSError:
			Gtk.main_quit()
			return False
		if not chunk:
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
