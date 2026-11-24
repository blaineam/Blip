#!/bin/sh
# Installs Blip for the current user only — no root, nothing outside your home folder.
#   ./install.sh              install (or update) into ~/.local
#   ./install.sh --uninstall  remove it again (settings in ~/.config/blip are kept)
set -eu

here=$(cd "$(dirname "$0")" && pwd)
data=${XDG_DATA_HOME:-$HOME/.local/share}
bin=$HOME/.local/bin
app=$data/blip
apps=$data/applications
icons=$data/icons/hicolor
autostart=${XDG_CONFIG_HOME:-$HOME/.config}/autostart/com.blainemiller.Blip.desktop

refresh() {
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q "$apps" 2>/dev/null || true
    command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t "$icons" 2>/dev/null || true
}

if [ "${1:-}" = "--uninstall" ]; then
    pkill -x Blip 2>/dev/null || true
    rm -rf "$app"
    rm -f "$bin/blip-cli" "$bin/Blip" "$apps/com.blainemiller.Blip.desktop" "$autostart"
    for s in 16 24 32 48 64 128 256; do
        rm -f "$icons/${s}x${s}/apps/com.blainemiller.Blip.png"
    done
    refresh
    echo "Blip removed. Your settings are still in ${XDG_CONFIG_HOME:-$HOME/.config}/blip."
    exit 0
fi

mkdir -p "$app" "$bin" "$apps"
# Replace a running copy cleanly (the binary is busy while it runs).
pkill -x Blip 2>/dev/null && sleep 1 || true
install -m 755 "$here/Blip" "$app/Blip"
install -m 755 "$here/blip-cli" "$app/blip-cli"
ln -sf "$app/Blip" "$bin/Blip"
ln -sf "$app/blip-cli" "$bin/blip-cli"
for s in 16 24 32 48 64 128 256; do
    mkdir -p "$icons/${s}x${s}/apps"
    install -m 644 "$here/icons/$s.png" "$icons/${s}x${s}/apps/com.blainemiller.Blip.png"
done
sed "s|^Exec=Blip|Exec=\"$app/Blip\"|" "$here/com.blainemiller.Blip.desktop" > "$apps/com.blainemiller.Blip.desktop"
chmod 644 "$apps/com.blainemiller.Blip.desktop"
# Launch at login points at the binary; keep it pointing at this install.
if [ -f "$autostart" ]; then
    sed -i "s|^Exec=.*|Exec=\"$app/Blip\" --background|" "$autostart"
fi
refresh

echo "Blip is installed. Open it from your app menu, or run: Blip"
case ":$PATH:" in
    *":$bin:"*) ;;
    *) echo "Note: $bin isn't on your PATH yet; the app menu entry works regardless." ;;
esac
if [ "${XDG_CURRENT_DESKTOP:-}" != "${XDG_CURRENT_DESKTOP#*GNOME}" ] &&
    ! gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
        --method org.freedesktop.DBus.NameHasOwner org.kde.StatusNotifierWatcher 2>/dev/null | grep -q true; then
    echo "GNOME has no tray icons without the AppIndicator extension (Ubuntu ships it on)."
    echo "Install \"AppIndicator and KStatusNotifierItem Support\" for the tray; until then Blip opens as a window."
fi
