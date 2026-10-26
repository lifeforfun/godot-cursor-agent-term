# Cursor Agent Term（Godot 编辑器插件）

在 Godot 编辑器里用终端跑 [cursor-agent](https://cursor.com)：可停靠底栏 / 左右 / 浮动，支持会话恢复、注入脚本路径、中文 IME、文本/图片粘贴。

**不绑定任何开发者本机路径**；换机器只要装好依赖即可用。

## 依赖

| 级别 | 组件 | 说明 |
|------|------|------|
| **必需** | Godot **4.7+**（`EditorDock`） | 编辑器插件 |
| **必需** | [`cursor-agent`](https://cursor.com/docs/cli) | 已登录；或设 `CURSOR_AGENT_PATH` |
| 推荐 | Python3 + `gi`（Gtk3 / Vte 2.91） | 编辑器内嵌 VTE 终端 |
| 可选 | `xclip` | 剪贴板图片规范化（Linux/X11） |
| 回退 | `screen` + 任意终端模拟器 | 无 VTE 时外挂终端 |

Debian/Ubuntu 内嵌终端示例：

```bash
sudo apt install python3-gi gir1.2-vte-2.91 xclip
```

```bash
command -v cursor-agent || ls "$HOME/.local/bin/cursor-agent"
cursor-agent status
```

## 安装到其他工程 / 其他机器

安装前会做**环境检测**，硬性条件不满足则报错退出、不改工程：

- Linux 桌面（`DISPLAY` / `WAYLAND_DISPLAY`）
- Godot **4.7+**（读工程 `config/features` 或本机 `godot`）
- 可用的 `cursor-agent`（或 `CURSOR_AGENT_PATH`）
- `python3`，以及 **VTE** 或 **screen+终端** 之一

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
4. 截图后点终端，`Ctrl+V` 贴图（需 `xclip` 时更稳）。
5. **开启会话** 在已有会话时会确认是否开新对话。

会话按**工程路径**隔离，只 resume 本插件绑定的 id，不会误接 Cursor IDE 其它聊天。

## 目录

```text
addons/cursor_agent_term/
├── plugin.cfg / plugin.gd / agent_dock.gd / panel.gd
├── plat.gd                 # 平台门面（唯一 OS 分发入口）
├── plat_base.gd            # 能力接口
├── plat_linux.gd           # Linux：VTE + screen（已实现）
├── plat_macos.gd           # macOS：占位 + TODO
├── plat_windows.gd         # Windows：占位 + TODO
├── ext_host_stub.gd        # 非 Linux 外挂终端占位
├── vte_host.py / vte_bridge.gd   # Linux 内嵌（勿在其它 OS 引用）
├── screen_host.gd          # Linux screen 回退
├── launcher.gd / session_store.gd / editor_ctx.gd
└── export_plugin.gd
```

## 跨平台隔离

- **业务**（`panel` / `launcher` / `session_store`）只通过 `CursorAgentPlat.get_plat()` 取能力，不写 `OS.get_name()` 分支。
- **系统独有逻辑**只放在对应 `plat_*.gd` 及其宿主（Linux=`vte_*` / `screen_host`；将来 mac/win 各自新文件）。
- 现状：**仅 Linux 内嵌 VTE 可用**；macOS / Windows 会提示尚未实现，避免误用 Linux 专用代码。

## 可选环境变量

```bash
export CURSOR_AGENT_PATH=...     # agent 可执行文件
export GCAT_TERM_FONT_SIZE=9     # 字号（默认 10）
export GCAT_TERM_FONT="JetBrains Mono"  # 字体族（可选）
export GCAT_DEBUG=1              # 调试日志 → 系统临时目录/gcat_vte_debug.log
export GCAT_VTE_DEBUG=1          # 仅 VTE 宿主日志
```

## 故障排查

| 现象 | 处理 |
|------|------|
| 提示未找到 cursor-agent | 安装 CLI，或设 `CURSOR_AGENT_PATH` |
| 无内嵌终端 / 回退 screen | 安装 `python3-gi gir1.2-vte-2.91` |
| 贴图无芯片 | 安装 `xclip`；面板需焦点 |
| resume 进了 IDE 聊天 | 点「开启会话」开新对话（只认插件绑定） |
