#!/bin/sh
# Prints the CHANGELOG.md section for one version, e.g. scripts/release-notes.sh 0.2.0
set -eu
awk -v v="$1" '
    /^## / { if (found) exit; found = ($2 == v) ; next }
    found { print }
' CHANGELOG.md | sed -e '/./,$!d'
