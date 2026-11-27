#!/bin/bash
# Sets up Blip for Android's release signing key. Run it yourself, once, on your own Mac:
#
#   android/tools/setup-signing.sh
#
# It creates the key (if there isn't one yet) in ~/.android-keys/blip with a random password
# that is never printed, records the certificate's public fingerprint in android/signing-cert.sha256
# (commit that file), and stores the four GitHub Actions secrets the Android workflow signs with.
# Running it again reuses the same key and uploads the secrets again.
#
# Every future update must be signed with this key, or Android refuses to install it over the
# old one. Keep a copy of the whole folder somewhere safe besides this Mac.
#
#   --no-upload      create and check the key, but leave GitHub alone
#   BLIP_KEY_DIR     where the key lives (default ~/.android-keys/blip)
#   BLIP_CERT_FILE   where the fingerprint is recorded (default android/signing-cert.sha256)
#   BLIP_REPO        the GitHub repository (default blaineam/blip)
set -euo pipefail
umask 077

upload=true
case "${1:-}" in
    "") ;;
    --no-upload) upload=false ;;
    *) echo "usage: $0 [--no-upload]" >&2; exit 2 ;;
esac

here=$(cd "$(dirname "$0")" && pwd)
dir=${BLIP_KEY_DIR:-$HOME/.android-keys/blip}
store=$dir/blip-release.jks
passfile=$dir/password.txt
cert_file=${BLIP_CERT_FILE:-$here/../signing-cert.sha256}
repo=${BLIP_REPO:-blaineam/blip}
alias_name=blip

die() { echo "error: $*" >&2; exit 1; }

keytool=$(command -v keytool || true)
for candidate in "${JAVA_HOME:+$JAVA_HOME/bin/keytool}" /opt/homebrew/opt/openjdk@17/bin/keytool; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then keytool=$candidate; break; fi
done
[ -n "$keytool" ] && "$keytool" -help >/dev/null 2>&1 || die "no working keytool; install JDK 17"
if $upload; then
    command -v gh >/dev/null || die "install the GitHub CLI (gh) first"
    gh auth status >/dev/null 2>&1 || die "sign in first: gh auth login"
fi

if [ -f "$store" ]; then
    [ -s "$passfile" ] || die "$store exists but $passfile is missing: restore it from your backup"
    echo "Using the key already in $dir."
else
    [ ! -e "$passfile" ] || die "$passfile exists without its key: restore $store from your backup"
    # A recorded fingerprint means a key already exists somewhere. A new one could not update
    # installs signed with it.
    [ ! -s "$cert_file" ] || die "$cert_file records an existing key that isn't in $dir. Restore it from your backup."
    mkdir -p "$dir"
    chmod 700 "$(dirname "$dir")" "$dir" 2>/dev/null || true
    # 48 hex characters (192 bits), no trailing newline.
    openssl rand -hex 24 | tr -d '\n' >"$passfile"
    "$keytool" -genkeypair -keystore "$store" -storetype PKCS12 -alias "$alias_name" \
        -keyalg RSA -keysize 4096 -sigalg SHA256withRSA -validity 10950 \
        -dname "CN=Blip, O=wemiller.com" \
        -storepass:file "$passfile" -keypass:file "$passfile" >/dev/null
    echo "Created a new signing key in $dir."
fi
chmod 600 "$store" "$passfile"

# The certificate's SHA-256, as apksigner prints it: lowercase hex, no colons. Public.
fingerprint=$("$keytool" -exportcert -keystore "$store" -alias "$alias_name" -storepass:file "$passfile" |
    openssl dgst -sha256 | awk '{print $NF}')
[ ${#fingerprint} -eq 64 ] || die "couldn't read the certificate (wrong password file?)"

if [ -s "$cert_file" ]; then
    [ "$(tr -d '[:space:]' <"$cert_file")" = "$fingerprint" ] ||
        die "this key doesn't match $cert_file. Don't upload it: restore the original key."
else
    printf '%s\n' "$fingerprint" >"$cert_file"
    chmod 644 "$cert_file"
fi
echo "Certificate SHA-256: $fingerprint"

if $upload; then
    # Values go through standard input, so they never appear in a command line or on screen.
    base64 <"$store" | tr -d '\n' | gh secret set ANDROID_KEYSTORE_BASE64 --repo "$repo"
    gh secret set ANDROID_KEYSTORE_PASSWORD --repo "$repo" <"$passfile"
    printf '%s' "$alias_name" | gh secret set ANDROID_KEY_ALIAS --repo "$repo"
    gh secret set ANDROID_KEY_PASSWORD --repo "$repo" <"$passfile"
    echo "GitHub secrets are set on $repo."
else
    echo "Skipped GitHub (--no-upload)."
fi

echo
echo "Now back up $dir (both files) somewhere safe besides this Mac, for example your"
echo "password manager. Without them you can't ship updates to anyone who has installed Blip."
