#!/bin/bash
set -euo pipefail

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
