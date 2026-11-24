# ccbox

**An ultra-lightweight clean proxy environment for macOS: native Seatbelt network isolation, comprehensive proxy coverage, pre-flight checks, concurrent environments, and colored window frames.**

[简体中文](./README.md) · [English](./README.en.md)

## Why ccbox?

When multiple macOS workspaces need independent network exits, full virtual machines usually require tens of gigabytes of guest OS images, heavy memory overhead, and sluggish remote desktop sessions.

**ccbox** takes a **native, zero-VM approach**: built directly on macOS's built-in **Seatbelt (`/usr/bin/sandbox-exec`)**, it starts in milliseconds with minimal overhead. Each environment runs with its own dedicated **mihomo global proxy exit**, isolated **application data**, auto-synced **timezone & web language**, an independent **`xterm.js` terminal**, and **color-framed isolated Chrome & imported macOS apps**.

## Key Features

- **Native macOS Seatbelt Isolation**: Terminals, Chrome, and imported apps all launch through Seatbelt. Non-proxy egress is blocked, and loopback access is limited to the active proxy and bridge ports. Each environment has an isolated workspace, `HOME`, application data, and temporary directory; host user folders, host applications, external volumes, and shared temporary directories are inaccessible. Stopping the proxy immediately cuts network access and terminates associated apps.
- **NetworkExtension GUI Egress Enforcement**: A real `NEFilterDataProvider` system extension identifies Chrome and imported-app copies by the code path associated with their audit tokens. It drops non-proxy TCP/UDP egress and permits only the active environment's mihomo and required bridge ports, without constraining identically named host apps. Click **System Protection** in the top bar and approve the extension and content filter in System Settings on first use.
- **Pre-Flight Clean Proxy Environment Checks**: Automatically runs a 7-point check every time a proxy/sandbox starts or when clicking **Check Exit**: exit IP/ASN/ISP and location, IPv6 leak protection, generic network connectivity and latency, Seatbelt direct-egress block verification, DNS/QUIC/WebRTC leak protection, timezone alignment, and browser language consistency. Results appear in the top bar badge and sidebar status card.
- **Pure Isolation Only**: Copies the project into an isolated workspace on first launch and uses a dedicated `HOME`. Host user directories, host applications, external volumes, and shared temporary directories are blocked. The interactive prompt and `pwd` display `/workspace` and `/home`; changes inside the environment never modify the original project.
- **Concurrent Multi-Environment Execution**: Run multiple environments simultaneously, each with its own mihomo loopback ports, independent `xterm.js` terminal buffer, and isolated GUI apps. Switch freely in the sidebar without interrupting background sessions or closing Chrome.
- **Isolated Chrome + Import Any macOS App (Browser URL Redirection)**:
  - Copies local `Google Chrome.app` into app storage and disables Chromium's nested sandbox, which conflicts with the outer Seatbelt profile that enforces file and network isolation. Each environment has dedicated profile data, node-matched `TZ`, Chinese UI with `en-US,en` web language, and leak-protection flags for DNS, QUIC, and WebRTC UDP.
  - When terminal tools or imported native/Electron macOS apps open `http`/`https` links via `NSWorkspace` or `LSOpenCFURLRef`, the bundled URL hook redirects them into **that environment's own isolated Chrome**, preferring an imported Chrome in that environment if present.
  - **Import Other Apps**: Use the **+ Import App** tile to add a macOS `.app` bundle to the selected environment. Import immediately makes an atomic, full-bundle copy inside that environment, and only the copy is used for icons and launching, so uninstalling the original app does not prevent the copy from starting. The copy receives the environment's proxy settings, timezone, and separate data directory. Electron/Chromium apps also receive proxy flags. Nested `.app` bundles and helpers launched through LaunchServices re-enter the same Seatbelt profile and URL hook, with Darwin user temporary and cache directories redirected into the environment.
- **Colored Window Frames**: Each environment is automatically assigned a distinct accent color. Every Chrome or imported app window launched from that environment is framed externally by a transparent, click-through 3.5pt rounded colored border without modifying native app themes.
- **Stable `xterm.js` Terminal**: Powered by `WKWebView` + `xterm.js` (`FitAddon` + `Unicode11Addon`), supporting modern TUIs, CJK wide characters, and pixel-accurate PTY resizing.
- **Safety Guardrails**: Prompts for explicit confirmation before launching a sandbox without a proxy node, and cleans up all background proxies, shells, browsers, imported apps, and overlays on `Cmd+Q`.

## Quick Start

### Prerequisites

- **macOS 13+** (Apple Silicon or Intel)
- `mihomo` installed locally (e.g., `brew install mihomo`)
- Your preferred command-line tools and Google Chrome

### Build & Run

```sh
./scripts/build-app.sh
open "dist/ccbox.app"
```

> To customize the app icon, replace `scripts/icon.png` with a `1024×1024` PNG and re-run `./scripts/build-app.sh` to regenerate `AppIcon.icns`.
>
> The default ad-hoc build retains Seatbelt and omits NetworkExtension. Building the system extension requires a developer identity plus matching provisioning profiles for both the app and extension. Set `CCBOX_ENABLE_NETWORK_FILTER=1`, `CCBOX_CODESIGN_IDENTITY`, `CCBOX_APP_PROVISIONING_PROFILE`, and `CCBOX_NETWORK_FILTER_PROVISIONING_PROFILE`. The script fails explicitly when profiles are missing instead of producing an app that macOS cannot launch. The App IDs are `com.tu95.ccbox` and `com.tu95.ccbox.NetworkFilter`; both profiles need `content-filter-provider`, and the app also needs `com.apple.developer.system-extension.install`.

### Usage

1. **Create an Isolated Environment**: Click `+ 新建` and choose the original project folder. An accent color is assigned automatically, and the first launch creates an independent project copy.
2. **Import & Select a Proxy Node**: Click **Import Subscription** or **Import YAML** (supports Clash/mihomo YAML and Base64 subscriptions), select a node, and optionally click **Check Exit** to verify exit IP, city, and timezone.
3. **Open Apps**: Choose **Terminal** to open a terminal tab, or choose Chrome or an imported app to open it in a separate window. The first launch starts the sandbox session. Use **+ Import App** to add another local `.app` bundle.

Terminals receive private `TMPDIR`, `TEMP`, `TMP`, `XDG_RUNTIME_DIR`, and `BUN_TMPDIR` values. For command-line tools with their own `*_TMPDIR` variable, add uppercase variable names as a JSON array in `~/Library/Application Support/CCBox/temporary-directory-variables.json`, for example `["CUSTOM_RUNTIME_TMPDIR"]`. CCBox points every listed variable at the current session's private temporary directory without opening the host's shared `/tmp`.

## Architecture & Security Boundaries

| Area | Details |
| --- | --- |
| File & Network Isolation | Every managed process launches through `/usr/bin/sandbox-exec`; only environment copies and dedicated data directories are accessible, non-proxy egress is blocked, and loopback ports are individually allowed |
| Proxy Leak Protection | mihomo listens exclusively on ephemeral `127.0.0.1` ports with IPv6 disabled; Chrome and Electron/Chromium imported apps enforce proxy, DNS, QUIC, and WebRTC UDP restrictions |
| System Network Protection | `NEFilterDataProvider` constrains only CCBox-managed GUI copies by path, drops non-proxy TCP/UDP egress by default, and updates rules with session and proxy-port changes; it does not inspect or store network content |
| App & Browser Data | Dedicated `HOME`, application data, temporary directory, keychain, and browser profile per environment, with no access to the corresponding host data |
| Timezone & Locale | Resolves exit IANA timezone through the selected proxy (with manual override) and passes `TZ` to terminal, Chrome, and imported apps without touching macOS system settings |
| Scope Note | This is process-level isolation on a shared macOS kernel, not a virtual machine with an independent kernel. Non-Chromium/Electron apps depend on their own networking stack until NetworkExtension is activated for system-level enforcement. Full copying covers the `.app` bundle; apps requiring external system components may remain limited |

## License

MIT License
