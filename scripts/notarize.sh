#!/bin/bash
set -euo pipefail

usage() {
    printf 'Usage: %s <app|dmg> <path>\n' "$0" >&2
    exit 64
}

if [[ $# -ne 2 ]]; then
    usage
fi

kind="$1"
target="$2"

case "$kind" in
    app)
        if [[ ! -d "$target" ]]; then
            printf 'App bundle not found: %s\n' "$target" >&2
            exit 1
        fi
        ;;
    dmg)
        if [[ ! -f "$target" ]]; then
            printf 'DMG file not found: %s\n' "$target" >&2
            exit 1
        fi
        ;;
    *)
        usage
        ;;
esac

for var in APPLE_API_ISSUER APPLE_API_KEY APPLE_API_KEY_PATH; do
    if [[ -z "${!var:-}" ]]; then
        printf 'Missing required notarization environment variable: %s\n' "$var" >&2
        exit 1
    fi
done

if [[ ! -f "$APPLE_API_KEY_PATH" ]]; then
    printf 'Apple API key file not found: %s\n' "$APPLE_API_KEY_PATH" >&2
    exit 1
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/toki-notarize.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

submit_path="$target"
if [[ "$kind" == "app" ]]; then
    submit_path="$scratch/$(basename "$target").zip"
    ditto -c -k --keepParent "$target" "$submit_path"
fi

printf '==> Submitting %s (%s) to Apple notarization service...\n' "$(basename "$target")" "$kind" >&2
result_json="$scratch/notary-result.json"
set +e
xcrun notarytool submit "$submit_path" \
    --key "$APPLE_API_KEY_PATH" \
    --key-id "$APPLE_API_KEY" \
    --issuer "$APPLE_API_ISSUER" \
    --wait \
    --output-format json > "$result_json"
submit_exit=$?
set -e

status="$(plutil -extract status raw "$result_json" 2>/dev/null || true)"
submission_id="$(plutil -extract id raw "$result_json" 2>/dev/null || true)"

if [[ $submit_exit -ne 0 || "$status" != "Accepted" ]]; then
    printf 'Notarization failed (exit=%s, status=%s, id=%s)\n' "$submit_exit" "${status:-unknown}" "${submission_id:-unknown}" >&2
    if [[ -s "$result_json" ]]; then
        cat "$result_json" >&2
    fi
    if [[ -n "$submission_id" ]]; then
        printf '\n==> Fetching Apple notarization log for %s:\n' "$submission_id" >&2
        xcrun notarytool log "$submission_id" \
            --key "$APPLE_API_KEY_PATH" \
            --key-id "$APPLE_API_KEY" \
            --issuer "$APPLE_API_ISSUER" >&2 || true
    fi
    exit 1
fi

printf '==> Notarization accepted (id=%s). Stapling ticket...\n' "$submission_id" >&2
xcrun stapler staple -v "$target" >&2
xcrun stapler validate -v "$target" >&2

if [[ "$kind" == "app" ]]; then
    spctl --assess --type execute -vv "$target" >&2
else
    spctl --assess --type open --context context:primary-signature -vv "$target" >&2
fi
