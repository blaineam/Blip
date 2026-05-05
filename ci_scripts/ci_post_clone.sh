#!/bin/bash
set -euo pipefail

# Xcode Cloud post-clone script
# Installs XcodeGen and generates the Xcode project so that
# Xcode Cloud can build the BlipAppStore scheme for MAS distribution.

echo "=== Blip: Xcode Cloud Post-Clone ==="

# Install XcodeGen via Homebrew
echo "Installing XcodeGen..."
brew install xcodegen

# Generate app icons (full-bleed PNGs for macOS 26 xcassets format)
echo "Generating app icons..."
cd "$CI_PRIMARY_REPOSITORY_PATH"
swift Scripts/generate-icon.swift

# Generate the Xcode project
echo "Generating Xcode project..."
xcodegen generate

echo "=== Post-clone complete ==="
