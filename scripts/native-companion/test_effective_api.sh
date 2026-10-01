#!/bin/zsh
# ENSO ad-hoc local override: fixture-only native behavior acceptance for Companion API v1.
# It assumes a locally built app, CompanionTest bundle isolation, and Python 3 loopback mocks.
# Revalidate bundle signing, provider schemas, persistence, queue state, and cleanup on upstream changes.

set -euo pipefail

if (( $# != 1 )); then
    print -u2 'usage: test_effective_api.sh /absolute/path/to/VoiceInk.app'
    exit 64
fi

source_app=$1
api_port=${VOICEINK_COMPANION_EFFECTIVE_PORT:-62744}
provider_port=${VOICEINK_COMPANION_FIXTURE_PROVIDER_PORT:-62745}
[[ -d "$source_app" ]]

script_dir=${0:A:h}
scratch=$(mktemp -d "${TMPDIR:-/tmp}/voiceink-companion-effective.XXXXXX")
test_app="$scratch/VoiceInk-CompanionTest.app"
data_dir="$scratch/data"
provider_pid=""
test_pid=""
contender_pid=""
live_pid=$(pgrep -f '^/Applications/VoiceInk-GPL.app/Contents/MacOS/VoiceInk$' | head -1 || true)

cleanup() {
    if [[ -n "$test_pid" ]] && kill -0 "$test_pid" 2>/dev/null; then
        kill "$test_pid"
        wait "$test_pid" 2>/dev/null || true
    fi
    if [[ -n "$provider_pid" ]] && kill -0 "$provider_pid" 2>/dev/null; then
        kill "$provider_pid"
        wait "$provider_pid" 2>/dev/null || true
    fi
    if [[ -n "$contender_pid" ]] && kill -0 "$contender_pid" 2>/dev/null; then
        kill "$contender_pid"
        wait "$contender_pid" 2>/dev/null || true
    fi
    if [[ -n "${test_id:-}" ]]; then
        defaults delete "$test_id" >/dev/null 2>&1 || true
        security delete-generic-password -s "$test_id" \
            -a 'customAIProvider_E2E00000-0000-4000-8000-000000000004_APIKey' >/dev/null 2>&1 || true
        security delete-generic-password -s "$test_id" -a 'customAPIKey' >/dev/null 2>&1 || true
    fi
    rm -rf "$scratch"
}
trap cleanup EXIT INT TERM

/usr/bin/ditto "$source_app" "$test_app"
info_plist="$test_app/Contents/Info.plist"
source_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")
source_preferences="$HOME/Library/Preferences/$source_id.plist"
source_preferences_before=$(stat -f '%m' "$source_preferences" 2>/dev/null || print missing)
test_id="${source_id%.CompanionTest}.ProviderAcceptance.CompanionTest"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $test_id" "$info_plist"
/usr/bin/codesign --force --deep --sign - "$test_app" >/dev/null
/usr/bin/codesign --verify --deep --strict "$test_app"
executable_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist")

/usr/bin/python3 "$script_dir/companion_fixture_provider.py" \
    --port "$provider_port" --transcription-delay 2.5 >"$scratch/provider.log" 2>&1 &
provider_pid=$!
for _ in {1..50}; do
    nc -z 127.0.0.1 "$provider_port" >/dev/null 2>&1 && break
    kill -0 "$provider_pid"
    sleep 0.1
done
nc -z 127.0.0.1 "$provider_port"

launch_app() {
    mkdir -p "$data_dir"
    VOICEINK_COMPANION_DATA_DIR="$data_dir" \
    VOICEINK_COMPANION_PORT="$api_port" \
    VOICEINK_COMPANION_SEED_FIXTURE=1 \
    VOICEINK_COMPANION_FIXTURE_PROVIDER_URL="http://127.0.0.1:$provider_port" \
        "$test_app/Contents/MacOS/$executable_name" >"$scratch/app.log" 2>&1 &
    test_pid=$!

    connection="$data_dir/Companion/connection.json"
    ready=0
    for _ in {1..250}; do
        if [[ -f "$connection" ]]; then
            endpoint=$(/usr/bin/plutil -extract endpoint raw "$connection" 2>/dev/null || true)
            token=$(/usr/bin/plutil -extract token raw "$connection" 2>/dev/null || true)
            if [[ -n "$endpoint" && -n "$token" ]]; then
                code=$(curl --silent --output "$scratch/state.json" --write-out '%{http_code}' \
                    --header "Authorization: Bearer $token" "$endpoint/v1/state" || true)
                if [[ "$code" == "200" ]]; then
                    ready=1
                    break
                fi
            fi
        fi
        kill -0 "$test_pid"
        sleep 0.1
    done
    [[ "$ready" == "1" ]]
    [[ "$endpoint" == "http://127.0.0.1:$api_port" ]]
    [[ "$(stat -f '%Lp' "$connection")" == "600" ]]
}

launch_app

descriptor_hash_before=$(shasum -a 256 "$connection" | awk '{print $1}')
VOICEINK_COMPANION_DATA_DIR="$data_dir" \
VOICEINK_COMPANION_PORT="$api_port" \
    "$test_app/Contents/MacOS/$executable_name" >"$scratch/contender.log" 2>&1 &
contender_pid=$!
sleep 1
kill -0 "$contender_pid"
descriptor_hash_after=$(shasum -a 256 "$connection" | awk '{print $1}')
[[ "$descriptor_hash_before" == "$descriptor_hash_after" ]]
curl --fail --silent --header "Authorization: Bearer $token" "$endpoint/v1/state" >"$scratch/owner-state.json"
kill "$contender_pid"
wait "$contender_pid" 2>/dev/null || true
contender_pid=""

/usr/bin/python3 - "$scratch/state.json" "$scratch/asr-id" "$scratch/pending-id" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
models = {item["name"]: item for item in state["models"]}
for name in ("companion-fixture-asr", "companion-fixture-after-idle"):
    assert models[name]["provider"] == "Custom"
    assert models[name]["downloaded"] is True
open(sys.argv[2], "w").write(models["companion-fixture-asr"]["id"])
open(sys.argv[3], "w").write(models["companion-fixture-after-idle"]["id"])
providers = {item["id"]: item for item in state["providers"]}
assert providers["Custom"]["selected"] is True
assert providers["Custom"]["connected"] is True
assert providers["Custom"]["selectedModel"] == "companion-fixture-review"
PY
asr_id=$(<"$scratch/asr-id")
pending_id=$(<"$scratch/pending-id")

curl --fail --silent --request POST --header 'Content-Type: application/json' \
    --header "Authorization: Bearer $token" \
    --data '{"key":"AppendTrailingSpace","value":true}' \
    "$endpoint/v1/settings" >"$scratch/setting.json"
/usr/bin/python3 - "$scratch/setting.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1]))
assert value["key"] == "AppendTrailingSpace" and value["value"] is True
PY

curl --fail --silent --header "Authorization: Bearer $token" \
    "$endpoint/v1/dictionary" >"$scratch/dictionary.json"
/usr/bin/python3 - "$scratch/dictionary.json" "$scratch/dictionary-mutation.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1]))
item = next(x for x in value["replacements"] if x["originalText"] == "CompanionSyntheticOriginal")
payload = {
    "expectedRevision": value["revision"],
    "operations": [{
        "kind": "replacement", "action": "upsert", "id": item["id"],
        "originalText": item["originalText"], "replacementText": item["replacementText"],
        "isEnabled": True,
    }],
}
json.dump(payload, open(sys.argv[2], "w"), separators=(",", ":"))
PY
curl --fail --silent --request POST --header 'Content-Type: application/json' \
    --header "Authorization: Bearer $token" --data-binary "@$scratch/dictionary-mutation.json" \
    "$endpoint/v1/dictionary" >"$scratch/dictionary-updated.json"

curl --fail --silent --request POST --header 'Content-Type: application/json' \
    --header "Authorization: Bearer $token" --data "{\"id\":\"$asr_id\"}" \
    "$endpoint/v1/models/select" >"$scratch/model-applied.json"
grep -q '"status"[[:space:]]*:[[:space:]]*"applied"' "$scratch/model-applied.json"

audio_path="$data_dir/Companion/Inbox/companion-e2e-input.wav"
[[ -f "$audio_path" ]]
/usr/bin/python3 - "$audio_path" "$scratch/transcribe.json" <<'PY'
import json, sys
json.dump({"action":"transcribeAudio","args":{"path":sys.argv[1]}}, open(sys.argv[2], "w"), separators=(",", ":"))
PY
curl --fail --silent --request POST --header 'Content-Type: application/json' \
    --header "Authorization: Bearer $token" --data-binary "@$scratch/transcribe.json" \
    "$endpoint/v1/actions" >"$scratch/transcribe-response.json"

processing=0
for _ in {1..50}; do
    curl --fail --silent --header "Authorization: Bearer $token" "$endpoint/v1/state" >"$scratch/busy-state.json"
    if /usr/bin/python3 - "$scratch/busy-state.json" <<'PY'
import json, sys
raise SystemExit(0 if json.load(open(sys.argv[1]))["audioTranscription"]["isProcessing"] else 1)
PY
    then
        processing=1
        break
    fi
    sleep 0.05
done
[[ "$processing" == "1" ]]

pending_code=$(curl --silent --output "$scratch/model-pending.json" --write-out '%{http_code}' \
    --request POST --header 'Content-Type: application/json' \
    --header "Authorization: Bearer $token" --data "{\"id\":\"$pending_id\"}" \
    "$endpoint/v1/models/select")
[[ "$pending_code" == "202" ]]
curl --fail --silent --header "Authorization: Bearer $token" "$endpoint/v1/state" >"$scratch/pending-state.json"
/usr/bin/python3 - "$scratch/model-pending.json" "$scratch/pending-state.json" "$pending_id" <<'PY'
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "pending"
state = json.load(open(sys.argv[2]))
assert state["metadata"]["activeTranscriptionModelID"] != sys.argv[3]
assert state["metadata"]["pendingModelID"] == sys.argv[3]
PY

completed=0
for _ in {1..200}; do
    curl --fail --silent --header "Authorization: Bearer $token" "$endpoint/v1/state" >"$scratch/final-state.json"
    if /usr/bin/python3 - "$scratch/final-state.json" "$pending_id" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
items = state["audioTranscription"]["items"]
ok = (not state["audioTranscription"]["isProcessing"] and items and
      items[-1]["status"] == "completed" and
      state["metadata"]["activeTranscriptionModelID"] == sys.argv[2] and
      state["metadata"].get("pendingModelID") is None)
raise SystemExit(0 if ok else 1)
PY
    then
        completed=1
        break
    fi
    sleep 0.1
done
[[ "$completed" == "1" ]]

curl --fail --silent --header "Authorization: Bearer $token" \
    "$endpoint/v1/history?offset=0&limit=20" >"$scratch/history.json"
/usr/bin/python3 - "$scratch/history.json" <<'PY'
import json, sys
items = json.load(open(sys.argv[1]))["items"]
match = next(x for x in items if x.get("transcriptionModelName") == "Companion Fixture ASR")
assert match["text"] == "CompanionSyntheticReplacement"
PY

curl --fail --silent --request POST --header 'Content-Type: application/json' \
    --header "Authorization: Bearer $token" \
    --data '{"original":"CompanionSyntheticOriginal","corrected":"CompanionSyntheticReplacement"}' \
    "$endpoint/v1/review" >"$scratch/review.json"
/usr/bin/python3 - "$scratch/review.json" <<'PY'
import json, sys
items = json.load(open(sys.argv[1]))["suggestions"]
assert items == [{
    "original":"CompanionSyntheticOriginal",
    "corrected":"CompanionSyntheticReplacement",
    "reason":"Deterministic fixture correction",
}]
PY

kill "$test_pid"
wait "$test_pid" 2>/dev/null || true
test_pid=""
launch_app
curl --fail --silent --header "Authorization: Bearer $token" "$endpoint/v1/state" >"$scratch/relaunch-state.json"
/usr/bin/python3 - "$scratch/relaunch-state.json" "$pending_id" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
setting = next(x for x in state["settings"] if x["key"] == "AppendTrailingSpace")
assert setting["value"] is True
assert state["metadata"]["activeTranscriptionModelID"] == sys.argv[2]
assert state["metadata"]["historyCount"] >= 2
PY

[[ -z "$live_pid" ]] || kill -0 "$live_pid"
source_preferences_after=$(stat -f '%m' "$source_preferences" 2>/dev/null || print missing)
[[ "$source_preferences_before" == "$source_preferences_after" ]]
for store in default.store dictionary.store stats.store; do
    [[ -f "$data_dir/$store" ]]
done

print 'PASS effective Companion API: isolated provider, persisted setting, queued model apply, dictionary transcription, structured review'
