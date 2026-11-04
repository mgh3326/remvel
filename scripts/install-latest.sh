#!/bin/sh
# Installs the newest successful CI build of main into /Applications and restarts Remvel.
# Needs the GitHub CLI signed in to any account (the repo is public).
set -eu
REPO=mgh3326/remvel
DEST=/Applications/Remvel.app

RUN=$(gh run list -R "$REPO" -w build.yml -b main -s success -L 1 --json databaseId,headSha \
    -q '.[0] | "\(.databaseId) \(.headSha)"')
[ -n "$RUN" ] || { echo "No successful build of main yet." >&2; exit 1; }
set -- $RUN
ID=$1 SHA=$2

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
echo "Downloading build ${SHA%"${SHA#???????}"} (run $ID)…"
gh run download "$ID" -R "$REPO" -n "Remvel-$SHA" -D "$WORK"
ditto -x -k "$WORK/Remvel.zip" "$WORK"

osascript -e 'tell application id "io.github.remvel.Remvel" to quit' 2>/dev/null || true
pkill -x Remvel 2>/dev/null || true
rm -rf "$DEST"
ditto "$WORK/Remvel.app" "$DEST"
# gh does not set the quarantine flag, but a browser download would.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
codesign -dv "$DEST" 2>&1 | grep -E "^Authority|Signature=adhoc" || true
open -g "$DEST"
echo "Installed $DEST"
