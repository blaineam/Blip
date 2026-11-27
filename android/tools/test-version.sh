#!/bin/sh
# Checks version.sh: valid tags rise in release order, and malformed ones are refused.
set -eu
here=$(dirname "$0")
last=0
for tag in android-v2.1.0-alpha.1 android-v2.1.0-beta.1 android-v2.1.0-beta.29 android-v2.1.0-rc.1 \
    android-v2.1.0 android-v2.1.1-alpha.1 android-v2.1.1 android-v2.2.0 android-v2.99.99 android-v3.0.0; do
    code=$(sh "$here/version.sh" "$tag" | cut -d' ' -f2)
    [ "$code" -gt "$last" ] || { echo "$tag: versionCode $code is not above $last" >&2; exit 1; }
    last=$code
done
[ "$(sh "$here/version.sh" android-v2.1.0)" = "2.1.0 2010099" ]
[ "$(sh "$here/version.sh" android-v2.1.0-beta.2)" = "2.1.0-beta.2 2010032" ]
for tag in v2.1.0 android-v2.1 android-v2.100.0 android-v2.1.0-beta android-v2.1.0-beta.30 \
    android-v2.1.0-preview.1 android-v02.1.0 "android-v2.1.0 x" ""; do
    if sh "$here/version.sh" "$tag" >/dev/null 2>&1; then
        echo "accepted a bad tag: '$tag'" >&2
        exit 1
    fi
done
echo "version.sh ok"
