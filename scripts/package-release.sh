#!/bin/bash
# Builds the release artifacts for one version into dist/:
#   Claude-Profile-Switcher-<version>.zip   the app, universal, ad-hoc signed
#   checksums.txt                           SHA-256 of the zip
#   claude-profile-switcher.rb              the Homebrew cask for that zip
#   release-notes.md                        that version's CHANGELOG section
# Usage: scripts/package-release.sh 1.2.3
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/package-release.sh <version>}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]]; then
    echo "not a version: $VERSION" >&2
    exit 2
fi

VERSION="$VERSION" scripts/build-app.sh
rm -rf dist
mkdir -p dist
ZIP="Claude-Profile-Switcher-$VERSION.zip"
# ditto keeps the bundle's symlinks, permissions and signature intact; zip would not.
ditto -c -k --sequesterRsrc --keepParent "build/Claude Profile Switcher.app" "dist/$ZIP"
(cd dist && shasum -a 256 "$ZIP" > checksums.txt)
SHA=$(cut -d' ' -f1 dist/checksums.txt)

sed -e "s/__VERSION__/$VERSION/g" -e "s/__SHA256__/$SHA/g" packaging/claude-profile-switcher.rb.template > dist/claude-profile-switcher.rb

# The section between "## [<version>]" and the next "## [" heading.
awk -v v="$VERSION" '
    $0 ~ "^## \\[" v "\\]" { on = 1; next }
    on && /^## \[/ { exit }
    on { print }
' CHANGELOG.md > dist/release-notes.md
if [[ ! -s dist/release-notes.md ]]; then
    echo "No CHANGELOG.md section for $VERSION; writing a placeholder." >&2
    echo "See CHANGELOG.md." > dist/release-notes.md
fi

ls -l dist
