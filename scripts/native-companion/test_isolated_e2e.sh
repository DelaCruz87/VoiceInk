#!/bin/zsh
# ENSO ad-hoc local override: isolated CompanionTest launcher for the approved native API v1.
# It assumes a locally built macOS .app, ad-hoc signing, and the deterministic fixture seeder.
# Revalidate bundle signing, preference domains, store roots, and API responses after build/schema changes.

set -euo pipefail

if (( $# != 1 )); then
    print -u2 'usage: test_isolated_e2e.sh /absolute/path/to/VoiceInk.app'
    exit 64
fi
source_app=$1
port=${VOICEINK_COMPANION_E2E_PORT:-62742}
[[ -d "$source_app" ]]

scratch=$(mktemp -d "${TMPDIR:-/tmp}/voiceink-companion-e2e.XXXXXX")
test_app="$scratch/VoiceInk-CompanionTest.app"
data_dir="$scratch/data"
test_pid=""
live_pid=$(pgrep -f '^/Applications/VoiceInk-GPL.app/Contents/MacOS/VoiceInk$' | head -1 || true)

cleanup() {
    if [[ -n "$test_pid" ]] && kill -0 "$test_pid" 2>/dev/null; then
        kill "$test_pid"
        wait "$test_pid" 2>/dev/null || true
    fi
    [[ -z "${test_id:-}" ]] || defaults delete "$test_id" >/dev/null 2>&1 || true
    rm -rf "$scratch"
}
trap cleanup EXIT INT TERM

/usr/bin/ditto "$source_app" "$test_app"
info_plist="$test_app/Contents/Info.plist"
source_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")
source_preferences="$HOME/Library/Preferences/$source_id.plist"
source_preferences_before=$(stat -f '%m' "$source_preferences" 2>/dev/null || print missing)
test_id="${source_id%.CompanionTest}.CompanionTest"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $test_id" "$info_plist"
/usr/bin/codesign --force --deep --sign - "$test_app" >/dev/null
/usr/bin/codesign --verify --deep --strict "$test_app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")" == "$test_id" ]]
[[ "$test_id" != "$source_id" ]]

executable_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist")
mkdir -p "$data_dir"
VOICEINK_COMPANION_DATA_DIR="$data_dir" \
VOICEINK_COMPANION_PORT="$port" \
VOICEINK_COMPANION_SEED_FIXTURE=1 \
    "$test_app/Contents/MacOS/$executable_name" >"$scratch/app.log" 2>&1 &
test_pid=$!

connection="$data_dir/Companion/connection.json"
ready=0
for _ in {1..200}; do
    if [[ -f "$connection" ]]; then
        endpoint=$(/usr/bin/plutil -extract endpoint raw "$connection" 2>/dev/null || true)
        token=$(/usr/bin/plutil -extract token raw "$connection" 2>/dev/null || true)
        if [[ -n "$endpoint" && -n "$token" ]]; then
            code=$(curl --silent --output "$scratch/capabilities.json" --write-out '%{http_code}' \
                --header "Authorization: Bearer $token" "$endpoint/v1/capabilities" || true)
            if [[ "$code" == "200" ]]; then
                ready=1
                break
            fi
        fi
    fi
    kill -0 "$test_pid" 2>/dev/null
    sleep 0.1
done
[[ "$ready" == "1" ]]
[[ "$(stat -f '%Lp' "$connection")" == "600" ]]
[[ "$endpoint" == "http://127.0.0.1:$port" ]]
for store in default.store dictionary.store stats.store; do
    [[ -f "$data_dir/$store" ]]
done

curl --fail --silent --header "Authorization: Bearer $token" "$endpoint/v1/state" >"$scratch/state.json"
curl --fail --silent --header "Authorization: Bearer $token" "$endpoint/v1/dictionary" >"$scratch/dictionary.json"
curl --fail --silent --header "Authorization: Bearer $token" "$endpoint/v1/history?offset=0&limit=10" >"$scratch/history.json"

history_id=$(/usr/bin/plutil -extract items.0.id raw "$scratch/history.json")
[[ "$history_id" == "E2E00000-0000-4000-8000-000000000001" ]]
curl --fail --silent --dump-header "$scratch/audio.headers" \
    --header "Authorization: Bearer $token" \
    "$endpoint/v1/history/$history_id/audio" >"$scratch/audio.wav"
expected_hash=$(awk 'BEGIN{IGNORECASE=1} /^X-Content-SHA256:/ {gsub("\\r", "", $2); print $2}' "$scratch/audio.headers")
actual_hash=$(shasum -a 256 "$scratch/audio.wav" | awk '{print $1}')
[[ -n "$expected_hash" && "$expected_hash" == "$actual_hash" ]]

conflict=$(curl --silent --output "$scratch/conflict.json" --write-out '%{http_code}' \
    --request POST --header 'Content-Type: application/json' \
    --header "Authorization: Bearer $token" \
    --data '{"expectedRevision":"synthetic-conflict","operations":[{"kind":"vocabulary","action":"delete","word":"CompanionSyntheticVocabulary"}]}' \
    "$endpoint/v1/dictionary")
[[ "$conflict" == "409" ]]

[[ -z "$live_pid" ]] || kill -0 "$live_pid"
source_preferences_after=$(stat -f '%m' "$source_preferences" 2>/dev/null || print missing)
[[ "$source_preferences_before" == "$source_preferences_after" ]]
print "PASS isolated Companion E2E: $test_id, stores, auth, state, dictionary conflict, history, and audio hash"
