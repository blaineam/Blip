# Blip for Windows and Linux: port ledger

Rust workspace: native metrics (Win32 on Windows; /proc, /sys and D-Bus on Linux), egui UI,
tray icon, no admin/root anywhere.

## Layout
- `crates/core`: models, formatting, history, recommendations, grades, MTR stats, BenchKit
  (frozen Blip 2.0 references), OpenSpeedTest tester (+ `ExternalRun` for the public widget),
  uncached disk test, GeoIP, settings (Mac keys), metric catalog (Mac ids), Markdown export,
  i18n (`tools/gen_strings.py`: Mac catalog + `tools/desktop_strings.json`).
- `crates/platform`: `Sampler` (sysinfo base + `win/` overrides), pinger, MTR, Keep Awake, kill,
  autostart, fonts, exe icons. `win/`: pdh, icmp, adapters (+WLAN, metered), battery IOCTLs,
  storage (NVMe health log with zero-access handle), gpu (DXGI + PDH + NVML), d3d (bench GEMM),
  power (request, lid override with crash restore, jiggle), system, process, icons.
  `tests/windows_live.rs` exercises every source on a real Windows runner.
- `crates/platform/src/linux/`: procfs (CPU split, meminfo, diskstats, PSI, zram), hwmon
  (CPU/GPU/drive temps, fan RPM, clocks, Intel + Pi throttling), gpu (amdgpu, i915/xe RC6,
  Pi V3D gpu_stats, NVML via dlopen), gpubench (WGSL GEMM on wgpu Vulkan/GLES), storage
  (/sys/block + UDisks2 NVMe/ATA SMART), netinfo (route, DNS, NetworkManager SSID/signal/
  metered), icmp (ping sockets + IP_RECVERR traceroute), power (logind inhibitor fd, portal /
  ScreenSaver idle inhibit, XTest jiggle, `_NET_WORKAREA`), system (DMI / device tree / Steam
  Deck names, ARM core names, hybrid topology, XDG autostart, fontconfig, SNI host check),
  icons (.desktop → hicolor PNG). `tests/linux_live.rs` runs on Linux CI.
- `linux/`: `.desktop` entry, hicolor icons (from `app/res/blip.ico`), per-user `install.sh`,
  tarball README and prerelease notes.
- `app`: `Blip.exe` (tray app) + `blip-cli.exe`. `app.rs` shell, `popover.rs`, `panels/`,
  `settings_ui.rs`, `tray.rs` (bars/numbers/logo icons), `publictest.rs` (hidden WebView2),
  `screens.rs` offscreen renders (`BLIP_SHOTS_DIR=… cargo test -p blip-desktop render`),
  `demo.rs` sample data.

## Dev loop (macOS host)
- Toolchain: rustup's cargo first in PATH (`export PATH=$HOME/.cargo/bin:$PATH` — Homebrew's
  rust has no cross targets); `CARGO_TARGET_DIR` outside iCloud.
- `cargo clippy --workspace --all-targets --target x86_64-pc-windows-msvc -- -D warnings`
  (and `aarch64-pc-windows-msvc`, and the host) — all must be clean.
- Linux via zig (`brew install zig`, `cargo install cargo-zigbuild`):
  `cargo-zigbuild clippy --workspace --all-targets --target x86_64-unknown-linux-gnu.2.28 -- -D warnings`
  (and `aarch64-…`); `cargo-zigbuild zigbuild --release --target <t>.2.28 -p blip-desktop`
  builds the shipping binaries. Their only DT_NEEDED is glibc; X11/Wayland/GL/Vulkan/NVML are
  dlopened.
- `cargo test --workspace` on the host; Windows and Linux behaviour are verified by
  `windows.yml` and `linux.yml` (dispatch them: pushes carry `[ci skip]` because Blip's Xcode
  Cloud builds every main push).
- `cargo fmt --all`, `python3 tools/gen_strings.py` after adding UI strings.

## Status
- [x] Core, platform, Windows layer, app shell, panels, Settings, CLI, CI.
- [x] Offscreen render check of popover + all 9 panels, light and dark.
- [x] First run on a real Windows desktop by the owner (previews 1–4 on an x64 gaming PC; ARM64 untested on hardware) (tray click → popover placement, focus /
      click-away, WebView2 public test, lid override on a laptop, NVMe health on real drives).
- [x] Prerelease wiring: a `windows-v*` tag makes windows.yml publish
      `Blip-<ver>-windows-{x64,arm64}.zip` + SHA256SUMS as a GitHub prerelease (notes from
      RELEASE_NOTES.md). If the tagged commit has `[ci skip]`, dispatch:
      `gh workflow run windows.yml --ref windows-v<ver>`.
- [x] `windows-v2.1.0` full release (2026-11-26), unsigned by the owner's choice; never GitHub
      "Latest" (Mac downloads use releases/latest). Landing page links the release tag.
- [ ] winget/Scoop manifests, if wanted.
- [x] No GTK/glib anywhere in Cargo.lock: tray-icon uses `ksni` (D-Bus SNI), wry has no
      `os-webview`. Keep it that way on Linux: SNI tray (KDE/SteamOS native; GNOME needs the
      AppIndicator extension), and the public speed test either skips WebKitGTK or uses webkit6.
- [x] Linux backend, x64 / arm64 / armv7, one glibc-2.28 build per arch (Ubuntu, Debian,
      Raspberry Pi OS, Fedora, Rocky/RHEL 8+, Arch, SteamOS). `linux.yml` lints, tests live
      sources, renders, launches the GUI under Xvfb, runs the CLI in Rocky 8 / Ubuntu / Debian /
      Fedora / Arch containers, and on a `linux-v*` tag publishes tarballs as a prerelease.
      Packaging: tarball + per-user `install.sh` — not Flatpak (its sandbox hides the host's
      process list) and not AppImage (FUSE 2 is missing on new distros).
- [x] `linux-v2.1.0-beta.2` published as a beta (2026-11-26; beta.1 misreported its version). Releases and docs ask users to
      open issues (`.github/ISSUE_TEMPLATE/linux-beta.yml`; `app/src/report.rs` prefills it).
      Keep the beta label until real desktops and devices have been confirmed.
- [ ] First run on real Linux desktops by the owner (SNI click position and popover
      placement per DE, click-away, UDisks SMART, Pi V3D, Keep Awake lid lock, jiggle on X11).

## Linux parity limits (no root)
- Tray needs a StatusNotifierItem host: stock GNOME (Fedora, Rocky) needs the AppIndicator
  extension; otherwise Blip runs as a window. SteamOS Game Mode has no tray.
- Wayland can't position client windows, so Blip prefers XWayland when a display exists
  (`BLIP_WAYLAND=1` opts out); on pure Wayland the popover opens where the compositor puts it,
  and the mouse jiggle is hidden (no client pointer control).
- The public OpenSpeedTest test opens in the browser: WebKitGTK would pull GTK back into the
  graph and add a runtime dependency. Self-hosted tests run natively, as on Windows.
- Intel GPU busy % comes from RC6 residency (engine counters need perf privileges). NVMe SMART
  needs UDisks ≥ 2.10 (Rocky 8 has 2.9: temperature only there).
- Ping/traceroute use ping sockets; where `net.ipv4.ping_group_range` excludes the user they
  fall back to the system `ping`/`traceroute`.

## Windows parity limits (no admin)
- No fan RPM and no CPU die temperature: both need a kernel driver. Blip shows ACPI thermal
  zones, NVIDIA GPU temperature and fan % (NVML), drive temperatures, and clock-vs-base throttling.
- SATA SMART attribute tables need admin, so SATA drives show temperature + pass/fail prediction.
- Bench has no Neural leg (no OS-shipped model); the GPU leg is D3D11 compute. Its scores are close
  to the Mac's, but they come from different libraries.
- SSID needs Windows location access on 24H2+; without it the Wi-Fi name stays hidden.
