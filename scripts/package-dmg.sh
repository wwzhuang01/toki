#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
app="$("$root/scripts/package-app.sh" "$@")"
scratch="$(mktemp -d "$root/dist/.dmg.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/volume"
ditto "$app" "$scratch/volume/Toki.app"
ln -s /Applications "$scratch/volume/Applications"
hdiutil create -volname Toki -srcfolder "$scratch/volume" -format UDZO "$scratch/Toki.dmg" >&2
mv -f "$scratch/Toki.dmg" "$root/dist/Toki.dmg"
(cd "$root/dist" && shasum -a 256 Toki.dmg > Toki.dmg.sha256)
printf '%s\n' "$root/dist/Toki.dmg"
