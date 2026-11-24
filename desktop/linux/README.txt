Blip for Linux (preview)
========================

A featherlight system monitor in the system tray. It needs no root, no package manager and no
background service: everything it reads is open to your own account.

Install (just for you, into ~/.local):

    ./install.sh

Then open Blip from your app menu, or run `Blip`. To remove it again:

    ./install.sh --uninstall

Or run it in place without installing: ./Blip

Runs on any distribution with glibc 2.28 or newer: Ubuntu 18.10+, Debian 10+, Raspberry Pi OS
(64-bit: arm64, 32-bit: armv7), Fedora, Rocky/Alma/RHEL 8+, Arch, and SteamOS desktop mode.

Tray: KDE Plasma (and SteamOS), Ubuntu's GNOME, Xfce, Cinnamon, MATE, LXQt and Raspberry Pi
OS show it out of the box. Stock GNOME (Fedora, Rocky) needs the "AppIndicator and
KStatusNotifierItem Support" extension; without a tray, Blip opens as a window instead.

Where things come from, all without root:
  - CPU, memory, disk I/O, pressure: /proc
  - Temperatures and fan speeds: /sys/class/hwmon and /sys/class/thermal
  - Drive health (S.M.A.R.T.): UDisks2 (the desktop's disk service), plus drive temperatures
  - GPU: amdgpu / Intel / Raspberry Pi V3D sysfs counters, NVIDIA's NVML
  - Wi-Fi name, signal and metered networks: NetworkManager
  - Ping and traceroute: unprivileged ICMP "ping sockets"
  - Keep Awake: systemd-logind inhibitors and the desktop portal

`blip-cli` is the command-line companion: `blip-cli --help`.
Settings live in ~/.config/blip.
