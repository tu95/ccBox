# ccbox

**Ultra-lightweight native macOS sandbox workbench for AI development: kernel-enforced macOS Seatbelt network isolation, clean proxy environments, pre-flight environment checks, multi-environment concurrency, and DACS-style external colored window frames.**

[简体中文](./README.md) · [English](./README.en.md)

## Why ccbox?

When running **Claude Code**, **Codex**, **Antigravity (Agy)**, or multiple AI accounts on macOS, full virtual machine solutions require tens of gigabytes of guest OS images, heavy memory overhead, and sluggish remote desktop sessions.

**ccbox** takes a **native, zero-VM approach**: built directly on macOS's built-in **Seatbelt (`/usr/bin/sandbox-exec`)**, it starts in milliseconds with minimal overhead. Each environment runs with its own dedicated **mihomo global proxy exit**, isolated **account credentials**, auto-synced **timezone & web language**, an independent **`xterm.js` terminal**, and **color-framed isolated Chrome & imported macOS apps**.

## Key Features

- **Native macOS Seatbelt Network Isolation**: Zero VM images and zero third-party Node sandbox wrappers. Blocks all non-loopback egress at the macOS kernel level, forcing every terminal process through the environment's selected mihomo global proxy (with IPv6 disabled by default). Stopping the proxy immediately cuts network access and terminates associated apps.
- **NetworkExtension GUI Egress Enforcement**: A real `NEFilterDataProvider` system extension identifies Chrome and imported-app copies by the code path associated with their audit tokens. It drops non-proxy TCP/UDP egress and permits only the active environment's mihomo and required bridge ports, without constraining identically named host apps. Click **System Protection** in the top bar and approve the extension and content filter in System Settings on first use.
- **Pre-Flight Clean Proxy Environment Checks**: Automatically runs a 7-point check every time a proxy/sandbox starts or when clicking **Check Exit** (exit IP/ASN/ISP & Claude-supported region, IPv6 leak protection, `claude.ai`/`api.anthropic.com` latency, Seatbelt direct-egress block verification, DNS/QUIC/WebRTC leak protection, timezone alignment, and browser language consistency), displayed directly in the top bar badge and sidebar status card.
- **Dual Isolation Modes**:
  - **Host Passthrough (`本机直通`)**: Strictly isolates network egress, Claude credentials, and browser profiles while reading/writing your real project directory directly and reusing your native shell, Homebrew, nvm, Python, and Git toolchain.
  - **Pure Isolated (`纯隔离`)**: Copies the project into an isolated workspace on first launch, uses a dedicated `HOME`, blocks host user directories and external volumes, and displays `/workspace` and `/home` in the interactive prompt and `pwd`.
- **Concurrent Multi-Environment Execution**: Run multiple environments simultaneously—each with its own mihomo loopback ports, independent `xterm.js` terminal buffer, and isolated GUI apps. Switch freely in the sidebar without interrupting background sessions or closing Chrome.
- **Isolated Chrome + Import Any macOS App (Browser URL Redirection)**:
  - Copies local `Google Chrome.app` into app storage while keeping Chromium's native sandbox intact, paired with per-environment profile data, node-matched `TZ`, Chinese UI with `en-US,en` web language, and leak-protection flags for DNS, QUIC, and WebRTC UDP.
  - Both terminal tools and imported native/Electron macOS apps (e.g., Gemini) that open `http`/`https` links via `NSWorkspace` or `LSOpenCFURLRef` are automatically redirected by the bundled URL hook into **that environment's own isolated Chrome** (preferring an imported Chrome in that environment if present), never the host browser or another environment's Chrome.
  - **Import Other Apps**: Use the **+ Import App** tile to add a macOS `.app` bundle to the selected environment. Import immediately makes an atomic, full-bundle copy inside that environment, and only the copy is used for icons and launching, so uninstalling the original app does not prevent the copy from starting. The copy receives the environment's proxy settings, timezone, and separate data directory. Electron/Chromium apps also receive proxy flags.
- **DACS-Style External Colored Window Borders**: Each environment is automatically assigned a distinct accent color. Every Chrome or imported app window launched from that environment is framed externally by a transparent, click-through 3.5pt rounded colored border without modifying native app themes.
- **Battle-Tested `xterm.js` Terminal**: Powered by `WKWebView` + `xterm.js` (`FitAddon` + `Unicode11Addon`), delivering VS Code–grade compatibility for modern TUIs, CJK wide characters, and pixel-accurate PTY resizing.
- **Safety Guardrails**: Prompts for explicit confirmation before launching a sandbox without a proxy node, and cleans up all background proxies, shells, browsers, imported apps, and overlays on `Cmd+Q`.

## Quick Start

### Prerequisites

- **macOS 13+** (Apple Silicon or Intel)
- `mihomo` installed locally (e.g., `brew install mihomo`)
- Your preferred CLI tools (`claude`, `codex`, `agy`) and Google Chrome

### Build & Run

```sh
./scripts/build-app.sh
open "dist/ccbox.app"
```

> To customize the app icon, replace `scripts/icon.png` with a `1024×1024` PNG and re-run `./scripts/build-app.sh` to regenerate `AppIcon.icns`.
>
> The default ad-hoc build retains Seatbelt and omits NetworkExtension. Building the system extension requires a developer identity plus matching provisioning profiles for both the app and extension. Set `CCBOX_ENABLE_NETWORK_FILTER=1`, `CCBOX_CODESIGN_IDENTITY`, `CCBOX_APP_PROVISIONING_PROFILE`, and `CCBOX_NETWORK_FILTER_PROVISIONING_PROFILE`. The script fails explicitly when profiles are missing instead of producing an app that macOS cannot launch. The App IDs are `com.tu95.ccbox` and `com.tu95.ccbox.NetworkFilter`; both profiles need `content-filter-provider`, and the app also needs `com.apple.developer.system-extension.install`.

### Usage

1. **Create an Environment**: Click `+ 新建`, pick **Host Passthrough** or **Pure Isolated**, and choose your project folder (an accent color is automatically assigned).
2. **Import & Select a Proxy Node**: Click **Import Subscription** or **Import YAML** (supports Clash/mihomo YAML and Base64 subscriptions), select a node, and optionally click **Check Exit** to verify exit IP, city, and timezone.
3. **Open Apps**: Choose **Terminal** to open a terminal tab, or choose Chrome or an imported app to open it in a separate window. The first launch starts the sandbox session. Use **+ Import App** to add another local `.app` bundle.

## Architecture & Security Boundaries

| Area | Details |
| --- | --- |
| Terminal Network Isolation | Enforces kernel-level non-loopback egress blocking via native `/usr/bin/sandbox-exec`; all internet traffic routes through mihomo in global mode |
| Proxy Leak Protection | mihomo listens exclusively on ephemeral `127.0.0.1` ports with IPv6 disabled; Chrome and Electron/Chromium imported apps enforce proxy, DNS, QUIC, and WebRTC UDP restrictions |
| System Network Protection | `NEFilterDataProvider` constrains only CCBox-managed GUI copies by path, drops non-proxy TCP/UDP egress by default, and updates rules with session and proxy-port changes; it does not inspect or store network content |
| Account & Credential Isolation | Dedicated `CLAUDE_CONFIG_DIR` and browser profile per environment; Host Passthrough mode blocks access to existing host Claude login files |
| Timezone & Locale | Resolves exit IANA timezone through the selected proxy (with manual override) and passes `TZ` to terminal, Chrome, and imported apps without touching macOS system settings |
| Scope Note | Non-Chromium/Electron native macOS GUI apps imported via **Import App** receive isolated `HOME`, `TZ`, and standard proxy environment variables; proxy adherence depends on each app's networking stack. Full copying covers the `.app` bundle; apps that require external frameworks, system daemons, login items, or licensing services still depend on those system components |

## License

MIT License
