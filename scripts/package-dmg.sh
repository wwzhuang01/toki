#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
sign_identity="${TOKI_CODESIGN_IDENTITY:-${APPLE_SIGNING_IDENTITY:--}}"
notarize="${TOKI_NOTARIZE:-0}"

if [[ "$notarize" == "1" && "$sign_identity" == "-" ]]; then
    printf 'Error: TOKI_NOTARIZE=1 requires a Developer ID signing identity (TOKI_CODESIGN_IDENTITY or APPLE_SIGNING_IDENTITY).\n' >&2
    exit 1
fi

app="$("$root/scripts/package-app.sh" "$@")"
if [[ "$notarize" == "1" ]]; then
    "$root/scripts/notarize.sh" app "$app"
fi

scratch="$(mktemp -d "$root/dist/.dmg.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/volume"
ditto "$app" "$scratch/volume/Toki.app"
ln -s /Applications "$scratch/volume/Applications"
hdiutil create -volname Toki -srcfolder "$scratch/volume" -format UDZO "$scratch/Toki.dmg" >&2

if [[ "$sign_identity" != "-" ]]; then
    codesign --force --timestamp --sign "$sign_identity" "$scratch/Toki.dmg" >&2
    codesign --verify --verbose=2 "$scratch/Toki.dmg" >&2
fi

if [[ "$notarize" == "1" ]]; then
    "$root/scripts/notarize.sh" dmg "$scratch/Toki.dmg"
fi

mv -f "$scratch/Toki.dmg" "$root/dist/Toki.dmg"
(cd "$root/dist" && shasum -a 256 Toki.dmg > Toki.dmg.sha256)
printf '%s\n' "$root/dist/Toki.dmg"
