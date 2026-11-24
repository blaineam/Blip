# Blip for Windows (then Linux): port ledger

Rust workspace: native Win32 metrics, egui UI, tray icon, no admin. Linux later as a second
backend in `crates/platform` (the portable sysinfo layer already runs there).

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
- `app`: `Blip.exe` (tray app) + `blip-cli.exe`. `app.rs` shell, `popover.rs`, `panels/`,
  `settings_ui.rs`, `tray.rs` (bars/numbers/logo icons), `publictest.rs` (hidden WebView2),
  `screens.rs` offscreen renders (`BLIP_SHOTS_DIR=… cargo test -p blip-desktop render`),
  `demo.rs` sample data.

## Dev loop (macOS host)
- Toolchain: rustup's cargo first in PATH; `CARGO_TARGET_DIR` outside iCloud.
- `cargo clippy --workspace --all-targets --target x86_64-pc-windows-msvc -- -D warnings`
  (and `aarch64-pc-windows-msvc`, and the host) — all three must be clean.
- `cargo test --workspace` on the host; Windows behaviour is verified by `windows.yml`
  (dispatch it: pushes carry `[ci skip]` because Blip's Xcode Cloud builds every main push).
- `cargo fmt --all`, `python3 tools/gen_strings.py` after adding UI strings.

## Status
- [x] Core, platform, Windows layer, app shell, panels, Settings, CLI, CI.
- [x] Offscreen render check of popover + all 9 panels, light and dark.
- [ ] First run on a real Windows desktop by the owner (tray click → popover placement, focus /
      click-away, WebView2 public test, lid override on a laptop, NVMe health on real drives).
- [ ] Release wiring: attach `Blip-windows-{x64,arm64}.zip` to GitHub Releases (release.yml
      job, like Glint), code signing, winget/Scoop manifests. Landing-page mention at release.
- [ ] Linux: Ubuntu / Raspberry Pi OS (arm64) / Rocky 8 (glibc 2.28 build) / SteamOS
      (Flatpak or AppImage). Needs: hwmon temps + fans (sysinfo Components / /sys/class/hwmon),
      /sys/class/power_supply battery, /proc/diskstats, NVMe via `/sys/class/nvme` (health log
      needs root → smartctl-free fallback to temp only), tray via StatusNotifierItem
      (tray-icon's GTK/appindicator backend), O_DIRECT disk test (done), systemd-inhibit Keep
      Awake (done), traceroute via unprivileged ICMP datagram sockets.

## Windows parity limits (no admin)
- No fan RPM and no CPU die temperature: both need a kernel driver. Blip shows ACPI thermal
  zones, NVIDIA GPU temperature and fan % (NVML), drive temperatures, and clock-vs-base throttling.
- SATA SMART attribute tables need admin, so SATA drives show temperature + pass/fail prediction.
- Bench has no Neural leg (no OS-shipped model); the GPU leg is D3D11 compute. Its scores are close
  to the Mac's, but they come from different libraries.
- SSID needs Windows location access on 24H2+; without it the Wi-Fi name stays hidden.
