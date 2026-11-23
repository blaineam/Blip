# Blip for Windows (then Linux): port ledger

Rust workspace. The plan is native Win32 for every metric, egui for the UI, and nothing that needs admin. Linux would come later as a second backend in `crates/platform`.

## Done (builds and tests pass on macOS)
- `crates/core` (31 tests): models, formatting, history, recommendations, connection grades, MTR stats + host validation, BenchKit port (same frozen references; D3D11 GPU leg is injected, the Neural leg drops out), self-hosted OpenSpeedTest tester + `ExternalRun` hook for the public widget, uncached disk benchmark (NO_BUFFERING / O_DIRECT), DB-IP GeoIP, settings (Mac `@AppStorage` keys + CLI get/set), metric catalog (Mac ids), Markdown export, i18n (`tools/gen_strings.py` pulls in all 421 Mac translations).
- `crates/platform`: portable sysinfo sampler, pinger, MTR session, Keep Awake front end (3 tests).
- `crates/platform/src/win/` is written but has **not been compiled yet**: pdh, icmp (ping + TTL traceroute), adapters (IP Helper, WLAN, metered), battery IOCTLs, storage (NVMe health log with zero-access handle), gpu (DXGI + PDH engines + NVML), d3d (bench compute), power (power request, lid override with crash restore, jiggle), dev.

## Next
1. `win/mod.rs` (WinSampler: PDH CPU user/kernel/perf %/queue → LoadAvg, PhysicalDisk I/O, thermal zones + level, GPU, battery, drives every 60 s, adapters, OS/model from registry, P/E cores; `ensure_winrt`), `win/system.rs` (ui_language, HKCU Run autostart, ShellExecute, has_lid), `win/process.rs` (OpenProcess+TerminateProcess), `win/icons.rs` (ExtractIconExW → RGBA).
2. Cross-check: `cargo clippy --target x86_64-pc-windows-msvc -p blip-platform -- -D warnings` (rustup cargo, `CARGO_TARGET_DIR` outside iCloud).
3. `app/`: eframe/egui tray app (tray-icon; Bars/Numbers/Logo icons), popover + hover detail panels (immediate viewports), pin/detach, Settings window, Segoe UI + Segoe Fluent Icons + CJK fonts loaded from the OS, public OpenSpeedTest via a hidden WebView2 (wry), traceroute map (Natural Earth outline), `blip` CLI (metric/bench/speedtest/disktest/trace/get/set), manifest asInvoker + icon via winresource.
4. Desktop-only strings in `tools/desktop_strings.json` (8 languages), e.g. "Your PC is running hot (%@)".
5. CI `.github/workflows/windows.yml` (fmt/clippy/test/build x64+arm64), release job attaching `Blip-windows-{x64,arm64}.exe`, README/CHANGELOG/site.
6. Linux backends: Ubuntu, Raspberry Pi OS (arm64), Rocky 8 (glibc 2.28 build), SteamOS (Flatpak/AppImage).

## Windows parity limits (no admin)
- No fan RPM and no CPU die temperature: both need a kernel driver. Blip shows ACPI thermal zones, NVIDIA GPU temps via NVML, drive temps, and clock throttling instead.
- SATA SMART attributes need admin, so SATA drives show temperature and pass/fail prediction only.
- There's no Neural bench leg on Windows.
