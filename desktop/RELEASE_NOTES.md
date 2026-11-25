> **Fixed since preview.1:** preview.1 crashed at startup, before the tray icon appeared, with no message. This build fixes that crash. It hasn't been run on a PC with a graphics card yet, so the tray icon and popover are what to check first.
>
> **If anything goes wrong,** send `%APPDATA%\Blip\blip.log`. It records each startup step, your graphics driver, tray clicks and any crash, and a fatal error now shows a message box. Blip needs OpenGL 2.0 or newer.

**Preview build of Blip for Windows 10 and 11.** No administrator rights, ever. Unzip and run `Blip.exe`. It offers to **install itself for your user**: it's copied to `%LOCALAPPDATA%\Programs\Blip`, added to the Start menu and to Settings › Apps (uninstall it there like any app), started at login, and `blip-cli` is put on your PATH. Choose **No** to keep running it portably from wherever you unzipped it; Settings › General offers *Install Blip…* later. Running a newer download offers to update the installed copy. It sits in the notification area (drag it out of the ^ overflow to keep it visible).

For scripted installs: `Blip.exe --install` (silent), and `Blip.exe --uninstall --quiet`.

Pick the zip for your PC: **x64** for Intel/AMD, **arm64** for Snapdragon and other Windows on Arm machines. The exes aren't code-signed yet, so SmartScreen may say "Windows protected your PC": choose **More info › Run anyway**.

`blip-cli.exe` is the command-line counterpart of the Mac's Shortcuts actions (`blip-cli --help`).

### Worth checking on real hardware
These can't be covered by CI runners:
- Left-click the tray icon: the popover should open right above it and close when you click elsewhere. Right-click for the menu.
- Hover rows for the detail panels; open Settings and change the tray style.
- Network › public speed test (uses the built-in WebView2).
- Disk › drive health on an NVMe drive (life remaining, temperature).
- Keep Awake, including lid-closed mode on a laptop: closing the lid should keep it running, and normal lid behaviour should return when Keep Awake ends or Blip quits.
- Install from the download, then find Blip in the Start menu and in Settings › Apps; uninstall from there.
- Launch at login, then sign out and back in.

Data lives in `%APPDATA%\Blip`. See the CHANGELOG for everything in this build.
