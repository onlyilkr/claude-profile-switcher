#!/bin/bash
# Publishes dist/claude-profile-switcher.rb to the Homebrew tap through the GitHub API, so
# the token never appears in a git remote URL or a log line.
# Needs HOMEBREW_TAP_TOKEN: a fine-grained token with contents read/write on the tap only.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/update-tap.sh <version>}"
TAP="${TAP_REPOSITORY:-onlyilkr/homebrew-tap}"
FILE="Casks/claude-profile-switcher.rb"
: "${HOMEBREW_TAP_TOKEN:?HOMEBREW_TAP_TOKEN is not set}"
[[ -f dist/claude-profile-switcher.rb ]] || { echo "run scripts/package-release.sh first" >&2; exit 1; }

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "not a final version: $VERSION (prereleases never reach the tap)" >&2; exit 2; }
grep -q "version \"$VERSION\"" dist/claude-profile-switcher.rb || { echo "dist/claude-profile-switcher.rb is not for $VERSION" >&2; exit 1; }

export GH_TOKEN="$HOMEBREW_TAP_TOKEN"
# The current file's blob SHA, needed to replace it, and its version; both empty on the first
# release. For a missing file gh prints the error body on stdout, so only its exit status counts.
SHA=""
CURRENT=""
if gh api "repos/$TAP/contents/$FILE" --silent 2>/dev/null; then
    SHA=$(gh api "repos/$TAP/contents/$FILE" --jq .sha)
    CURRENT=$(gh api "repos/$TAP/contents/$FILE" --jq .content | tr -d '\n' | base64 --decode | sed -n 's/^  version "\(.*\)"$/\1/p')
fi
# The tap only ever moves forward: an older tag pushed later must not roll users back.
if [[ -n "$CURRENT" ]] && [[ "$(printf '%s\n%s\n' "$CURRENT" "$VERSION" | sort -V | tail -1)" != "$VERSION" || "$CURRENT" == "$VERSION" ]]; then
    echo "The tap already has $CURRENT; not replacing it with $VERSION." >&2
    exit 1
fi
ARGS=(-X PUT "repos/$TAP/contents/$FILE"
      -f "message=claude-profile-switcher $VERSION"
      -f "content=$(base64 < dist/claude-profile-switcher.rb | tr -d '\n')")
[[ -n "$SHA" ]] && ARGS+=(-f "sha=$SHA")
gh api "${ARGS[@]}" --jq .commit.html_url
