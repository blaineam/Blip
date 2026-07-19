#!/bin/bash
set -euo pipefail

# ---- docs-only guard ------------------------------------------------------
# Mirrors the workflow's Files-and-Folders start condition in App Store Connect
# (that filter is the real gate; this is belt-and-braces for what it misses).
# If EVERY file changed in this commit is docs / screenshots / store metadata,
# there is nothing to build.
#
# NOTE: exiting non-zero is the ONLY way to stop an Xcode Cloud run early. A run
# that ends with the banner below is a DELIBERATE SKIP, not a broken build.
__REPO="${CI_PRIMARY_REPOSITORY_PATH:-$(pwd)}"
if ( cd "$__REPO" && git rev-parse HEAD~1 >/dev/null 2>&1 ); then
    __CHANGED="$(cd "$__REPO" && git diff --name-only HEAD~1 HEAD || true)"
    __RELEVANT="$(printf '%s\n' "$__CHANGED" | grep -vE '(^|/)(docs|screenshots|appstore|AppStore|Documentation|\.claude)/|\.(md|monkr)$|(^|/)(\.local-ci\.conf|\.local-screenshots\.conf|knox\.config\.mjs|soren\.config\.mjs|changelog\.txt|build\.log)$' || true)"
    if [ -n "$__CHANGED" ] && [ -z "$__RELEVANT" ]; then
        echo "=============================================================="
        echo "  BUILD SKIPPED — this is NOT a failure."
        echo "  Every file in this commit is docs/screenshots/metadata:"
        printf '%s\n' "$__CHANGED" | sed 's/^/    /'
        echo "  Nothing here affects the app binary, so the run stops now"
        echo "  instead of burning compute minutes and uploading a build."
        echo "=============================================================="
        exit 1
    fi
fi
# ---- end docs-only guard --------------------------------------------------

# Xcode Cloud post-clone script
# Installs XcodeGen and generates the Xcode project so that
# Xcode Cloud can build the BlipAppStore scheme for MAS distribution.

echo "=== Blip: Xcode Cloud Post-Clone ==="

# Install XcodeGen via Homebrew
echo "Installing XcodeGen..."
brew install xcodegen

# Generate the Xcode project
echo "Generating Xcode project..."
cd "$CI_PRIMARY_REPOSITORY_PATH"
xcodegen generate

echo "=== Post-clone complete ==="
