#!/bin/sh
# Installs the latest Remvel release into /Applications and starts it.
# --nightly installs the newest build of main instead.
# After that, Remvel updates itself from its menu bar menu.
set -eu
API=https://api.github.com/repos/mgh3326/remvel/releases/latest
[ "${1:-}" = --nightly ] && API=https://api.github.com/repos/mgh3326/remvel/releases/tags/nightly
DEST=/Applications/Remvel.app

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
curl -fsSL "$API" -o "$WORK/release.json"
# The newest Remvel-<build>.zip asset.
URL=$(/usr/bin/python3 -I -c '
import json, re, sys
assets = json.load(open(sys.argv[1]))["assets"]
builds = [(int(m.group(1)), a["browser_download_url"]) for a in assets if (m := re.fullmatch(r"Remvel-(\d+)\.zip", a["name"]))]
print(max(builds)[1] if builds else "")
' "$WORK/release.json")
[ -n "$URL" ] || { echo "Nothing published at $API yet." >&2; exit 1; }

echo "Downloading $URL"
curl -fsSL "$URL" -o "$WORK/Remvel.zip"
ditto -x -k "$WORK/Remvel.zip" "$WORK"

osascript -e 'tell application id "io.github.remvel.Remvel" to quit' 2>/dev/null || true
pkill -x Remvel 2>/dev/null || true
rm -rf "$DEST"
ditto "$WORK/Remvel.app" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
codesign -dv "$DEST" 2>&1 | grep -E "^Authority|Signature=adhoc" || true
open -g "$DEST"
echo "Installed $DEST (build $(defaults read "$DEST/Contents/Info" CFBundleVersion))"
