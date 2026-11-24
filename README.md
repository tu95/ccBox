# ccbox

**专为 macOS 打造的超轻量纯代理环境：原生 Seatbelt 网络隔离、完整代理覆盖、启动前环境自检、多环境并行与彩色窗口外框。**

[简体中文](./README.md) · [English](./README.en.md)

## 为什么做 ccbox？

在 macOS 上同时运行多个需要独立网络出口的工作环境时，传统虚拟机方案往往需要数十 GB 系统镜像、高内存占用和卡顿的远程桌面。

**ccbox** 采用**原生轻量化路线**：零虚拟机镜像、毫秒级启动。直接利用 macOS 内置 **Seatbelt（`/usr/bin/sandbox-exec`）** 在内核层禁止外网直连，让每个工作环境拥有独立的 **mihomo 全局代理出口、应用数据目录、自动对齐的时区与网页语言、独立的 `xterm.js` 终端**，以及带**专属颜色外部边框**的隔离版 Chrome 和自定义导入的 macOS 应用。

## 核心特性

- **原生 macOS Seatbelt 内核级隔离**：终端、Chrome 与导入应用全部通过 Seatbelt 启动。禁止非代理外网直连，回环仅放行当前代理和桥接端口；独立工作区、HOME、应用数据与临时目录，并隔离宿主机用户目录、应用目录、外接盘和共享临时目录。代理停止即自动断网并关闭关联应用。
- **NetworkExtension 系统级 GUI 直连兜底**：真实 `NEFilterDataProvider` 系统扩展按 audit token 对应的代码路径识别环境内 Chrome/导入应用副本，丢弃其非代理 TCP/UDP 外联，仅放行当前环境的 mihomo 与必要桥接端口；宿主机同名应用不受规则影响。顶栏点击「系统防护」启用，首次需在系统设置中允许扩展与内容过滤器。
- **启动前纯代理环境自检**：每次启动代理/沙箱或点击「测出口」时自动执行 7 项检测（出口 IP/ASN/ISP 与归属、IPv6 泄露防护、通用网络连通与延迟、Seatbelt 直连拦截验证、DNS/QUIC/WebRTC 泄露防护、时区与出口一致性、浏览器语言一致性），结果直观展示在顶栏徽章与侧边栏卡片中。
- **单一纯隔离环境**：首次启动复制项目副本并在独立 HOME 中运行，隔离宿主用户目录、宿主应用、外部卷与共享临时目录；交互式提示符与 `pwd` 呈现为 `/workspace` 和 `/home`，原项目不会被环境内操作修改。
- **多环境同时运行，随时无缝切换**：每个环境拥有独立的 mihomo 端口、独立的 `xterm.js` 终端缓冲区与后台输出流；左侧列表随时切换，后台环境的终端与 Chrome/导入应用持续运行不被杀掉。
- **隔离版 Chrome + 导入其他 macOS APP（浏览器链接重定向）**：
  - 复制本机 Chrome 到沙箱目录并保留 Chrome 原生沙箱，独立用户数据目录、匹配节点时区 `TZ`，保持中文界面并将网页语言设为 `en-US,en`，同时禁用 QUIC、本地 DNS 解析与非代理 WebRTC UDP。
  - 终端与导入的原生/Electron macOS 应用调用 `NSWorkspace` / `LSOpenCFURLRef` 打开 `http/https` 链接时，会通过内置 URL Hook 自动重定向到**当前所属隔离环境的 Chrome**（优先当前环境导入的 Chrome，否则回退到该环境的隔离 Chrome），不串宿主也不串其他环境。
  - 在应用首页点击 **「＋ 导入应用」** 为当前环境添加其他 macOS `.app`。导入时即把完整 `.app` Bundle 原子复制到当前环境目录，保存并启动的都是副本；原应用随后被卸载也不影响副本启动。启动时设置当前环境的代理、时区与独立数据目录，Electron/Chromium 应用另有代理启动参数。
- **彩色窗口外框**：新建环境自动分配专属高对比颜色，该环境启动的 Chrome 及导入的其他应用窗口外部都会套上一层透明、不拦截鼠标点击的 3.5pt 彩色圆角外框，一眼区分不同环境，且不篡改应用原生主题。
- **成熟稳定的 `xterm.js` 终端**：采用 `xterm.js` + `FitAddon` + `Unicode11Addon`，适配现代 TUI、中文宽字符与窗口实时缩放。
- **安全护栏**：未选代理节点时启动沙箱会弹出二次确认；退出应用（`Cmd+Q`）时自动清理所有并行运行的代理、终端、Chrome、导入应用与边框叠加层。

## 快速开始

### 环境要求

- **macOS 13+**（Apple Silicon / Intel）
- 本机安装 `mihomo`（例如 `brew install mihomo`）
- 本机安装你需要使用的命令行工具与 Google Chrome

### 构建与运行

```sh
./scripts/build-app.sh
open "dist/ccbox.app"
```

> 如需自定义应用图标，将 `1024×1024` 的 PNG 覆盖到 `scripts/icon.png`，再重新运行 `./scripts/build-app.sh` 即可自动生成 `AppIcon.icns`。
>
> 默认 ad-hoc 构建保留 Seatbelt，不包含 NetworkExtension。启用系统扩展需要开发者签名以及主程序、扩展各自匹配的 provisioning profile，然后设置 `CCBOX_ENABLE_NETWORK_FILTER=1`、`CCBOX_CODESIGN_IDENTITY`、`CCBOX_APP_PROVISIONING_PROFILE` 和 `CCBOX_NETWORK_FILTER_PROVISIONING_PROFILE` 再构建；缺少 profile 时脚本会明确失败，不会生成无法启动的应用。两个 App ID 分别为 `com.tu95.ccbox` 和 `com.tu95.ccbox.NetworkFilter`，profile 需包含 `content-filter-provider`，主程序还需 `com.apple.developer.system-extension.install`。

### 三步使用

1. **新建纯隔离环境**：点击左上角 `+ 新建` 并选定原项目目录（自动分配专属颜色）；首次启动会创建独立项目副本。
2. **导入并选择代理节点**：点击「导入订阅」或「导入 YAML」（支持 Clash/mihomo YAML 与 Base64 订阅），选好节点后可点「测出口」核对出口 IP、城市和时区。
3. **打开应用**：在首页点「终端」打开终端标签页，点 Chrome 或已导入的应用打开独立窗口。首次打开时启动对应的沙箱会话。点「＋ 导入应用」添加本机 `.app`。

终端默认提供私有 `TMPDIR`、`TEMP`、`TMP`、`XDG_RUNTIME_DIR` 与 `BUN_TMPDIR`。少数命令行工具使用自己的 `*_TMPDIR` 变量时，可在 `~/Library/Application Support/CCBox/temporary-directory-variables.json` 写入大写变量名数组，例如 `["CUSTOM_RUNTIME_TMPDIR"]`；CCBox 会把这些变量统一指向当次会话的私有临时目录，不开放宿主共享 `/tmp`。

## 架构与隔离边界

| 维度 | 说明 |
| --- | --- |
| 文件与网络隔离 | 所有环境内进程通过 `/usr/bin/sandbox-exec` 启动；仅允许访问环境副本和专属数据目录，禁止非代理出站，回环按端口精确放行 |
| 代理防泄露 | mihomo 仅监听 `127.0.0.1` 随机端口并禁用 IPv6；Chrome 与 Electron/Chromium 导入应用强制代理、禁本地 DNS、禁 QUIC 与非代理 WebRTC UDP |
| 系统网络防护 | `NEFilterDataProvider` 仅按副本路径约束 CCBox 启动的 GUI 应用，默认丢弃非代理 TCP/UDP 外联，规则随会话和代理端口动态更新；不读取或保存网络内容 |
| 应用与浏览器数据 | 每个环境使用独立 HOME、应用数据目录、临时目录、钥匙串与浏览器配置目录，不读写宿主对应数据 |
| 时区与语言 | 自动经所选代理查询出口 IANA 时区（支持手动指定），通过 `TZ` 注入终端与隔离应用，不修改 macOS 系统设置 |
| 已知边界 | 这是共享 macOS 内核的进程级隔离，不是独立内核虚拟机；非 Chromium/Electron 应用的代理遵循程度取决于自身网络栈，NetworkExtension 激活后提供系统级兜底；完整复制仅覆盖 `.app` Bundle，依赖外置系统组件的应用仍可能受限 |

## 许可协议

MIT License
