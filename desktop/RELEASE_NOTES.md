**Blip for Windows 10 and 11**, x64 and ARM64. A featherlight system monitor in the notification area, with the same popover and live detail panels as Blip on the Mac. No administrator rights, no drivers, no background service. Free and open source.

### Download
| Your PC | File |
|---|---|
| Intel or AMD | `Blip-…-windows-x64.zip` |
| Snapdragon and other Windows on Arm | `Blip-…-windows-arm64.zip` |

Unzip and run `Blip.exe`. It offers to **install itself for your user**: Start menu, Settings › Apps (uninstall it there like any app), launch at login, and `blip-cli` on your PATH. Choose **No** to keep running it portably; Settings can install it later. Running a newer download updates the installed copy. For scripts: `Blip.exe --install` and `Blip.exe --uninstall --quiet`. Drag the tray icon out of the **^** overflow to keep it visible.

**SmartScreen:** Blip for Windows isn't code-signed, so Windows may say "Windows protected your PC". Choose **More info › Run anyway**. You can check your download against `SHA256SUMS.txt`.

### What's in it
CPU, memory, disk (including NVMe drive health without admin), network, GPU, thermals, battery, Keep Awake, speed tests, live traceroute with an offline map, Blip Bench, and `blip-cli` for scripts. In the same nine languages as the Mac.

Windows keeps CPU die temperature and fan speeds behind kernel drivers, so Blip shows what it can read without admin rights. It needs OpenGL 2.0 or newer, which some virtual machines and Remote Desktop sessions don't provide.

Problems? [Open an issue](https://github.com/blaineam/blip/issues) and attach `%APPDATA%\Blip\blip.log`.
