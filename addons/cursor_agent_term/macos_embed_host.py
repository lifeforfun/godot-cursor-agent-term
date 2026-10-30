#!/usr/bin/env python3
"""macOS 专用内嵌终端宿主（仅 plat_macos / macos_bridge 使用）。

无边框 NSPanel 叠在 Godot 槽位；WKWebView + xterm.js 渲染；真 PTY 跑 cursor-agent。
TCP NDJSON 协议对齐 Linux vte_host。Linux / Windows 勿引用。
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
import sys
import tempfile
import termios
import threading
import time
from pathlib import Path

SHIFT_ENTER = "\x1b[13;2u"
IMAGE_PASTE = "\x16"

try:
	_FONT_PT = max(7, min(18, int((os.environ.get("GCAT_TERM_FONT_SIZE") or "10").strip())))
except ValueError:
	_FONT_PT = 10

# 设 GCAT_DEBUG=1 或 GCAT_VTE_DEBUG=1|/path 才写日志；未设则静默（对齐 Linux vte_host）
_raw_dbg = (os.environ.get("GCAT_VTE_DEBUG") or os.environ.get("GCAT_DEBUG") or "").strip()
_DEFAULT_DBG = os.path.join(tempfile.gettempdir(), "gcat_macos_debug.log")
_DEBUG_PATH = ""
if _raw_dbg in ("1", "true", "yes", "on"):
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
			f.flush()
	except OSError:
		pass


def _assets_dir() -> Path:
	return Path(__file__).resolve().parent / "macos_xterm"


def main() -> None:
	signal.signal(signal.SIGINT, signal.SIG_DFL)
	port_file = sys.argv[1] if len(sys.argv) > 1 else ""

	from AppKit import (
		NSApplication,
		NSApplicationActivationPolicyAccessory,
		NSBackingStoreBuffered,
		NSColor,
		NSEvent,
		NSEventMaskLeftMouseDown,
		NSMakeRect,
		NSPanel,
		NSPasteboard,
		NSPasteboardTypeString,
		NSScreen,
		NSWindowStyleMaskBorderless,
		NSWindowStyleMaskNonactivatingPanel,
	)
	from Foundation import NSObject, NSURL
	from PyObjCTools import AppHelper
	from WebKit import (
		WKUserContentController,
		WKUserScript,
		WKUserScriptInjectionTimeAtDocumentStart,
		WKWebView,
		WKWebViewConfiguration,
		WKWebsiteDataStore,
	)
	from objc import super as objc_super

	assets = _assets_dir()
	html_path = assets / "index.html"
	_dbg("H-BOOT", "start", assets=str(assets), html=str(html_path), log=_DEBUG_PATH or "(off)")
	if not html_path.is_file():
		_dbg("H-BOOT", "missing-html")
		sys.stderr.write(f"missing assets: {html_path}\n")
		sys.exit(2)

	class NavDelegate(NSObject):
		_host = None

		def initWithHost_(self, host):  # noqa: N802
			self = objc_super(NavDelegate, self).init()
			if self is None:
				return None
			self._host = host
			return self

		def webView_didFinishNavigation_(self, _web, _nav):  # noqa: N802
			_dbg("H-WEB", "did-finish")

		def webView_didFailNavigation_withError_(self, _web, _nav, err):  # noqa: N802
			_dbg("H-WEB", "did-fail", err=str(err))

		def webView_didFailProvisionalNavigation_withError_(self, _web, _nav, err):  # noqa: N802
			_dbg("H-WEB", "did-fail-provisional", err=str(err))

	class FrontAppObserver(NSObject):
		_host = None

		def initWithHost_(self, host):  # noqa: N802
			self = objc_super(FrontAppObserver, self).init()
			if self is None:
				return None
			self._host = host
			return self

		def onActivate_(self, _note):  # noqa: N802
			host = self._host
			if host is not None:
				host._sync_front_app("activate")

	# 对齐 Linux 2f9c951：默认不接焦点；仅 _accept_keys 时 canBecomeKey。
	# 无边框窗系统默认 canBecomeKeyWindow=NO，必须子类放开。
	class GcatPanel(NSPanel):
		_host_ref = None

		def setHost_(self, host):  # noqa: N802
			self._host_ref = host

		def canBecomeKeyWindow(self):  # noqa: N802
			h = self._host_ref
			return bool(h is not None and getattr(h, "_accept_keys", False))

		def canBecomeMainWindow(self):  # noqa: N802
			return False

	class WinDelegate(NSObject):
		_host = None

		def initWithHost_(self, host):  # noqa: N802
			self = objc_super(WinDelegate, self).init()
			if self is None:
				return None
			self._host = host
			return self

		def windowDidResignKey_(self, _note):  # noqa: N802
			# 对齐 vte _on_focus_out：放下接键；不 activate Godot、不还焦点拉锯
			host = self._host
			if host is not None:
				host._on_resign_key()

	class Host:
		def __init__(self) -> None:
			self._conn: socket.socket | None = None
			self._buf = b""
			self._attached = False
			self._visible = False
			self._last_geom = None
			self._child_pid = -1
			self._master_fd = -1
			self._pty_thread: threading.Thread | None = None
			self._pty_stop = threading.Event()
			self._cols = 80
			self._rows = 24
			self._web_ready = False
			self._pending_out = bytearray()
			self._pending_lock = threading.Lock()
			self._want_visible = False  # dock 要求显示；真正是否可见还看 Godot 是否前台
			self._accept_keys = False  # 对齐 GTK accept_focus：默认 False，点击/显式 focus 才 True

			self.app = NSApplication.sharedApplication()
			# Accessory：不占 Dock。geom/show 不 activate；仅点击/focus 临时接键盘（见 focus）
			self.app.setActivationPolicy_(NSApplicationActivationPolicyAccessory)

			# NonactivatingPanel ≈ 默认不抢激活 / 少进 Cmd+Tab；接键靠 _accept_keys + focus()
			style = NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
			self.win = GcatPanel.alloc().initWithContentRect_styleMask_backing_defer_(
				NSMakeRect(80, 80, 480, 240),
				style,
				NSBackingStoreBuffered,
				False,
			)
			self.win.setHost_(self)
			self.win.setTitle_("gcat-macos-term")
			self.win.setOpaque_(True)
			self.win.setBackgroundColor_(NSColor.colorWithCalibratedRed_green_blue_alpha_(0.08, 0.08, 0.08, 1.0))
			self.win.setHasShadow_(False)
			self.win.setFloatingPanel_(True)
			self.win.setBecomesKeyOnlyIfNeeded_(True)
			self.win.setHidesOnDeactivate_(False)  # 宿主是独立进程，不能靠 deactivate；见 _sync_front_app
			self.win.setReleasedWhenClosed_(False)
			self.win.setMovable_(False)
			self._win_delegate = WinDelegate.alloc().initWithHost_(self)
			self.win.setDelegate_(self._win_delegate)
			# 略高于普通窗即可；PopUpMenu 级会盖住 Cmd+Tab / 其它 App
			try:
				from AppKit import NSFloatingWindowLevel

				self.win.setLevel_(NSFloatingWindowLevel)
			except Exception:
				self.win.setLevel_(3)

			cfg = WKWebViewConfiguration.alloc().init()
			ucc = WKUserContentController.alloc().init()
			self._handler = MsgHandler.alloc().initWithHost_(self)
			ucc.addScriptMessageHandler_name_(self._handler, "gcat")
			boot = WKUserScript.alloc().initWithSource_injectionTime_forMainFrameOnly_(
				f"window.GCAT_FONT_SIZE = {_FONT_PT};",
				WKUserScriptInjectionTimeAtDocumentStart,
				True,
			)
			ucc.addUserScript_(boot)
			cfg.setUserContentController_(ucc)
			try:
				cfg.setWebsiteDataStore_(WKWebsiteDataStore.nonPersistentDataStore())
			except Exception:
				pass

			self.web = WKWebView.alloc().initWithFrame_configuration_(NSMakeRect(0, 0, 480, 240), cfg)
			self._nav = NavDelegate.alloc().initWithHost_(self)
			self.web.setNavigationDelegate_(self._nav)
			try:
				self.web.setOpaque_(True)
			except Exception:
				pass
			try:
				# 避免未铺满时露出 WKWebView 默认白底（右侧白条）
				self.web.setValue_forKey_(False, "drawsBackground")
			except Exception:
				pass
			try:
				self.web.setUnderPageBackgroundColor_(
					NSColor.colorWithCalibratedRed_green_blue_alpha_(0.08, 0.08, 0.08, 1.0)
				)
			except Exception:
				pass
			self.win.setContentView_(self.web)
			url = NSURL.fileURLWithPath_(str(html_path))
			_dbg("H-WEB", "load", url=str(url))
			self.web.loadFileURL_allowingReadAccessToURL_(url, NSURL.fileURLWithPath_(str(assets)))
			self._install_front_app_watch()
			self._install_click_focus()

		def set_conn(self, conn: socket.socket) -> None:
			self._conn = conn
			self._conn.setblocking(False)

		def _install_front_app_watch(self) -> None:
			## 只有 Godot 前台时显示叠窗；切到其它 App / Cmd+Tab 时隐藏
			try:
				from AppKit import NSWorkspace
				from Foundation import NSNotificationCenter

				ws = NSWorkspace.sharedWorkspace()
				nc = ws.notificationCenter()
				self._front_obs = FrontAppObserver.alloc().initWithHost_(self)
				nc.addObserver_selector_name_object_(
					self._front_obs,
					b"onActivate:",
					"NSWorkspaceDidActivateApplicationNotification",
					None,
				)
				_dbg("H-APP", "watch-ok")
			except Exception as e:  # noqa: BLE001
				_dbg("H-APP", "watch-fail", err=str(e))

		def _is_self_app(self, app) -> bool:
			try:
				return int(app.processIdentifier()) == int(os.getpid())
			except Exception:
				return False

		def _godot_is_front(self) -> bool:
			## Godot 前台，或本宿主因点击临时接键成为前台时，叠窗保持显示（勿因此 hide）
			try:
				from AppKit import NSWorkspace

				app = NSWorkspace.sharedWorkspace().frontmostApplication()
				if app is None:
					return False
				if self._is_self_app(app):
					return True
				name = str(app.localizedName() or "")
				bid = str(app.bundleIdentifier() or "")
				return ("Godot" in name) or ("godot" in bid.lower())
			except Exception:
				return True

		def _install_click_focus(self) -> None:
			## 对齐 vte button-press → _focus_term；不在 geom/spawn 里接键
			try:

				def _on_down(event):
					try:
						w = event.window()
						if w is not None and w == self.win:
							AppHelper.callAfter(self.focus)
					except Exception:
						pass
					return event

				self._mouse_mon = NSEvent.addLocalMonitorForEventsMatchingMask_handler_(
					NSEventMaskLeftMouseDown, _on_down
				)
				_dbg("H-FOCUS", "click-watch-ok")
			except Exception as e:  # noqa: BLE001
				_dbg("H-FOCUS", "click-watch-fail", err=str(e))

		def _on_resign_key(self) -> None:
			self._accept_keys = False
			self._apply_input_passthrough()
			_dbg("H-FOCUS", "resign")

		def _apply_input_passthrough(self) -> None:
			## 未接键时穿透鼠标，避免 Floating 叠窗挡住 Godot 下拉/选项弹层
			try:
				self.win.setIgnoresMouseEvents_(not self._accept_keys)
			except Exception as e:  # noqa: BLE001
				_dbg("H-FOCUS", "passthrough-fail", err=str(e))

		def _sync_front_app(self, reason: str = "") -> None:
			## 只 orderFront/Out，绝不 makeKey / activate（避免 show 时抢焦点）
			should = bool(self._want_visible and self._godot_is_front())
			if should:
				try:
					self.win.orderFront_(None)
				except Exception:
					pass
				self._visible = True
				self._apply_input_passthrough()
			else:
				self._accept_keys = False
				try:
					self.win.orderOut_(None)
				except Exception:
					pass
				self._visible = False
			_dbg("H-APP", "sync", reason=reason, want=self._want_visible, show=should)

		def _emit(self, obj: dict) -> None:
			if self._conn is None:
				return
			try:
				self._conn.sendall((json.dumps(obj, ensure_ascii=False) + "\n").encode("utf-8"))
			except OSError:
				pass

		def _js(self, script: str) -> None:
			try:
				self.web.evaluateJavaScript_completionHandler_(script, None)
			except Exception as e:  # noqa: BLE001
				_dbg("H-JS", "fail", err=str(e))

		def _flush_pending(self) -> None:
			with self._pending_lock:
				data = bytes(self._pending_out)
				self._pending_out.clear()
			if data:
				_dbg("H-PTY", "flush-pending", n=len(data))
				self._write_term_bytes_now(data)

		def _write_term_bytes_now(self, data: bytes) -> None:
			if not data:
				return
			b64 = base64.b64encode(data).decode("ascii")
			for i in range(0, len(b64), 24000):
				self._js(f"window.gcatWriteB64 && window.gcatWriteB64('{b64[i:i+24000]}')")

		def _write_term_bytes(self, data: bytes) -> None:
			if not data:
				return
			if not self._web_ready:
				with self._pending_lock:
					self._pending_out.extend(data)
					# 防止无限涨
					if len(self._pending_out) > 512_000:
						del self._pending_out[:-256_000]
				return
			self._write_term_bytes_now(data)

		def _screen_span(self):
			screens = list(NSScreen.screens() or [])
			if not screens:
				return 0.0, 0.0, 1.0, []
			max_top = max(float(s.frame().origin.y) + float(s.frame().size.height) for s in screens)
			min_y = min(float(s.frame().origin.y) for s in screens)
			return max_top, min_y, max_top - min_y, screens

		def _rect_on_screens(self, rect, screens) -> bool:
			rx, ry = float(rect.origin.x), float(rect.origin.y)
			rw, rh = float(rect.size.width), float(rect.size.height)
			for s in screens:
				f = s.frame()
				fx, fy = float(f.origin.x), float(f.origin.y)
				fw, fh = float(f.size.width), float(f.size.height)
				if rx + rw <= fx or fx + fw <= rx or ry + rh <= fy or fy + fh <= ry:
					continue
				return True
			return False

		def _quartz_godot_bounds(self):
			## CGWindow 坐标：主屏左上为原点、y 向下（与 Godot screen 系不同）。
			## 优先编辑器窗（标题含 Godot Engine）；避免 F5 游戏窗抢锚导致浮层漂到槽位左边。
			try:
				from Quartz import (  # noqa: WPS433
					CGWindowListCopyWindowInfo,
					kCGNullWindowID,
					kCGWindowListOptionOnScreenOnly,
				)
			except Exception as e:  # noqa: BLE001
				_dbg("H-GEOM", "quartz-import-fail", err=str(e))
				return None
			try:
				wins = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID)
			except Exception as e:  # noqa: BLE001
				_dbg("H-GEOM", "quartz-list-fail", err=str(e))
				return None
			best = None
			best_score = -1.0
			for info in wins or []:
				d = dict(info)
				name = str(d.get("kCGWindowOwnerName") or "")
				if "Godot" not in name:
					continue
				b = d.get("kCGWindowBounds")
				if not b:
					continue
				bd = dict(b)
				w = float(bd.get("Width") or 0)
				h = float(bd.get("Height") or 0)
				area = w * h
				layer = int(d.get("kCGWindowLayer") or 0)
				if layer != 0 or area < 32 * 32:
					continue
				title = str(d.get("kCGWindowName") or "")
				# 编辑器标题常见 "… - Godot Engine"；游戏窗多是项目名/场景名
				is_editor = ("Godot Engine" in title) or title.endswith(".godot")
				score = area + (1.0e12 if is_editor else 0.0)
				if score > best_score:
					best_score = score
					best = bd
			if best is not None:
				_dbg(
					"H-GEOM",
					"quartz-pick",
					editor_bias=best_score >= 1.0e12,
					bounds=(
						float(best.get("X") or 0),
						float(best.get("Y") or 0),
						float(best.get("Width") or 0),
						float(best.get("Height") or 0),
					),
				)
			return best

		def _quartz_to_cocoa(self, qx: float, qy: float, qw: float, qh: float):
			## Quartz(左上、y下) → Cocoa(左下、y上)：按主屏高度翻转；多屏时 Quartz Y 可负。
			primary = NSScreen.mainScreen().frame()
			ph = float(primary.size.height)
			# Quartz Y=0 对齐主屏顶；主屏顶的 Cocoa y = primary.origin.y + ph
			top_cocoa = float(primary.origin.y) + ph
			return NSMakeRect(qx, top_cocoa - qy - qh, qw, qh)

		def _godot_to_cocoa(self, x: int, y: int, w: int, h: int):
			## 优先：Godot 虚拟桌面坐标 → Cocoa；失败则按 Quartz；再失败贴 Godot 窗。
			max_top, _min_y, span, screens = self._screen_span()
			if not screens:
				return NSMakeRect(float(x), float(y), float(w), float(h))
			gx, gy, gw, gh = float(x), float(y), float(max(1, w)), float(max(1, h))
			scale = 1.0
			try:
				scale = float(NSScreen.mainScreen().backingScaleFactor() or 1.0)
			except Exception:
				scale = 1.0
			candidates = []
			# A) Godot 虚拟桌面（顶=0）
			candidates.append(("godot-virt", NSMakeRect(gx, max_top - gy - gh, gw, gh)))
			if scale > 1.01:
				candidates.append(
					(
						"godot-virt/scale",
						NSMakeRect(gx / scale, max_top - gy / scale - gh / scale, gw / scale, gh / scale),
					)
				)
			# B) 当作 Quartz 主屏坐标
			candidates.append(("quartz", self._quartz_to_cocoa(gx, gy, gw, gh)))
			if scale > 1.01:
				candidates.append(
					("quartz/scale", self._quartz_to_cocoa(gx / scale, gy / scale, gw / scale, gh / scale))
				)

			for tag, rect in candidates:
				if self._rect_on_screens(rect, screens):
					_dbg(
						"H-GEOM",
						"pick",
						tag=tag,
						cocoa=(float(rect.origin.x), float(rect.origin.y), float(rect.size.width), float(rect.size.height)),
					)
					return rect

			# C) 贴到当前 Godot 窗口客户区（CGWindow），避免再飞到另一块屏
			gb = self._quartz_godot_bounds()
			if gb:
				qx = float(gb.get("X") or 0)
				qy = float(gb.get("Y") or 0)
				qw = float(gb.get("Width") or 800)
				qh = float(gb.get("Height") or 400)
				# 估槽位：底栏约下方 35%–90% 宽居中偏下（无相对坐标时的可见兜底）
				slot_w = min(gw if gw < qw else qw * 0.9, qw - 16)
				slot_h = min(gh if gh < qh else qh * 0.55, qh - 48)
				slot_x = qx + (qw - slot_w) * 0.5
				slot_y = qy + qh - slot_h - 8
				rect = self._quartz_to_cocoa(slot_x, slot_y, slot_w, slot_h)
				_dbg(
					"H-GEOM",
					"snap-godot-window",
					godot_win=(qx, qy, qw, qh),
					cocoa=(float(rect.origin.x), float(rect.origin.y), float(rect.size.width), float(rect.size.height)),
				)
				return rect

			vis = NSScreen.mainScreen().visibleFrame()
			_dbg("H-GEOM", "clamp-main", godot=(x, y, w, h))
			return NSMakeRect(
				float(vis.origin.x) + 40,
				float(vis.origin.y) + 40,
				min(gw, float(vis.size.width) - 80),
				min(gh, float(vis.size.height) - 80),
			)

		def attach(self, parent_ptr: int) -> None:
			## 叠窗靠 geom 钉在槽位；parent 绑定在部分 PyObjC 版本不可用，可后续再补。
			self._attached = True
			parent_ptr = int(parent_ptr or 0)
			_dbg("H-ATTACH", "ok", xid=parent_ptr)
			self._emit({"event": "attached", "xid": parent_ptr})

		def _frame_from_rel(self, fx: float, fy: float, fw: float, fh: float):
			## 相对 Godot 窗口客户区（CGWindow bounds，Quartz 坐标）→ Cocoa frame
			gb = self._quartz_godot_bounds()
			if not gb:
				return None
			qx = float(gb.get("X") or 0)
			qy = float(gb.get("Y") or 0)
			qw = float(gb.get("Width") or 0)
			qh = float(gb.get("Height") or 0)
			if qw < 32 or qh < 32:
				return None
			fx = max(0.0, min(1.0, float(fx)))
			fy = max(0.0, min(1.0, float(fy)))
			fw = max(0.02, min(1.0 - fx, float(fw)))
			fh = max(0.02, min(1.0 - fy, float(fh)))
			sx = qx + qw * fx
			sy = qy + qh * fy
			sw = max(32.0, qw * fw)
			sh = max(32.0, qh * fh)
			rect = self._quartz_to_cocoa(sx, sy, sw, sh)
			_dbg(
				"H-GEOM",
				"rel",
				godot_win=(qx, qy, qw, qh),
				frac=(fx, fy, fw, fh),
				cocoa=(float(rect.origin.x), float(rect.origin.y), float(rect.size.width), float(rect.size.height)),
			)
			return rect, sw, sh

		def show_at(self, x: int, y: int, w: int, h: int, rel=None) -> None:
			if not self._attached:
				_dbg("H-GEOM", "skip-not-attached", x=x, y=y, w=w, h=h)
				return
			try:
				frame = None
				cw = ch = 0.0
				if rel is not None:
					got = self._frame_from_rel(rel[0], rel[1], rel[2], rel[3])
					if got is not None:
						frame, cw, ch = got
				if frame is None:
					w = max(1, int(w))
					h = max(1, int(h))
					x, y = int(x), int(y)
					self._last_geom = (x, y, w, h)
					frame = self._godot_to_cocoa(x, y, w, h)
					cw, ch = float(frame.size.width), float(frame.size.height)
				else:
					self._last_geom = (int(x), int(y), int(w), int(h))
				self.win.setFrame_display_(frame, True)
				self.web.setFrame_(NSMakeRect(0, 0, float(cw), float(ch)))
				self._want_visible = True
				first = not self._visible
				self._sync_front_app("geom")
				self._js("window.gcatFit && window.gcatFit()")
				fr = self.win.frame()
				_dbg(
					"H-GEOM",
					"show" if first else "move",
					x=x,
					y=y,
					w=w,
					h=h,
					cocoa_x=float(fr.origin.x),
					cocoa_y=float(fr.origin.y),
					cocoa_w=float(fr.size.width),
					cocoa_h=float(fr.size.height),
					visible=bool(self.win.isVisible()),
					level=int(self.win.level()),
					web_ready=self._web_ready,
					godot_front=self._godot_is_front(),
				)
			except Exception as e:  # noqa: BLE001
				_dbg("H-GEOM", "show-fail", err=str(e))

		def hide(self) -> None:
			## 只藏窗，保留 _last_geom，便于弹层关闭后立刻按原几何 show
			self._want_visible = False
			self._accept_keys = False
			self._apply_input_passthrough()
			try:
				self.win.orderOut_(None)
			except Exception:
				pass
			self._visible = False
			_dbg("H-GEOM", "hide")

		def focus(self) -> None:
			"""用户点终端 / 显式 focus：临时接键盘。对齐 vte_host._focus_term（2f9c951）。

			- 不在 geom/spawn 调用；show 只用 orderFront
			- 跨进程必须 activate 才能收键（≈ Linux gdk_win.focus），仅此处
			- 失焦只清 _accept_keys，不 activate Godot / 不还焦点拉锯
			"""
			if not self._want_visible:
				return
			if not self._godot_is_front():
				return
			try:
				self._accept_keys = True
				self._apply_input_passthrough()
				self.app.activateIgnoringOtherApps_(True)
				self.win.makeKeyAndOrderFront_(None)
				try:
					self.win.makeFirstResponder_(self.web)
				except Exception:
					pass
				self._js("window.gcatFocus && window.gcatFocus()")
				_dbg(
					"H-FOCUS",
					"ok",
					key=bool(self.win.isKeyWindow()),
					first=str(self.win.firstResponder()),
				)
			except Exception as e:  # noqa: BLE001
				self._accept_keys = False
				_dbg("H-FOCUS", "fail", err=str(e))

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
				AppHelper.callAfter(self._write_term_bytes, data)
			if self._child_pid > 0:
				pid = self._child_pid
				self._child_pid = -1
				AppHelper.callAfter(self._emit, {"event": "child_exited", "pid": pid})

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
				return
			b = data.encode("utf-8", errors="replace")
			try:
				os.write(self._master_fd, b)
			except OSError as e:
				_dbg("H-WRITE", "fail", err=str(e))

		def _clipboard_text(self) -> str:
			pb = NSPasteboard.generalPasteboard()
			try:
				t = pb.stringForType_(NSPasteboardTypeString)
				return str(t) if t else ""
			except Exception:
				return ""

		def _clipboard_has_image(self) -> bool:
			pb = NSPasteboard.generalPasteboard()
			names = [str(t).lower() for t in (pb.types() or [])]
			hints = ("png", "tiff", "jpeg", "jpg", "gif", "image")
			return any(any(h in n for h in hints) for n in names)

		def _handle_paste(self, shift: bool = False) -> None:
			if shift:
				text = self._clipboard_text()
				if text:
					self.write(text.replace("\r\n", "\r").replace("\n", "\r"))
				return
			if self._clipboard_has_image():
				self.write(IMAGE_PASTE)
				return
			text = self._clipboard_text()
			if text:
				self.write(text.replace("\r\n", "\r").replace("\n", "\r"))

		def on_js_message(self, body) -> None:
			try:
				if hasattr(body, "keys"):
					msg = {str(k): body[k] for k in body.keys()}
				elif isinstance(body, dict):
					msg = body
				else:
					msg = json.loads(str(body))
			except Exception as e:  # noqa: BLE001
				_dbg("H-JS", "bad-msg", err=str(e))
				return
			typ = str(msg.get("type") or "")
			if typ == "ready":
				self._web_ready = True
				_dbg("H-WEB", "js-ready")
				self._js("window.gcatFit && window.gcatFit()")
				self._flush_pending()
			elif typ == "error":
				_dbg("H-WEB", "js-error", message=str(msg.get("message") or ""))
			elif typ == "focus-req":
				self.focus()
			elif typ == "data":
				self.write(str(msg.get("data") or ""))
			elif typ == "shift-enter":
				self.write(SHIFT_ENTER)
			elif typ == "paste":
				self._handle_paste(shift=bool(msg.get("shift")))
			elif typ == "copy":
				pb = NSPasteboard.generalPasteboard()
				pb.clearContents()
				pb.setString_forType_(str(msg.get("text") or ""), NSPasteboardTypeString)
			elif typ == "size":
				cols = int(msg.get("cols") or self._cols)
				rows = int(msg.get("rows") or self._rows)
				_dbg("H-PTY", "size-from-js", cols=cols, rows=rows)
				self._pty_resize(cols, rows)

		def handle(self, msg: dict) -> None:
			cmd = msg.get("cmd")
			_dbg(
				"H-CMD",
				str(cmd),
				raw={k: msg.get(k) for k in ("mode", "fx", "fy", "fw", "fh", "x", "y", "w", "h", "cwd") if k in msg},
			)
			try:
				if cmd in ("attach", "embed"):
					self.attach(int(msg.get("xid") or 0))
				elif cmd == "geom":
					rel = None
					if str(msg.get("mode") or "") == "rel":
						rel = (
							float(msg.get("fx") or 0),
							float(msg.get("fy") or 0),
							float(msg.get("fw") or 0),
							float(msg.get("fh") or 0),
						)
					self.show_at(
						int(msg.get("x") or 0),
						int(msg.get("y") or 0),
						int(msg.get("w") or 800),
						int(msg.get("h") or 240),
						rel=rel,
					)
				elif cmd == "hide":
					self.hide()
				elif cmd == "spawn":
					self.spawn(list(msg.get("argv") or []), str(msg.get("cwd") or ""))
				elif cmd == "write":
					data = str(msg.get("data") or "")
					_dbg("H-CMD", "write", n=len(data))
					self.write(data)
				elif cmd == "scroll_bottom":
					self.scroll_bottom()
				elif cmd == "focus":
					self.focus()
				elif cmd == "paste":
					self._handle_paste(False)
				elif cmd == "ping":
					self._emit({"event": "pong"})
				elif cmd == "quit":
					self.shutdown()
					AppHelper.stopEventLoop()
			except Exception as e:  # noqa: BLE001
				_dbg("H-CMD", "fail", cmd=str(cmd), err=str(e))

		def on_socket_readable(self) -> None:
			if self._conn is None:
				return
			try:
				chunk = self._conn.recv(4096)
			except BlockingIOError:
				return
			except OSError:
				AppHelper.stopEventLoop()
				return
			if not chunk:
				AppHelper.stopEventLoop()
				return
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

		def shutdown(self) -> None:
			self.hide()
			self._stop_pty()
			try:
				self.win.close()
			except Exception:
				pass

	class MsgHandler(NSObject):
		_host = None

		def initWithHost_(self, host):  # noqa: N802
			self = objc_super(MsgHandler, self).init()
			if self is None:
				return None
			self._host = host
			return self

		def userContentController_didReceiveScriptMessage_(self, _ucc, message):  # noqa: N802
			host = self._host
			if host is None:
				return
			try:
				host.on_js_message(message.body())
			except Exception as e:  # noqa: BLE001
				_dbg("H-JS", "handler-fail", err=str(e))

	srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
	srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
	srv.bind(("127.0.0.1", 0))
	srv.listen(1)
	srv.setblocking(False)
	port = srv.getsockname()[1]
	if port_file:
		with open(port_file, "w", encoding="utf-8") as f:
			f.write(str(port))
	else:
		sys.stdout.write(json.dumps({"event": "listen", "port": port}) + "\n")
		sys.stdout.flush()

	host = Host()
	accepted = {"done": False}

	def accept_poll() -> None:
		if accepted["done"]:
			return
		try:
			r, _, _ = select.select([srv], [], [], 0)
		except (OSError, ValueError):
			return
		if r:
			conn, _ = srv.accept()
			conn.setblocking(False)
			host.set_conn(conn)
			host._emit({"event": "ready"})
			accepted["done"] = True

			def sock_poll() -> None:
				host.on_socket_readable()
				AppHelper.callLater(0.02, sock_poll)

			AppHelper.callLater(0.02, sock_poll)
			return
		AppHelper.callLater(0.05, accept_poll)

	AppHelper.callLater(0.05, accept_poll)
	AppHelper.runEventLoop()
	host.shutdown()
	try:
		srv.close()
	except OSError:
		pass


if __name__ == "__main__":
	main()
