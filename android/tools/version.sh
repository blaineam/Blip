#!/bin/sh
# "versionName versionCode" for an Android release tag such as android-v2.1.0 or
# android-v2.1.0-beta.1. Android only installs an update whose versionCode is higher, so the code
# is built to rise in release order: 2.1.0-alpha.1 < -beta.1 < -rc.1 < 2.1.0 < 2.1.1-alpha.1.
#   MAJOR*1000000 + MINOR*10000 + PATCH*100 + stage
#   stage: alpha.N = N (1-29), beta.N = 30+N (31-59), rc.N = 60+N (61-89), final = 99
set -eu
tag=${1:-}
bad() { echo "version.sh: '$tag' isn't android-vX.Y.Z or android-vX.Y.Z-(alpha|beta|rc).N: $*" >&2; exit 1; }
echo "$tag" | grep -qE '^android-v(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]?)\.(0|[1-9][0-9]?)(-(alpha|beta|rc)\.([1-9]|[12][0-9]))?$' ||
    bad "MINOR, PATCH up to 99; N from 1 to 29"
name=${tag#android-v}
core=${name%%-*}
major=${core%%.*}
rest=${core#*.}
minor=${rest%.*}
patch=${rest#*.}
case "$name" in
    *-alpha.*) stage=$((${name##*.})) ;;
    *-beta.*) stage=$((30 + ${name##*.})) ;;
    *-rc.*) stage=$((60 + ${name##*.})) ;;
    *) stage=99 ;;
esac
echo "$name $((major * 1000000 + minor * 10000 + patch * 100 + stage))"
