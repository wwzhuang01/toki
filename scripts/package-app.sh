#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
icon=""
if [[ $# -gt 0 ]]; then
    if [[ $# -ne 2 || "$1" != --icon || ! -f "$2" ]]; then
        printf 'Usage: %s [--icon /path/to/icon.png]\n' "$0" >&2
        exit 64
    fi
    icon="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
elif [[ -f "$root/assets/AppIcon.png" ]]; then
    icon="$root/assets/AppIcon.png"
fi

# Build Universal Binary (Apple Silicon + Intel) by default.
# Override with TOKI_ARCHS="arm64" for single-arch local dev builds.
read -r -a archs <<< "${TOKI_ARCHS:-arm64 x86_64}"
if [[ ${#archs[@]} -eq 0 ]]; then
    printf 'TOKI_ARCHS must specify at least one architecture.\n' >&2
    exit 64
fi

cd "$root"
mkdir -p "$root/dist"
scratch="$(mktemp -d "$root/dist/.app.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

app="$scratch/Toki.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"

swift_binaries=()
for arch in "${archs[@]}"; do
    swift build -c release --arch "$arch" >&2
    binary_dir="$(swift build -c release --arch "$arch" --show-bin-path)"
    swift_binaries+=("$binary_dir/Toki")
done

if [[ ${#swift_binaries[@]} -eq 1 ]]; then
    install -m 755 "${swift_binaries[0]}" "$app/Contents/MacOS/Toki"
else
    lipo -create "${swift_binaries[@]}" -output "$app/Contents/MacOS/Toki"
    chmod 755 "$app/Contents/MacOS/Toki"
fi

cp "$root/scripts/Info.plist" "$app/Contents/Info.plist"
if [[ -n "${TOKI_BUNDLE_ID:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${TOKI_BUNDLE_ID}" "$app/Contents/Info.plist"
fi
if [[ -n "${TOKI_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${TOKI_VERSION}" "$app/Contents/Info.plist"
fi
if [[ -n "${TOKI_BUILD_NUMBER:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${TOKI_BUILD_NUMBER}" "$app/Contents/Info.plist"
fi

zstd_version=1.5.7
zstd_sha256=37d7284556b20954e56e1ca85b80226768902e2edabd3b649e9e72c0c9012ee3
zstd_archive="${TOKI_ZSTD_ARCHIVE:-$root/.build/zstd-$zstd_version.tar.gz}"
if [[ ! -f "$zstd_archive" ]]; then
    mkdir -p "$(dirname "$zstd_archive")"
    curl --fail --silent --show-error --location --max-time 90 \
        "https://codeload.github.com/facebook/zstd/tar.gz/refs/tags/v$zstd_version" \
        --output "$scratch/zstd.tar.gz"
    printf '%s  %s\n' "$zstd_sha256" "$scratch/zstd.tar.gz" | shasum -a 256 -c - >&2
    mv "$scratch/zstd.tar.gz" "$zstd_archive"
fi
printf '%s  %s\n' "$zstd_sha256" "$zstd_archive" | shasum -a 256 -c - >&2
tar -xzf "$zstd_archive" -C "$scratch"
zstd_source="$scratch/zstd-$zstd_version"
zstd_library="$app/Contents/Frameworks/libzstd.1.dylib"

zstd_slices=()
for arch in "${archs[@]}"; do
    slice="$scratch/libzstd.$arch.dylib"
    xcrun clang -arch "$arch" -mmacosx-version-min=14.0 -O2 -dynamiclib \
        -install_name '@rpath/libzstd.1.dylib' -DZSTD_DISABLE_ASM \
        "$zstd_source"/lib/common/*.c "$zstd_source"/lib/decompress/*.c \
        -o "$slice"
    zstd_slices+=("$slice")
done

if [[ ${#zstd_slices[@]} -eq 1 ]]; then
    cp "${zstd_slices[0]}" "$zstd_library"
else
    lipo -create "${zstd_slices[@]}" -output "$zstd_library"
fi
cp "$zstd_source/LICENSE" "$zstd_source/COPYING" "$app/Contents/Resources/"

sign_identity="${TOKI_CODESIGN_IDENTITY:-${APPLE_SIGNING_IDENTITY:--}}"
codesign_args=(--force --sign "$sign_identity")
if [[ "$sign_identity" != "-" ]]; then
    codesign_args+=(--options runtime --timestamp)
fi
codesign "${codesign_args[@]}" "$zstd_library" >&2

if [[ -n "$icon" ]]; then
    iconset="$scratch/AppIcon.iconset"
    mkdir "$iconset"
    for size in 16 32 128 256 512; do
        sips -s format png -z "$size" "$size" "$icon" --out "$iconset/icon_${size}x${size}.png" >/dev/null
        sips -s format png -z "$((size * 2))" "$((size * 2))" "$icon" \
            --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c 'Delete :CFBundleIconFile' "$app/Contents/Info.plist" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon.icns' "$app/Contents/Info.plist"
fi

codesign "${codesign_args[@]}" "$app" >&2
codesign --verify --deep --strict "$app" >&2
if [[ "$sign_identity" != "-" ]]; then
    details="$(codesign -dvvv "$app" 2>&1)"
    if ! grep -q '^CodeDirectory .*flags=.*(runtime)' <<<"$details"; then
        printf 'Error: Hardened Runtime is not enabled on %s\n' "$app" >&2
        printf '%s\n' "$details" >&2
        exit 1
    fi
    if ! grep -q '^Timestamp=' <<<"$details"; then
        printf 'Error: Secure timestamp is missing on %s\n' "$app" >&2
        printf '%s\n' "$details" >&2
        exit 1
    fi
    team_id="$(sed -n 's/^TeamIdentifier=//p' <<<"$details" | head -n 1)"
    if [[ -z "$team_id" || "$team_id" == "not set" ]]; then
        printf 'Error: TeamIdentifier is missing on %s\n' "$app" >&2
        exit 1
    fi
    if [[ -n "${TOKI_APPLE_TEAM_ID:-}" && "$team_id" != "$TOKI_APPLE_TEAM_ID" ]]; then
        printf 'Error: Expected TeamIdentifier=%s, got %s on %s\n' "$TOKI_APPLE_TEAM_ID" "$team_id" "$app" >&2
        exit 1
    fi
fi
rm -rf "$root/dist/Toki.app"
mv "$app" "$root/dist/Toki.app"
printf '%s\n' "$root/dist/Toki.app"
