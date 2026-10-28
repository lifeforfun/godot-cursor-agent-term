# Cursor Agent Term（Godot 编辑器插件）

在 Godot 编辑器里用终端跑 [cursor-agent](https://cursor.com)：可停靠底栏 / 左右 / 浮动，支持会话恢复、注入脚本路径、中文 IME、文本/图片粘贴。

**不绑定任何开发者本机路径**；换机器只要装好依赖即可用。

## 依赖

| 级别 | 组件 | 说明 |
|------|------|------|
| **必需** | Godot **4.7+**（`EditorDock`） | 编辑器插件 |
| **必需** | [`cursor-agent`](https://cursor.com/docs/cli) | 已登录；或设 `CURSOR_AGENT_PATH` |
| **必需** | `python3` | 仅安装脚本改 `project.godot` 用 |
| Linux 推荐 | `gi`（Gtk3 / Vte 2.91） | 编辑器内嵌 VTE |
| Linux 可选 | `xclip` | 剪贴板图片规范化（X11） |
| Linux 回退 | `screen` + 终端模拟器 | 无 VTE 时外挂 |
| macOS 推荐 | PyObjC venv（`install.sh` 自动装） | 内嵌叠窗（xterm.js + 真 PTY） |
| macOS 回退 | `tmux`/`screen` + Terminal.app | 内嵌不可用时外挂 |

Debian/Ubuntu 内嵌终端示例：

```bash
sudo apt install python3-gi gir1.2-vte-2.91 xclip
```

macOS：`./install.sh` 会在 `~/.cache/cursor-agent-term/macos-venv` 安装 PyObjC；失败时可：

```bash
python3.11 -m venv ~/.cache/cursor-agent-term/macos-venv
~/.cache/cursor-agent-term/macos-venv/bin/pip install pyobjc-framework-Cocoa pyobjc-framework-WebKit
# 可选回退：brew install tmux
```

## 安装到其他工程 / 其他机器

安装前会做**环境检测**，硬性条件不满足则报错退出、不改工程：

- **Linux**：桌面（`DISPLAY` / `WAYLAND_DISPLAY`）+ **VTE** 或 **screen+终端**
- **macOS**：内嵌 PyObjC 叠窗，或 **tmux/screen + Terminal.app** 回退
- Godot **4.7+**（读工程 `config/features` 或本机 `godot`）
- 可用的 `cursor-agent`（或 `CURSOR_AGENT_PATH`）
- `python3`

```bash
./install.sh --check-only /path/to/your-godot-project   # 只检测
./install.sh /path/to/your-godot-project                # 符号链接
./install.sh --copy /path/to/your-godot-project         # 复制分发
```

或手动：

```bash
cp -a addons/cursor_agent_term /path/to/your-game/addons/
```

然后在「项目设置 → 插件」启用 **Cursor Agent Term**，重新打开工程。

可选：`export CURSOR_AGENT_PATH=/绝对路径/cursor-agent`

## 使用

1. 打开 **Cursor Agent** dock，会自动预热会话并铺终端。
2. 可挪到左侧 / 右侧 / 底栏 / 浮动；终端跟随槽位尺寸。
3. 脚本编辑器打开 `.gd`，可选中行 → **注入路径**。
4. 截图后在终端焦点处 `Ctrl+V` / macOS 亦支持 `Cmd+V` 贴图。
5. **开启会话** 在已有会话时会确认是否开新对话。仅外挂回退时需点 **打开终端**。

会话按**工程路径**隔离，只 resume 本插件绑定的 id，不会误接 Cursor IDE 其它聊天。

## 目录

```text
addons/cursor_agent_term/
├── plugin.cfg / plugin.gd / agent_dock.gd / panel.gd
├── plat.gd                 # 平台门面（唯一 OS 分发入口）
├── plat_base.gd            # 能力接口
├── plat_linux.gd           # Linux：VTE + screen
├── plat_macos.gd           # macOS：内嵌叠窗 + tmux 回退
├── plat_windows.gd         # Windows：占位 + TODO
├── ext_host_stub.gd        # 未实现平台的外挂占位
├── vte_host.py / vte_bridge.gd   # Linux 内嵌（勿在其它 OS 引用）
├── screen_host.gd          # Linux screen 回退（勿在 macOS 引用）
├── macos_embed_host.py / macos_bridge.gd / macos_xterm/  # macOS 内嵌
├── macos_host.gd           # macOS tmux/screen 回退（勿在 Linux 引用）
├── launcher.gd / session_store.gd / editor_ctx.gd
└── export_plugin.gd
```

## 跨平台隔离

- **业务**（`panel` / `launcher` / `session_store`）只通过 `CursorAgentPlat.get_plat()` 取能力，不写 `OS.get_name()` 分支。
- **系统独有逻辑**只放在对应 `plat_*.gd` 及其宿主（Linux=`vte_*` / `screen_host`；macOS=`macos_embed_*` / `macos_host`；Windows 将来 `win_host`）。
- 现状：**Linux** 内嵌 VTE；**macOS** 内嵌 xterm 叠窗（PyObjC），失败回退 tmux；**Windows** 尚未实现。

## 可选环境变量

```bash
export CURSOR_AGENT_PATH=...     # agent 可执行文件
export GCAT_TERM_FONT_SIZE=9     # 字号（默认 10）
export GCAT_TERM_FONT="JetBrains Mono"  # 字体族（可选）
export GCAT_DEBUG=1              # 调试日志（默认关）→ Linux: gcat_vte_debug.log / macOS: gcat_macos_debug.log
export GCAT_VTE_DEBUG=1          # 仅宿主进程日志（VTE / macOS embed）
```

## 故障排查

| 现象 | 处理 |
|------|------|
| 提示未找到 cursor-agent | 安装 CLI，或设 `CURSOR_AGENT_PATH` |
| Linux：无内嵌终端 / 回退 screen | 安装 `python3-gi gir1.2-vte-2.91` |
| macOS：无内嵌终端 | 重跑 `./install.sh` 装 PyObjC venv；或 `brew install tmux` 走外挂 |
| Linux：贴图无芯片 | 安装 `xclip`；面板需焦点 |
| resume 进了 IDE 聊天 | 点「开启会话」开新对话（只认插件绑定） |
