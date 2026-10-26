#!/usr/bin/env bash
# 将 Cursor Agent Term 安装到任意 Godot 工程。
# 用法：
#   ./install.sh /path/to/godot-project           # 符号链接（开发用）
#   ./install.sh --copy /path/to/godot-project    # 复制目录（分发到其他机器）
#   ./install.sh --check-only /path/to/godot-project  # 只做环境检测
#   ./install.sh                                 # 交互输入路径
#
# 硬性环境不满足时中止安装并报错（不写入工程）。
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)/addons"
PLUGIN_ROOT="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_CFG="res://addons/cursor_agent_term/plugin.cfg"
EXCLUDE="addons/cursor_agent_term/*"
MIN_GODOT_MAJOR=4
MIN_GODOT_MINOR=7

COPY_MODE=0
CHECK_ONLY=0
TARGET=""
for arg in "$@"; do
  case "$arg" in
    --copy|-c) COPY_MODE=1 ;;
    --check-only) CHECK_ONLY=1 ;;
    -h|--help)
      sed -n '2,10p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    -*)
      echo "未知参数: $arg（支持 --copy / --check-only）" >&2
      exit 1
      ;;
    *)
      if [[ -z "$TARGET" ]]; then TARGET="$arg"; else
        echo "多余参数: $arg" >&2
        exit 1
      fi
      ;;
  esac
done

if [[ -z "$TARGET" ]]; then
  read -r -p "目标 Godot 工程根目录: " TARGET
fi
if [[ ! -d "$TARGET" ]]; then
  echo "错误：目录不存在：$TARGET" >&2
  exit 1
fi
TARGET="$(cd "$TARGET" && pwd)"

ERRORS=()
WARNINGS=()

err() { ERRORS+=("$1"); }
warn() { WARNINGS+=("$1"); }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

version_ge() {
  # $1=major $2=minor  相对 MIN_GODOT_* 是否足够
  local maj="$1" min="$2"
  if (( maj > MIN_GODOT_MAJOR )); then return 0; fi
  if (( maj == MIN_GODOT_MAJOR && min >= MIN_GODOT_MINOR )); then return 0; fi
  return 1
}

resolve_agent() {
  if [[ -n "${CURSOR_AGENT_PATH:-}" ]]; then
    if [[ -f "$CURSOR_AGENT_PATH" && -x "$CURSOR_AGENT_PATH" ]]; then
      printf '%s\n' "$CURSOR_AGENT_PATH"
      return 0
    fi
    return 1
  fi
  local c
  for c in cursor-agent agent; do
    if have_cmd "$c"; then
      command -v "$c"
      return 0
    fi
  done
  local home="${HOME:-}"
  local rel
  for rel in .local/bin/cursor-agent .local/bin/agent .cursor/bin/cursor-agent .cursor/bin/agent; do
    if [[ -n "$home" && -f "$home/$rel" && -x "$home/$rel" ]]; then
      printf '%s\n' "$home/$rel"
      return 0
    fi
  done
  return 1
}

check_os() {
  local uname_s
  uname_s="$(uname -s 2>/dev/null || echo unknown)"
  case "$uname_s" in
    Linux) ;;
    Darwin)
      err "当前为 macOS：插件终端宿主尚未实现（仅 Linux）。请在 Linux 桌面环境安装。"
      ;;
    MINGW*|MSYS*|CYGWIN*|Windows_NT)
      err "当前为 Windows：插件终端宿主尚未实现（仅 Linux）。请在 Linux 桌面环境安装。"
      ;;
    *)
      err "不支持的系统：$uname_s（目前仅支持 Linux）"
      ;;
  esac
}

check_plugin_src() {
  if [[ ! -d "$SRC/cursor_agent_term" ]]; then
    err "插件源目录缺失：$SRC/cursor_agent_term"
  fi
  if [[ ! -f "$SRC/cursor_agent_term/plugin.cfg" ]]; then
    err "缺少 plugin.cfg：$SRC/cursor_agent_term/plugin.cfg"
  fi
  if [[ ! -f "$SRC/cursor_agent_term/vte_host.py" ]]; then
    err "缺少 vte_host.py（Linux 内嵌终端宿主）"
  fi
}

check_project() {
  if [[ ! -f "$TARGET/project.godot" ]]; then
    err "未找到 project.godot（不是 Godot 工程根目录）：$TARGET"
    return
  fi

  local feat_line ver="" maj="" min=""
  local project_ok=0 bin_ok=0

  feat_line="$(grep -E '^config/features=' "$TARGET/project.godot" 2>/dev/null || true)"
  if [[ -n "$feat_line" ]]; then
    ver="$(printf '%s' "$feat_line" | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)"
    if [[ -n "$ver" ]]; then
      maj="${ver%%.*}"
      min="${ver#*.}"
      if version_ge "$maj" "$min"; then
        project_ok=1
      else
        err "工程 Godot 特性版本为 $ver，本插件需要 ${MIN_GODOT_MAJOR}.${MIN_GODOT_MINOR}+（EditorDock）"
        return
      fi
    else
      warn "无法从 config/features 解析版本号：$feat_line"
    fi
  else
    warn "project.godot 无 config/features"
  fi

  if (( project_ok == 1 )); then
    return
  fi

  # 工程未声明够用的版本：用本机 Godot 二进制兜底
  local godot_bin="" gver=""
  for c in godot4 godot Godot; do
    if have_cmd "$c"; then godot_bin="$(command -v "$c")"; break; fi
  done
  if [[ -n "$godot_bin" ]]; then
    gver="$("$godot_bin" --version 2>/dev/null | head -1 || true)"
    maj="$(printf '%s' "$gver" | grep -oE '^[0-9]+' | head -1 || true)"
    min="$(printf '%s' "$gver" | grep -oE '^[0-9]+\.[0-9]+' | head -1 | cut -d. -f2 || true)"
    if [[ -n "$maj" && -n "$min" ]] && version_ge "$maj" "$min"; then
      bin_ok=1
    elif [[ -n "$gver" ]]; then
      err "本机 Godot 为「$gver」，需要 ${MIN_GODOT_MAJOR}.${MIN_GODOT_MINOR}+"
      return
    fi
  fi

  if (( bin_ok == 0 )); then
    err "无法确认 Godot ${MIN_GODOT_MAJOR}.${MIN_GODOT_MINOR}+：请在 project.godot 的 config/features 写入 \"${MIN_GODOT_MAJOR}.${MIN_GODOT_MINOR}\"，或安装 godot4 到 PATH"
  fi
}

check_agent() {
  local agent=""
  if agent="$(resolve_agent)"; then
    if [[ ! -x "$agent" ]]; then
      err "cursor-agent 不可执行：$agent"
      return
    fi
    # 冒烟：能跑通 --help / -h 之一即可（不要求已登录）
    if ! "$agent" --help >/dev/null 2>&1 && ! "$agent" -h >/dev/null 2>&1; then
      # 某些包装脚本无 --help；再试 status，失败仍算硬错误
      if ! "$agent" status >/dev/null 2>&1; then
        warn "已找到 agent（$agent），但 --help/status 均失败；请确认 CLI 完整可用并已登录"
      fi
    fi
  else
    if [[ -n "${CURSOR_AGENT_PATH:-}" ]]; then
      err "CURSOR_AGENT_PATH 无效或不可执行：${CURSOR_AGENT_PATH}（请安装 Cursor CLI 或修正路径）"
    else
      err "未找到 cursor-agent（PATH / ~/.local/bin / CURSOR_AGENT_PATH）。安装：https://cursor.com/docs/cli"
    fi
  fi
}

check_python() {
  if ! have_cmd python3; then
    err "未找到 python3（安装脚本与 VTE 宿主都需要）"
    return
  fi
  local pyv
  pyv="$(python3 -c 'import sys; print("%d.%d"%sys.version_info[:2])' 2>/dev/null || true)"
  if [[ -z "$pyv" ]]; then
    err "python3 无法运行"
  fi
}

check_term_runtime() {
  local vte_ok=0 screen_ok=0 term_ok=0

  if have_cmd python3; then
    if python3 - <<'PY' >/dev/null 2>&1
import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Vte", "2.91")
from gi.repository import Gtk, Vte  # noqa: F401
print("ok")
PY
    then
      vte_ok=1
    fi
  fi

  if have_cmd screen; then
    screen_ok=1
  fi

  local t
  for t in gnome-terminal x-terminal-emulator xfce4-terminal konsole kitty alacritty wezterm xterm; do
    if have_cmd "$t"; then term_ok=1; break; fi
  done

  if (( vte_ok == 1 )); then
    :
  elif (( screen_ok == 1 && term_ok == 1 )); then
    warn "未检测到 VTE（python3-gi + Vte 2.91）：将只能使用 screen 外挂终端回退"
  elif (( screen_ok == 1 && term_ok == 0 )); then
    err "有 screen 但未找到终端模拟器（gnome-terminal / kitty / xterm 等）；请安装 VTE 或任一终端"
  else
    err "运行环境不足：需要「python3-gi + gir1.2-vte-2.91」内嵌终端，或「screen + 终端模拟器」回退"
  fi

  if (( vte_ok == 1 )) && ! have_cmd xclip; then
    warn "未找到 xclip：剪贴板贴图可能不稳定（建议：sudo apt install xclip）"
  fi

  # 显示环境：无 DISPLAY/WAYLAND 时编辑器内嵌通常不可用
  if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
    err "未检测到图形会话（DISPLAY/WAYLAND_DISPLAY 为空）：编辑器插件需要桌面环境"
  fi
}

run_checks() {
  echo "=== 环境检测（Cursor Agent Term）==="
  echo "插件源: $PLUGIN_ROOT"
  echo "目标工程: $TARGET"
  echo

  check_os
  check_plugin_src
  check_project
  check_python
  check_agent
  check_term_runtime

  local agent_show="(未找到)"
  if agent_show="$(resolve_agent 2>/dev/null)"; then :; else agent_show="(未找到)"; fi

  echo "摘要:"
  echo "  系统:      $(uname -s) $(uname -m 2>/dev/null || true)"
  echo "  python3:   $(command -v python3 2>/dev/null || echo 无)"
  echo "  agent:     $agent_show"
  if have_cmd python3 && python3 -c 'import gi; gi.require_version("Gtk","3.0"); gi.require_version("Vte","2.91"); from gi.repository import Gtk,Vte' >/dev/null 2>&1; then
    echo "  内嵌 VTE:  可用"
  else
    echo "  内嵌 VTE:  不可用"
  fi
  echo "  screen:    $(command -v screen 2>/dev/null || echo 无)"
  echo "  xclip:     $(command -v xclip 2>/dev/null || echo 无)"
  echo

  if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    echo "警告:"
    local w
    for w in "${WARNINGS[@]}"; do
      echo "  ! $w"
    done
    echo
  fi

  if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo "环境检测失败，已中止安装（未修改工程）：" >&2
    local e
    for e in "${ERRORS[@]}"; do
      echo "  x $e" >&2
    done
    echo >&2
    echo "修复后重新执行：" >&2
    echo "  $0 [--copy] [--check-only] \"$TARGET\"" >&2
    return 1
  fi

  echo "环境检测通过。"
  return 0
}

if ! run_checks; then
  exit 1
fi

if (( CHECK_ONLY == 1 )); then
  echo "（--check-only：不写入工程）"
  exit 0
fi

mkdir -p "$TARGET/addons"

install_addon() {
  local name="$1"
  local dest="$TARGET/addons/$name"
  local src="$SRC/$name"
  if [[ ! -d "$src" ]]; then
    echo "错误：缺少插件源 $src" >&2
    exit 1
  fi
  if [[ -e "$dest" || -L "$dest" ]]; then
    rm -rf "$dest"
  fi
  if [[ "$COPY_MODE" -eq 1 ]]; then
    cp -a "$src" "$dest"
    rm -rf "$dest/__pycache__" 2>/dev/null || true
    find "$dest" -name '*.pyc' -delete 2>/dev/null || true
    echo "已复制 $name"
  else
    ln -sfn "$src" "$dest"
    echo "已链接 $name -> $src"
  fi
}

install_addon cursor_agent_term

if [[ -L "$TARGET/addons/gdterm" ]] || [[ -d "$TARGET/addons/gdterm" ]]; then
  rm -rf "$TARGET/addons/gdterm"
  echo "已移除旧的 addons/gdterm"
fi

if grep -q '\[editor_plugins\]' "$TARGET/project.godot"; then
  if grep -q "cursor_agent_term/plugin.cfg" "$TARGET/project.godot"; then
    echo "插件已在 project.godot 中启用。"
  else
    if grep -q '^enabled=PackedStringArray(' "$TARGET/project.godot"; then
      python3 - <<PY
from pathlib import Path
p = Path("$TARGET/project.godot")
text = p.read_text()
needle = "enabled=PackedStringArray("
i = text.find(needle)
if i < 0:
    raise SystemExit("no enabled line")
j = text.find(")", i)
inner = text[i+len(needle):j].strip()
item = '"$PLUGIN_CFG"'
if item not in inner:
    new_inner = item if not inner else inner.rstrip() + ", " + item
    text = text[:i+len(needle)] + new_inner + text[j:]
    p.write_text(text)
    print("已追加到 enabled=PackedStringArray")
PY
    else
      python3 - <<PY
from pathlib import Path
p = Path("$TARGET/project.godot")
lines = p.read_text().splitlines(True)
out = []
done = False
for line in lines:
    out.append(line)
    if not done and line.strip() == "[editor_plugins]":
        out.append('enabled=PackedStringArray("$PLUGIN_CFG")\n')
        done = True
p.write_text("".join(out))
print("已写入 enabled=PackedStringArray")
PY
    fi
  fi
else
  printf '\n[editor_plugins]\n\nenabled=PackedStringArray("%s")\n' "$PLUGIN_CFG" >> "$TARGET/project.godot"
  echo "已新增 [editor_plugins] 段。"
fi

python3 - "$TARGET" "$EXCLUDE" <<'PY'
from pathlib import Path
import re
import sys

target = Path(sys.argv[1])
exclude_item = sys.argv[2]
path = target / "export_presets.cfg"

OPTIONS_STUB = """
custom_template/debug=""
custom_template/release=""
debug/export_console_wrapper=1
binary_format/embed_pck=false
texture_format/s3tc_bptc=true
texture_format/etc2_astc=false
binary_format/architecture="x86_64"
ssh_remote_deploy/enabled=false
"""

def merge_exclude(existing: str) -> str:
    parts = [p.strip() for p in existing.split(",") if p.strip()]
    parts = [p for p in parts if "gdterm" not in p]
    if exclude_item not in parts:
        parts.append(exclude_item)
    return ",".join(parts)

def ensure_options_sections(text: str) -> str:
    nums = re.findall(r"^\[preset\.(\d+)\]\s*$", text, flags=re.M)
    for n in nums:
        header = f"[preset.{n}.options]"
        if header not in text:
            text = text.rstrip() + f"\n\n{header}\n{OPTIONS_STUB}"
    return text

if not path.exists():
    print(f"无 {path.name}，跳过写入（导出忽略由 EditorExportPlugin 负责）")
    raise SystemExit(0)

text = path.read_text()
if "[preset.0.options]" not in text and text.count("[preset.") == 1:
    path.unlink()
    print(f"已删除残缺 {path.name}（改由 EditorExportPlugin 排除插件）")
    raise SystemExit(0)

if "exclude_filter=" not in text:
    def inject(m):
        return m.group(0) + f'exclude_filter="{merge_exclude("")}"\n'
    text, n = re.subn(r"(^\[preset\.\d+\]\n)", inject, text, flags=re.M)
    print(f"已向 {n} 个 preset 注入 exclude_filter")
else:
    def repl(m):
        return f'exclude_filter="{merge_exclude(m.group(1))}"'
    text, n = re.subn(r'exclude_filter="([^"]*)"', repl, text)
    print(f"已合并 {n} 处 exclude_filter")

text = ensure_options_sections(text)
path.write_text(text if text.endswith("\n") else text + "\n")
PY

echo "完成：$TARGET"
if [[ "$COPY_MODE" -eq 1 ]]; then
  echo "  模式: 复制 addons/cursor_agent_term"
else
  echo "  模式: 符号链接 -> $SRC/cursor_agent_term"
fi
echo "  导出忽略: $EXCLUDE"
echo "请重新打开该工程，应出现 Cursor Agent dock。"
