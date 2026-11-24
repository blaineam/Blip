**Preview build of Blip for Windows 10 and 11.** No installer and no administrator rights: unzip anywhere and run `Blip.exe`. It sits in the notification area (drag it out of the ^ overflow to keep it visible).

Pick the zip for your PC: **x64** for Intel/AMD, **arm64** for Snapdragon and other Windows on Arm machines. The exes aren't code-signed yet, so SmartScreen may say "Windows protected your PC": choose **More info › Run anyway**.

`blip-cli.exe` is the command-line counterpart of the Mac's Shortcuts actions (`blip-cli --help`).

### Worth checking on real hardware
These can't be covered by CI runners:
- Left-click the tray icon: the popover should open right above it and close when you click elsewhere. Right-click for the menu.
- Hover rows for the detail panels; open Settings and change the tray style.
- Network › public speed test (uses the built-in WebView2).
- Disk › drive health on an NVMe drive (life remaining, temperature).
- Keep Awake, including lid-closed mode on a laptop: closing the lid should keep it running, and normal lid behaviour should return when Keep Awake ends or Blip quits.
- Launch at login, then sign out and back in.

Data lives in `%APPDATA%\Blip`. See the CHANGELOG for everything in this build.
