## Beta: please tell us what breaks

**Blip for Linux is a beta.** It builds and passes its tests on x64 and arm64 Linux in CI, but it hasn't yet been tried on real Linux desktops and devices, and the 32-bit ARM build has only been compiled, never run. **If you run into a problem, please [open an issue](https://github.com/blaineam/blip/issues/new?template=linux-beta.yml).** Anything that looks off is worth reporting, however small, and so is hearing that it works on your distribution. In the app, **Settings › Report an issue** fills in your version and system details for you.

## Download

**Blip for Linux.** No root and no package manager: download the tarball for your machine, extract it, and run `./install.sh` (installs into `~/.local` for your user only), or just run `./Blip` in place.

| Your machine | Tarball |
|---|---|
| Intel/AMD PCs, Steam Deck | `…-linux-x64.tar.gz` |
| Raspberry Pi OS 64-bit (Pi 3/4/5), ARM laptops and servers | `…-linux-arm64.tar.gz` |
| Raspberry Pi OS 32-bit | `…-linux-armv7.tar.gz` |

One build runs on any distribution with glibc 2.28 or newer: Ubuntu, Debian and Raspberry Pi OS, Fedora, Rocky/Alma/RHEL 8+, Arch and SteamOS. CI runs each build inside Rocky Linux 8, Ubuntu, Debian, Fedora and Arch containers.

**Tray:** works out of the box on KDE Plasma (and SteamOS desktop mode), Ubuntu's GNOME, Xfce, Cinnamon, MATE, LXQt and Raspberry Pi OS. Stock GNOME (Fedora, Rocky) needs the *AppIndicator and KStatusNotifierItem Support* extension. Without a tray, Blip opens as a regular window instead.

**What Linux adds over Windows:** real fan RPM and CPU die temperatures (hwmon), drive S.M.A.R.T. through UDisks2, real load averages and memory-pressure stall info, and since-boot disk totals.

### Worth checking on real hardware
These can't be covered by CI runners:
- Left-click the tray icon: the popover should open by the icon and close when you click elsewhere. Right-click for Blip / Settings / Quit.
- Hover rows for the detail panels; open Settings and change the tray style.
- Thermal: CPU temperature and fan speeds on your machine.
- Disk › drive health on NVMe/SATA drives (needs UDisks2, which every desktop install has).
- Network: Wi-Fi name and signal (NetworkManager), router ping, traceroute.
- Keep Awake, including lid-closed on a laptop, and the mouse jiggle (X11 sessions only; Wayland doesn't let apps move the pointer).
- Blip Bench's GPU leg (Vulkan) on a real GPU, including the Raspberry Pi 4/5.
- Launch at login, then sign out and back in.

The public OpenSpeedTest test opens in your browser on Linux. Self-hosted servers are measured and graphed in Blip as on Windows.
